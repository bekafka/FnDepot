// cfpick —— 给挂在 Cloudflare 后面的域名挑「真正能用且落点近」的边缘 IP。
//
// 与 CloudflareSpeedTest / cf-dns-select 一类工具的区别：
//  1. 每个候选 IP 都用你的真实域名做 SNI + Host 去请求 /cdn-cgi/trace，
//     只有 200 且能取到 colo 才算可用；403 error code 1034 会被明确淘汰。
//  2. 排名看的是「你的线路到该边缘」的实际 TTFB，不是对 speed.cloudflare.com 的带宽。
//
// 本程序只读：不写任何配置文件，不碰 hosts。
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"net/netip"
	"os"
	"sort"
	"strings"
	"time"

	"cloudflareip/internal/candidates"
	"cloudflareip/internal/probe"
)

// version 由打包流水线用 -ldflags "-X main.version=x.y.z" 注入；
// 源码直接 go build 时是 dev。这样装到机器上能核对「跑的是不是新包」。
var version = "dev"

func main() {
	args := os.Args[1:]
	if len(args) > 0 {
		switch args[0] {
		case "probe":
			os.Exit(cmdProbe(args[1:]))
		case "page":
			os.Exit(cmdPage(args[1:]))
		case "apply":
			os.Exit(cmdApply(args[1:]))
		case "daemon":
			os.Exit(cmdDaemon(args[1:]))
		case "help", "-h", "--help":
			usage()
			return
		}
		// 其余参数（-write / -listen 等）当作默认运行的参数
		os.Exit(cmdDaemon(args))
	}
	os.Exit(cmdDaemon(nil))
}

func usage() {
	fmt.Fprintf(os.Stderr, "Cloudflare IP %s —— 给 Cloudflare 上的域名挑一条更快的线路\n", version)
	fmt.Fprint(os.Stderr, `

直接运行（推荐）：
  cloudflareip                  启动守护 + 网页，配置在 ~/.config/cloudflareip/
  sudo cloudflareip -write      同上，并把结果真正写入 /etc/hosts

常用参数：
  -write            真正写入 hosts（默认只预览，不改系统）
  -listen ADDR      网页监听地址，默认 127.0.0.1:17890
  -config PATH      指定配置文件（默认 ~/.config/cloudflareip/config.json）
  -no-ui            不启动网页

高级子命令（一般用不到）：
  probe  只测速、打印候选表
  page   对给定 IP 做页面级复测
  apply  手动写入 / 清除 hosts 里的受管记录
  daemon 同上面的默认运行
`)
}

func cmdProbe(args []string) int {
	fs := flag.NewFlagSet("probe", flag.ExitOnError)
	domain := fs.String("domain", "", "目标域名")
	path := fs.String("path", "/cdn-cgi/trace", "探测路径")
	perRange := fs.Int("per-range", 8, "每段抽样数")
	extra := fs.String("extra", "", "额外候选 IP，逗号分隔")
	conc := fs.Int("conc", 64, "并发数")
	timeout := fs.Duration("timeout", 3*time.Second, "单 IP 超时")
	top := fs.Int("top", 8, "复测前 N 名")
	repeat := fs.Int("repeat", 3, "复测次数")
	jsonOut := fs.String("json", "", "结果 JSON 输出路径")
	_ = fs.Parse(args)

	if *domain == "" {
		fmt.Fprintln(os.Stderr, "错误：-domain 必填")
		return 2
	}

	addrs, err := candidates.Sample(*perRange)
	if err != nil {
		fmt.Fprintf(os.Stderr, "生成候选失败：%v\n", err)
		return 1
	}
	// 额外候选（通常是该域名当前的实际解析结果，作为对照组）
	for _, s := range strings.Split(*extra, ",") {
		s = strings.TrimSpace(s)
		if s == "" {
			continue
		}
		a, err := netip.ParseAddr(s)
		if err != nil {
			fmt.Fprintf(os.Stderr, "忽略非法 IP %q：%v\n", s, err)
			continue
		}
		addrs = append(addrs, a)
	}

	opt := probe.Options{Domain: *domain, Path: *path, Timeout: *timeout}
	fmt.Printf("目标域名 : %s\n", *domain)
	fmt.Printf("探测路径 : %s\n", opt.Path)
	fmt.Printf("候选数量 : %d 个 IP，并发 %d，单 IP 超时 %s\n\n", len(addrs), *conc, *timeout)

	t0 := time.Now()
	results := probe.Run(addrs, opt, *conc)
	elapsed := time.Since(t0)

	// 统计各状态
	counts := map[string]int{}
	var okList []probe.Result
	for _, r := range results {
		counts[r.Status]++
		if r.OK() {
			okList = append(okList, r)
		}
	}

	fmt.Printf("扫描完成：%.1fs\n", elapsed.Seconds())
	fmt.Println("状态分布：")
	for _, st := range []string{probe.StatusOK, probe.StatusEdgeRestricted, probe.StatusForbidden, probe.StatusHTTPError, probe.StatusTLSError, probe.StatusTimeout, probe.StatusConnError} {
		if counts[st] > 0 {
			fmt.Printf("  %-16s %d\n", st, counts[st])
		}
	}
	if len(okList) == 0 {
		fmt.Println("\n没有任何可用 IP —— 检查域名是否正确、或换 -per-range 提高覆盖。")
		return 1
	}

	// 复测前 N 名，取中位 TTFB，避免单次抖动决定排名
	sort.Slice(okList, func(i, j int) bool { return okList[i].TTFBms < okList[j].TTFBms })
	if *top > 0 && *repeat > 1 {
		n := *top
		if n > len(okList) {
			n = len(okList)
		}
		for i := 0; i < n; i++ {
			vals := []float64{okList[i].TTFBms}
			for k := 1; k < *repeat; k++ {
				r := probe.One(mustAddr(okList[i].IP), opt)
				if r.OK() {
					vals = append(vals, r.TTFBms)
				}
			}
			okList[i].TTFBms = median(vals)
			fmt.Printf("\r复测中 %d/%d", i+1, n)
		}
		fmt.Print("\r" + strings.Repeat(" ", 24) + "\r")
		sort.Slice(okList, func(i, j int) bool { return okList[i].TTFBms < okList[j].TTFBms })
	}

	// 排名表
	const show = 20
	fmt.Printf("\n可用 IP 排名（共 %d 个可用，显示前 %d）\n", len(okList), min(show, len(okList)))
	fmt.Printf("%-3s %-16s %-6s %-8s %-8s %-8s\n", "#", "IP", "colo", "TCP", "TLS", "TTFB")
	for i, r := range okList {
		if i >= show {
			break
		}
		fmt.Printf("%-3d %-16s %-6s %-8.1f %-8.1f %-8.1f\n", i+1, r.IP, r.Colo, r.TCPms, r.TLSms, r.TTFBms)
	}

	// 按 colo 分组：这是「落点分布」的直接证据
	byColo := map[string][]float64{}
	for _, r := range okList {
		byColo[r.Colo] = append(byColo[r.Colo], r.TTFBms)
	}
	type coloStat struct {
		Colo    string
		Count   int
		Best    float64
		MedianF float64
	}
	var cs []coloStat
	for c, v := range byColo {
		sort.Float64s(v)
		cs = append(cs, coloStat{Colo: c, Count: len(v), Best: v[0], MedianF: median(v)})
	}
	sort.Slice(cs, func(i, j int) bool { return cs[i].Best < cs[j].Best })
	fmt.Printf("\n落点（colo）分布\n")
	fmt.Printf("%-8s %-6s %-10s %-10s\n", "colo", "数量", "最好TTFB", "中位TTFB")
	for _, c := range cs {
		fmt.Printf("%-8s %-6d %-10.1f %-10.1f\n", c.Colo, c.Count, c.Best, c.MedianF)
	}

	// 不可用样本取证（只看前几条，证明判定逻辑在工作）
	var bad []probe.Result
	for _, r := range results {
		if !r.OK() && len(bad) < 5 {
			bad = append(bad, r)
		}
	}
	if len(bad) > 0 {
		fmt.Printf("\n淘汰样本（示例）\n")
		for _, r := range bad {
			fmt.Printf("  %-16s %-16s %s\n", r.IP, r.Status, clipErr(r.Err, r.Body))
		}
	}

	if *jsonOut != "" {
		type dump struct {
			Domain  string         `json:"domain"`
			Path    string         `json:"path"`
			At      string         `json:"at"`
			Elapsed float64        `json:"elapsed_s"`
			Counts  map[string]int `json:"counts"`
			Results []probe.Result `json:"results"`
		}
		d := dump{
			Domain:  *domain,
			Path:    *path,
			At:      time.Now().Format(time.RFC3339),
			Elapsed: elapsed.Seconds(),
			Counts:  counts,
			Results: results,
		}
		b, _ := json.MarshalIndent(d, "", "  ")
		if err := os.WriteFile(*jsonOut, b, 0o644); err != nil {
			fmt.Fprintf(os.Stderr, "写 JSON 失败：%v\n", err)
		} else {
			fmt.Printf("\nJSON 已写入 %s\n", *jsonOut)
		}
	}
	return 0
}

func mustAddr(s string) netip.Addr {
	a, _ := netip.ParseAddr(s)
	return a
}

func median(v []float64) float64 {
	if len(v) == 0 {
		return 0
	}
	sort.Float64s(v)
	m := len(v) / 2
	if len(v)%2 == 0 {
		return (v[m-1] + v[m]) / 2
	}
	return v[m]
}

func clipErr(errStr, body string) string {
	s := errStr
	if s == "" {
		s = body
	}
	s = strings.Join(strings.Fields(s), " ")
	if len(s) > 80 {
		return s[:80]
	}
	return s
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
