// PhotoCraft 静态站点宿主：只做一件事——把上游的 WebAssembly 静态包按它要求的
// 响应头规则发出去。没有任何服务端存储、没有账号、不代理任何外部请求。
//
// 之所以不直接用现成的文件服务器：
//   · .wasm 必须以 application/wasm 发，否则浏览器拒绝流式编译（只能慢速加载或直接失败）；
//   · 上游把应用 wasm 预压缩后切成 *.part-aa 之类分片，页面自己解压，服务端不得再叠
//     Content-Encoding，必须原字节直出；
//   · 未知路径必须真 404，禁止 SPA 兜底——否则上传缺文件会被掩盖成「白屏/一直加载」；
//   · 带内容哈希的资源长期强缓存，index.html / app/photocraft-web.js / app/parts.txt /
//     fonts/manifest.txt 这几个固定名必须 no-cache。
//
// 运行期不做任何写操作：站点目录只读，进程只监听端口。
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"time"
)

var version = "dev"

// 这些文件跨版本同名但内容会变，必须每次回源校验。
var noCacheExact = map[string]bool{
	"index.html":            true,
	"app/photocraft-web.js": true,
	"app/parts.txt":         true,
	"fonts/manifest.txt":    true,
}

// 带内容哈希的文件名，例如 photocraft-web-2f37f62fa93f60ec.part-aa
var hashedName = regexp.MustCompile(`-[0-9a-f]{8,}\.`)

func main() {
	listen := flag.String("listen", "0.0.0.0:28200", "监听地址，例如 0.0.0.0:28200")
	root := flag.String("root", "", "站点根目录（必填）")
	showVersion := flag.Bool("version", false, "打印版本后退出")
	flag.Parse()

	if *showVersion {
		fmt.Printf("photocraft-web %s\n", version)
		return
	}
	if *root == "" {
		log.Fatal("-root 必填：指向解包后的站点目录")
	}
	abs, err := filepath.Abs(*root)
	if err != nil || abs == "" {
		log.Fatalf("解析 -root 失败：%v", err)
	}
	fi, err := os.Stat(abs)
	if err != nil {
		log.Fatalf("站点目录不可读：%s（%v）", abs, err)
	}
	if !fi.IsDir() {
		log.Fatalf("-root 不是目录：%s", abs)
	}
	if _, err := os.Stat(filepath.Join(abs, "index.html")); err != nil {
		log.Fatalf("站点目录里没有 index.html：%s（payload 没铺好？）", abs)
	}

	srv := &http.Server{
		Addr:              *listen,
		Handler:           newHandler(abs),
		ReadHeaderTimeout: 15 * time.Second,
		// 大 wasm 分片要完整下载，WriteTimeout 不设成短值；用空闲超时兜底。
		IdleTimeout: 120 * time.Second,
	}

	ln, err := net.Listen("tcp", *listen)
	if err != nil {
		log.Fatalf("监听 %s 失败：%v", *listen, err)
	}
	log.Printf("photocraft-web %s 监听 %s，站点根 %s", version, *listen, abs)

	stop := make(chan os.Signal, 2)
	signal.Notify(stop, syscall.SIGTERM, syscall.SIGINT)
	go func() {
		s := <-stop
		log.Printf("收到 %s，开始优雅退出", s)
		ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
		defer cancel()
		if err := srv.Shutdown(ctx); err != nil {
			log.Printf("优雅退出超时：%v", err)
			_ = srv.Close()
		}
	}()

	if err := srv.Serve(ln); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatalf("服务退出：%v", err)
	}
	log.Printf("已退出")
}

func newHandler(root string) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			w.Header().Set("Allow", "GET, HEAD")
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		if r.URL.Path == "/healthz" {
			w.Header().Set("Content-Type", "text/plain; charset=utf-8")
			w.Header().Set("Cache-Control", "no-store")
			_, _ = w.Write([]byte("ok\n"))
			return
		}

		// path.Clean 消掉 ../，再把 URL 路径映射到站点目录内。
		upath := path.Clean("/" + r.URL.Path)
		rel := strings.TrimPrefix(upath, "/")
		full := filepath.Join(root, filepath.FromSlash(rel))

		fi, err := os.Stat(full)
		if err != nil {
			http.NotFound(w, r)
			return
		}
		if fi.IsDir() {
			// 只接受目录下的 index.html；没有就 404，不做 SPA 兜底。
			idx := filepath.Join(full, "index.html")
			i2, e2 := os.Stat(idx)
			if e2 != nil || i2.IsDir() {
				http.NotFound(w, r)
				return
			}
			full, fi = idx, i2
			rel = path.Join(rel, "index.html")
			rel = strings.TrimPrefix(rel, "/")
		}

		setHeaders(w, rel)

		f, err := os.Open(full)
		if err != nil {
			http.Error(w, "internal error", http.StatusInternalServerError)
			return
		}
		defer f.Close()

		// ServeContent 负责 Range / If-Modified-Since / Content-Length。
		http.ServeContent(w, r, fi.Name(), fi.ModTime(), f)
	})
}

func setHeaders(w http.ResponseWriter, rel string) {
	h := w.Header()
	h.Set("X-Content-Type-Options", "nosniff")

	base := path.Base(rel)
	switch {
	case strings.HasSuffix(base, ".wasm"):
		h.Set("Content-Type", "application/wasm")
		h.Set("Cache-Control", "public, max-age=31536000, immutable")
	case strings.Contains(base, ".part-"):
		// 预压缩分片：本身就是 gzip，原字节直出，绝不加 Content-Encoding。
		h.Set("Content-Type", "application/octet-stream")
		h.Set("Cache-Control", "public, max-age=31536000, immutable")
	case noCacheExact[rel]:
		h.Set("Content-Type", contentTypeFor(base))
		h.Set("Cache-Control", "no-cache")
	case hashedName.MatchString(base):
		h.Set("Content-Type", contentTypeFor(base))
		h.Set("Cache-Control", "public, max-age=31536000, immutable")
	default:
		h.Set("Content-Type", contentTypeFor(base))
		h.Set("Cache-Control", "no-cache")
	}
}

func contentTypeFor(base string) string {
	switch {
	case strings.HasSuffix(base, ".html"):
		return "text/html; charset=utf-8"
	case strings.HasSuffix(base, ".js"):
		return "text/javascript; charset=utf-8"
	case strings.HasSuffix(base, ".json"), strings.HasSuffix(base, ".txt"):
		return "text/plain; charset=utf-8"
	case strings.HasSuffix(base, ".css"):
		return "text/css; charset=utf-8"
	case strings.HasSuffix(base, ".wasm"):
		return "application/wasm"
	case strings.HasSuffix(base, ".png"):
		return "image/png"
	case strings.HasSuffix(base, ".svg"):
		return "image/svg+xml"
	case strings.HasSuffix(base, ".ttf"):
		return "font/ttf"
	case strings.HasSuffix(base, ".otf"), strings.HasSuffix(base, ".ttc"):
		return "font/otf"
	case strings.HasSuffix(base, ".woff2"):
		return "font/woff2"
	default:
		return "application/octet-stream"
	}
}
