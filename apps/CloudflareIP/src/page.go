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

	"cloudflareip/internal/probe"
)

// cmdPage 对给定 IP 列表做「真实页面」级测速。
//
// 为什么要单独一步：/cdn-cgi/trace 由边缘直接应答，只反映 1 个 RTT；
// 而真实页面要落到 Worker 执行，两者的排名可能完全不同（实测过：
// trace 第一名 SJC 217ms，实际页面 1.44s；trace 第五名 LAX 224ms，
// 实际页面反而 0.89s 最快）。所以最终选点必须以页面级 TTFB 为准。
func cmdPage(args []string) int {
	fs := flag.NewFlagSet("page", flag.ExitOnError)
	domain := fs.String("domain", "", "目标域名")
	path := fs.String("path", "/", "页面路径")
	ips := fs.String("ips", "", "候选 IP，逗号分隔")
	repeat := fs.Int("repeat", 5, "每个 IP 采样次数（取中位）")
	timeout := fs.Duration("timeout", 8*time.Second, "单次超时")
	jsonOut := fs.String("json", "", "结果 JSON 输出")
	_ = fs.Parse(args)

	if *domain == "" || *ips == "" {
		fmt.Fprintln(os.Stderr, "错误：-domain 与 -ips 必填")
		return 2
	}

	type row struct {
		IP      string
		Colo    string
		Status  string
		Samples []float64
		Median  float64
		Best    float64
		Worst   float64
		Fail    int
	}
	var rows []row

	for _, s := range strings.Split(*ips, ",") {
		s = strings.TrimSpace(s)
		if s == "" {
			continue
		}
		a, err := netip.ParseAddr(s)
		if err != nil {
			fmt.Fprintf(os.Stderr, "忽略非法 IP %q\n", s)
			continue
		}
		r := row{IP: s}
		for i := 0; i < *repeat; i++ {
			res := probe.One(a, probe.Options{Domain: *domain, Path: *path, Timeout: *timeout})
			if res.Code == 200 {
				r.Samples = append(r.Samples, res.TTFBms)
				r.Colo = res.Colo
			} else {
				r.Fail++
				if r.Status == "" {
					r.Status = res.Status
				}
			}
		}
		// 页面响应不含 colo，单独打一次 trace 补齐落点信息
		if len(r.Samples) > 0 {
			tr := probe.One(a, probe.Options{Domain: *domain, Path: "/cdn-cgi/trace", Timeout: *timeout})
			r.Colo = tr.Colo
		}
		if len(r.Samples) == 0 {
			r.Status = "全部失败"
			rows = append(rows, r)
			continue
		}
		sort.Float64s(r.Samples)
		r.Median = median(append([]float64{}, r.Samples...))
		r.Best = r.Samples[0]
		r.Worst = r.Samples[len(r.Samples)-1]
		r.Status = probe.StatusOK
		rows = append(rows, r)
	}

	sort.Slice(rows, func(i, j int) bool {
		if rows[i].Median == 0 {
			return false
		}
		if rows[j].Median == 0 {
			return true
		}
		return rows[i].Median < rows[j].Median
	})

	fmt.Printf("页面级测速：%s%s，每 IP 采样 %d 次（TTFB 不含 TCP/TLS）\n\n", *domain, *path, *repeat)
	fmt.Printf("%-3s %-16s %-6s %-9s %-9s %-9s %-6s\n", "#", "IP", "colo", "中位", "最好", "最差", "失败")
	for i, r := range rows {
		if r.Median == 0 {
			fmt.Printf("%-3d %-16s %-6s %-9s %-9s %-9s %-6d  [%s]\n", i+1, r.IP, "-", "-", "-", "-", r.Fail, r.Status)
			continue
		}
		fmt.Printf("%-3d %-16s %-6s %-9.0f %-9.0f %-9.0f %-6d\n",
			i+1, r.IP, r.Colo, r.Median, r.Best, r.Worst, r.Fail)
	}

	if *jsonOut != "" {
		b, _ := json.MarshalIndent(rows, "", "  ")
		if err := os.WriteFile(*jsonOut, b, 0o644); err != nil {
			fmt.Fprintf(os.Stderr, "写 JSON 失败：%v\n", err)
		} else {
			fmt.Printf("\nJSON 已写入 %s\n", *jsonOut)
		}
	}
	return 0
}
