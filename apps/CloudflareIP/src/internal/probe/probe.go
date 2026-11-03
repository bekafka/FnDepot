// Package probe 对单个 Cloudflare 边缘 IP 做「用你的域名能否被服务」的可达性探测。
//
// 这是整个工具与 CloudflareSpeedTest 类工具的根本区别：
// 后者只测某个 IP 的带宽/延迟，不关心这个 IP 到底服不服务你的 zone；
// 我们把 SNI 和 Host 都设成目标域名，用 /cdn-cgi/trace 拿回真实落点 colo，
// 并用 403 / error code 1034 识别「边缘不服务该 zone」的伪候选。
package probe

import (
	"bufio"
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"strings"
	"sync"
	"time"
)

// 状态分类。只有 OK 能进入排名，其余都是硬淘汰或存疑。
const (
	StatusOK             = "OK"              // 200 且拿到 colo —— 唯一可用
	StatusEdgeRestricted = "EDGE_RESTRICTED" // 403 + error code 1034 —— 该边缘不服务此 zone
	StatusForbidden      = "FORBIDDEN"       // 其它 403
	StatusHTTPError      = "HTTP_ERROR"      // 其它非 200
	StatusTLSError       = "TLS_ERROR"       // 证书/握手失败
	StatusTimeout        = "TIMEOUT"         // 连接或读超时
	StatusConnError      = "CONN_ERROR"      // RST / 不可达
)

// Result 是单个 IP 的探测结果。
type Result struct {
	IP     string  `json:"ip"`
	Status string  `json:"status"`
	Code   int     `json:"code"`
	Colo   string  `json:"colo,omitempty"`
	Loc    string  `json:"loc,omitempty"`
	TCPms  float64 `json:"tcp_ms"`
	TLSms  float64 `json:"tls_ms"`
	TTFBms float64 `json:"ttfb_ms"`
	Err    string  `json:"err,omitempty"`
	Body   string  `json:"body,omitempty"` // 仅失败时保留前 120 字节，便于取证
}

// OK 表示该 IP 可用于服务目标域名。
func (r Result) OK() bool { return r.Status == StatusOK && r.Colo != "" }

// Options 控制单次探测行为。
type Options struct {
	Domain  string        // 目标域名，同时作为 SNI 与 Host
	Path    string        // 探测路径，默认 /cdn-cgi/trace
	Port    string        // 默认 443
	Timeout time.Duration // 单 IP 总超时
}

func (o *Options) applyDefaults() {
	if o.Path == "" {
		o.Path = "/cdn-cgi/trace"
	}
	if o.Port == "" {
		o.Port = "443"
	}
	if o.Timeout <= 0 {
		o.Timeout = 3 * time.Second
	}
}

// One 探测单个 IP。永不 panic、永不返回 error——失败一律编码进 Result.Status。
func One(addr netip.Addr, opt Options) Result {
	opt.applyDefaults()
	res := Result{IP: addr.String()}

	ctx, cancel := context.WithTimeout(context.Background(), opt.Timeout)
	defer cancel()

	var d net.Dialer
	t0 := time.Now()
	rawConn, err := d.DialContext(ctx, "tcp", net.JoinHostPort(addr.String(), opt.Port))
	if err != nil {
		res.Status = classifyDialErr(err)
		res.Err = trimErr(err)
		return res
	}
	defer rawConn.Close()
	res.TCPms = ms(t0)

	if dl, ok := ctx.Deadline(); ok {
		_ = rawConn.SetDeadline(dl)
	}

	// SNI 必须是目标域名——这正是「这个 IP 会不会服务我的 zone」的判决条件。
	tlsConn := tls.Client(rawConn, &tls.Config{
		ServerName: opt.Domain,
		NextProtos: []string{"http/1.1"}, // 固定 h1，便于逐跳计时与解析
		MinVersion: tls.VersionTLS12,
	})
	t1 := time.Now()
	if err := tlsConn.HandshakeContext(ctx); err != nil {
		res.Status = StatusTLSError
		res.Err = trimErr(err)
		return res
	}
	res.TLSms = ms(t1)

	req := fmt.Sprintf("GET %s HTTP/1.1\r\nHost: %s\r\nUser-Agent: cfpick/0.1\r\nAccept: */*\r\nConnection: close\r\n\r\n", opt.Path, opt.Domain)
	if _, err := io.WriteString(tlsConn, req); err != nil {
		res.Status = classifyDialErr(err)
		res.Err = trimErr(err)
		return res
	}

	t2 := time.Now()
	br := bufio.NewReader(tlsConn)
	statusLine, err := br.ReadString('\n')
	if err != nil {
		res.Status = classifyDialErr(err)
		res.Err = trimErr(err)
		return res
	}
	// 首字节到达时刻即 TTFB
	res.TTFBms = ms(t2)
	res.Code = parseStatusCode(statusLine)

	// 读完 header，丢掉
	for {
		line, err := br.ReadString('\n')
		if err != nil || line == "\r\n" || line == "\n" {
			break
		}
	}
	body, _ := io.ReadAll(io.LimitReader(br, 4096))
	text := string(body)
	res.Colo = field(text, "colo")
	res.Loc = field(text, "loc")

	switch {
	case res.Code == 200 && res.Colo != "":
		res.Status = StatusOK
	case res.Code == 403 && strings.Contains(text, "1034"):
		res.Status = StatusEdgeRestricted
		res.Body = clip(text)
	case res.Code == 403:
		res.Status = StatusForbidden
		res.Body = clip(text)
	case res.Code != 200:
		res.Status = StatusHTTPError
		res.Body = clip(text)
	default:
		// 200 但拿不到 colo：说明不是 CF 边缘应答（或路径被 Worker 吞了）
		res.Status = StatusHTTPError
		res.Body = clip(text)
	}
	return res
}

// Run 并发探测全部地址，返回结果（顺序与输入无关）。
func Run(addrs []netip.Addr, opt Options, conc int) []Result {
	if conc <= 0 {
		conc = 32
	}
	out := make([]Result, len(addrs))
	var wg sync.WaitGroup
	sem := make(chan struct{}, conc)
	for i, a := range addrs {
		wg.Add(1)
		go func(i int, a netip.Addr) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			out[i] = One(a, opt)
		}(i, a)
	}
	wg.Wait()
	return out
}

func ms(t time.Time) float64 { return float64(time.Since(t).Microseconds()) / 1000.0 }

func classifyDialErr(err error) string {
	if errors.Is(err, context.DeadlineExceeded) {
		return StatusTimeout
	}
	var ne net.Error
	if errors.As(err, &ne) && ne.Timeout() {
		return StatusTimeout
	}
	var oe *net.OpError
	if errors.As(err, &oe) && oe.Timeout() {
		return StatusTimeout
	}
	if strings.Contains(err.Error(), "i/o timeout") {
		return StatusTimeout
	}
	return StatusConnError
}

func parseStatusCode(line string) int {
	// 形如 "HTTP/1.1 200 OK"
	parts := strings.Fields(line)
	if len(parts) < 2 {
		return 0
	}
	var code int
	fmt.Sscanf(parts[1], "%d", &code)
	return code
}

// field 从 trace 文本里取 key=value 的值。
func field(text, key string) string {
	prefix := key + "="
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, prefix) {
			return strings.TrimSpace(strings.TrimPrefix(line, prefix))
		}
	}
	return ""
}

func clip(s string) string {
	s = strings.ReplaceAll(strings.ReplaceAll(s, "\r", ""), "\n", " ")
	if len(s) > 120 {
		return s[:120]
	}
	return s
}

func trimErr(err error) string {
	s := err.Error()
	if len(s) > 120 {
		return s[:120]
	}
	return s
}
