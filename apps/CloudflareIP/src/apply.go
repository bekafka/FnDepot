package main

import (
	"flag"
	"fmt"
	"os"
	"strings"
	"time"

	"cloudflareip/internal/hostfile"
)

// cmdApply 把选定的 IP 写进 /etc/hosts 的受管区块。
//
// 默认只做 dry-run：真正的落盘需要 root，且改的是全机解析行为，
// 不能因为一次手抖把机器搞成解析全挂。
func cmdApply(args []string) int {
	fs := flag.NewFlagSet("apply", flag.ExitOnError)
	domains := fs.String("domains", "", "域名列表，逗号分隔")
	ips := fs.String("ips", "", "IP 列表，逗号分隔；第一个用作所有域名的目标")
	hostsPath := fs.String("hosts", "/etc/hosts", "hosts 文件路径")
	stateDir := fs.String("state", expandHome("~/.local/state/cfpick"), "备份目录")
	dryRun := fs.Bool("dry-run", true, "只打印将要写入的内容（默认开启）")
	write := fs.Bool("write", false, "真正落盘（需要 root）")
	clear := fs.Bool("clear", false, "删除受管区块，回滚到系统默认解析")
	_ = fs.Parse(args)

	if *write {
		*dryRun = false
	}
	if *domains == "" {
		fmt.Fprintln(os.Stderr, "错误：-domains 必填")
		return 2
	}
	m := hostfile.Manager{Path: *hostsPath, StateDir: *stateDir}

	// 清空受管区块
	if *clear {
		cur, found, err := m.Current()
		if err != nil {
			fmt.Fprintf(os.Stderr, "读取 %s 失败：%v\n", *hostsPath, err)
			return 1
		}
		if !found {
			fmt.Printf("%s 里没有受管区块，无需清理。\n", *hostsPath)
			return 0
		}
		fmt.Printf("将删除受管区块（当前 %d 条）：\n", len(cur))
		for _, e := range cur {
			fmt.Printf("  - %s %s\n", e.IP, e.Domain)
		}
		if *dryRun {
			fmt.Println("\n(dry-run) 加 -write 才会真正删除。")
			return 0
		}
		changed, err := m.Clear()
		if err != nil {
			fmt.Fprintf(os.Stderr, "清理失败：%v\n", err)
			return 1
		}
		if changed {
			fmt.Println("已删除受管区块，解析回到系统默认。")
		} else {
			fmt.Println("无需改动。")
		}
		return 0
	}

	if *ips == "" {
		fmt.Fprintln(os.Stderr, "错误：-ips 必填（先跑 cfpick page 选出来）")
		return 2
	}
	var ipList []string
	for _, s := range strings.Split(*ips, ",") {
		if s = strings.TrimSpace(s); s != "" {
			ipList = append(ipList, s)
		}
	}
	if len(ipList) == 0 {
		fmt.Fprintln(os.Stderr, "错误：-ips 解析为空")
		return 2
	}
	best := ipList[0]

	var entries []hostfile.Entry
	for _, d := range strings.Split(*domains, ",") {
		if d = strings.TrimSpace(d); d != "" {
			entries = append(entries, hostfile.Entry{IP: best, Domain: d})
		}
	}

	meta := fmt.Sprintf("updated %s · src=%s", time.Now().Format(time.RFC3339), best)
	block := hostfile.Render(entries, meta)

	cur, found, err := m.Current()
	if err != nil && !os.IsNotExist(err) {
		fmt.Fprintf(os.Stderr, "读取 %s 失败：%v\n", *hostsPath, err)
		return 1
	}

	fmt.Printf("目标文件 : %s%s\n", *hostsPath, map[bool]string{true: "（已有受管区块）", false: "（将新建受管区块）"}[found])
	fmt.Printf("将写入 :\n\n%s\n", indent(block))
	if found {
		fmt.Printf("当前区块 :\n\n%s\n", indent(hostfile.Render(cur, "(现有内容)")))
	}
	if len(ipList) > 1 {
		fmt.Printf("备选（按顺序，守护切换时使用）: %s\n", strings.Join(ipList[1:], " → "))
	}

	if *dryRun {
		fmt.Println("(dry-run) 未改动任何文件。确认无误后以 root 执行同一命令并加 -write。")
		return 0
	}

	changed, err := m.Apply(entries, meta)
	if err != nil {
		fmt.Fprintf(os.Stderr, "写入失败：%v\n", err)
		return 1
	}
	if !changed {
		fmt.Println("内容与现有区块一致，未改动磁盘（幂等）。")
		return 0
	}
	fmt.Printf("已写入 %d 条记录，写后校验通过。\n", len(entries))
	fmt.Println("验证：getent hosts " + entries[0].Domain)
	return 0
}

func indent(s string) string {
	var b strings.Builder
	for _, line := range strings.Split(strings.TrimRight(s, "\n"), "\n") {
		b.WriteString("    " + line + "\n")
	}
	return strings.TrimRight(b.String(), "\n")
}

func expandHome(p string) string {
	if strings.HasPrefix(p, "~/") {
		if h, err := os.UserHomeDir(); err == nil {
			return h + p[1:]
		}
	}
	return p
}
