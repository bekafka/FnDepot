package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"sort"
	"sync"
	"syscall"
	"time"

	"cloudflareip/internal/candidates"
	"cloudflareip/internal/hostfile"
	"cloudflareip/internal/probe"
	"cloudflareip/internal/state"
)

// Config 是全部配置项（JSON），默认在 ~/.config/cloudflareip/config.json。
type Config struct {
	Domains            []string `json:"domains"`
	HostsPath          string   `json:"hosts_path"`
	ProbePath          string   `json:"probe_path"`
	PagePath           string   `json:"page_path"`
	Listen             string   `json:"listen"`
	CandidatesPerRange int      `json:"candidates_per_range"`
	Conc               int      `json:"conc"`
	TimeoutS           int      `json:"timeout_s"`
	TopN               int      `json:"top_n"`
	Repeat             int      `json:"repeat"`
	IPsPerDomain       int      `json:"ips_per_domain"`
}

func configDir() string {
	if h, err := os.UserHomeDir(); err == nil {
		return filepath.Join(h, ".config", "cloudflareip")
	}
	return ".cloudflareip"
}

func defaultConfig() Config {
	return Config{
		Domains:            []string{},
		HostsPath:          "/etc/hosts",
		ProbePath:          "/cdn-cgi/trace",
		PagePath:           "/",
		Listen:             "127.0.0.1:17890",
		CandidatesPerRange: 8,
		Conc:               64,
		TimeoutS:           5,
		TopN:               6,
		Repeat:             3,
		IPsPerDomain:       3,
	}
}

func ensureConfig(path string) (bool, error) {
	if _, err := os.Stat(path); err == nil {
		return false, nil
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return false, err
	}
	data, err := json.MarshalIndent(defaultConfig(), "", "  ")
	if err != nil {
		return false, err
	}
	return true, os.WriteFile(path, append(data, '\n'), 0o644)
}

func (c *Config) withDefaults() {
	d := defaultConfig()
	if c.HostsPath == "" {
		c.HostsPath = d.HostsPath
	}
	if c.ProbePath == "" {
		c.ProbePath = d.ProbePath
	}
	if c.PagePath == "" {
		c.PagePath = d.PagePath
	}
	if c.Listen == "" {
		c.Listen = d.Listen
	}
	if c.CandidatesPerRange <= 0 {
		c.CandidatesPerRange = d.CandidatesPerRange
	}
	if c.Conc <= 0 {
		c.Conc = d.Conc
	}
	if c.TimeoutS <= 0 {
		c.TimeoutS = d.TimeoutS
	}
	if c.TopN <= 0 {
		c.TopN = d.TopN
	}
	if c.TopN > 6 {
		c.TopN = 6 // 结果最多展示 6 个
	}
	if c.Repeat <= 0 {
		c.Repeat = d.Repeat
	}
	if c.IPsPerDomain <= 0 {
		c.IPsPerDomain = d.IPsPerDomain
	}
	if c.IPsPerDomain > 3 {
		c.IPsPerDomain = 3
	}
}

// runtime 持有配置、当前应用的 IP，以及「正在测速」的互斥。
type runtime struct {
	mu      sync.RWMutex
	cfg     Config
	applied map[string]string
	wmu     sync.Mutex // 串行化 hosts 写入
	tmu     sync.Mutex // 保护 testing/prog 与结果合并（每个域名可各跑各的）
	testing map[string]bool
	prog    map[string]string
}

// beginTest 按域名占位；任何一个域名已在测就返回 false（只拦同一个域名）。
func (r *runtime) beginTest(domains []string) bool {
	r.tmu.Lock()
	defer r.tmu.Unlock()
	if r.testing == nil {
		r.testing = map[string]bool{}
	}
	if r.prog == nil {
		r.prog = map[string]string{}
	}
	for _, d := range domains {
		if r.testing[d] {
			return false
		}
	}
	for _, d := range domains {
		r.testing[d] = true
		r.prog[d] = "准备中…"
	}
	return true
}

func (r *runtime) endTest(domains []string) {
	r.tmu.Lock()
	for _, d := range domains {
		delete(r.testing, d)
		delete(r.prog, d)
	}
	r.tmu.Unlock()
}

func (r *runtime) isTestingDomain(domains []string) bool {
	r.tmu.Lock()
	defer r.tmu.Unlock()
	for _, d := range domains {
		if r.testing[d] {
			return true
		}
	}
	return false
}

func (r *runtime) testingDomains() []string {
	r.tmu.Lock()
	defer r.tmu.Unlock()
	out := make([]string, 0, len(r.testing))
	for d := range r.testing {
		out = append(out, d)
	}
	sort.Strings(out)
	return out
}

func (r *runtime) setProgressFor(domain, msg string) {
	r.tmu.Lock()
	if r.prog == nil {
		r.prog = map[string]string{}
	}
	r.prog[domain] = msg
	r.tmu.Unlock()
}

func (r *runtime) progressMap() map[string]string {
	r.tmu.Lock()
	defer r.tmu.Unlock()
	out := make(map[string]string, len(r.prog))
	for k, v := range r.prog {
		out[k] = v
	}
	return out
}

func (r *runtime) get() Config {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.cfg
}

func (r *runtime) setDomains(list []string) {
	r.mu.Lock()
	r.cfg.Domains = append([]string(nil), list...)
	r.mu.Unlock()
}

func (r *runtime) setApplied(m map[string]string) {
	r.mu.Lock()
	r.applied = m
	r.mu.Unlock()
}

// cmdDaemon 是一次性程序：起网页 → 你操作 → Ctrl+C 退出。没有后台循环。
func cmdDaemon(args []string) int {
	fs := flag.NewFlagSet("cloudflareip", flag.ExitOnError)
	cfgPath := fs.String("config", "", "配置文件路径（默认 ~/.config/cloudflareip/config.json）")
	write := fs.Bool("write", false, "允许写入 hosts（默认只预览）")
	listen := fs.String("listen", "", "网页监听地址")
	noUI := fs.Bool("no-ui", false, "不开网页，直接测一轮并应用后退出")
	_ = fs.Parse(args)

	path := *cfgPath
	if path == "" {
		path = filepath.Join(configDir(), "config.json")
	}
	created, err := ensureConfig(path)
	if err != nil {
		fmt.Fprintf(os.Stderr, "创建配置失败：%v\n", err)
		return 1
	}
	data, err := os.ReadFile(path)
	if err != nil {
		fmt.Fprintf(os.Stderr, "读取配置失败：%v\n", err)
		return 1
	}
	var cfg Config
	if err := json.Unmarshal(data, &cfg); err != nil {
		fmt.Fprintf(os.Stderr, "配置格式错误：%v\n", err)
		return 1
	}
	cfg.withDefaults()
	if *listen != "" {
		cfg.Listen = *listen
	}

	rt := &runtime{cfg: cfg, applied: map[string]string{}, testing: map[string]bool{}, prog: map[string]string{}}
	store := state.New(filepath.Dir(path))
	store.Update(func(st *state.State) {
		st.Mode = "preview"
		if *write {
			st.Mode = "write"
		}
		st.Domains = cfg.Domains
		st.HostsPath = cfg.HostsPath
		st.IPsPerDomain = cfg.IPsPerDomain
	})

	if *noUI {
		if len(cfg.Domains) == 0 {
			fmt.Fprintln(os.Stderr, "没有域名可测")
			return 1
		}
		rs, err := runTest(rt, store, *write, "", false)
		if err != nil {
			fmt.Fprintf(os.Stderr, "测速失败：%v\n", err)
			return 1
		}
		applyResults(rt, store, *write, rs, "", "")
		return 0
	}

	srv := serveUI(rt, store, path, *write)
	defer func() { _ = srv.Close() }()
	fmt.Printf("网页面板：http://%s/\n", rt.get().Listen)
	if created {
		fmt.Printf("已创建默认配置：%s\n", path)
	}
	if !*write {
		fmt.Println("预览模式：可以测速看结果，但不会改动 hosts（用 sudo 启动并加 -write 才能应用）。")
	}
	fmt.Println("按 Ctrl+C 退出。")
	if os.Getenv("NO_BROWSER") == "" {
		go openBrowser("http://" + rt.get().Listen + "/")
	}

	sigc := make(chan os.Signal, 1)
	signal.Notify(sigc, syscall.SIGINT, syscall.SIGTERM)
	<-sigc
	fmt.Println("\n已退出。")
	return 0
}

// runTest 对指定域名（空=全部）跑一轮测速，结果写进 state，返回最新结果集。
func runTest(rt *runtime, store *state.Store, write bool, only string, screenOnly bool) ([]state.DomainResult, error) {
	cfg := rt.get()
	targets := cfg.Domains
	if only != "" {
		targets = []string{only}
	}
	if len(targets) == 0 {
		return nil, fmt.Errorf("还没有域名")
	}
	if !rt.beginTest(targets) {
		return nil, fmt.Errorf("这个域名正在测速中")
	}
	defer rt.endTest(targets)
	logf("开始测速：%v", targets)

	publish := func(r state.DomainResult) {
		rt.tmu.Lock()
		defer rt.tmu.Unlock()
		merged := mergeResults(store.Snapshot().Results, []state.DomainResult{r})
		store.Update(func(st *state.State) {
			st.Results = merged
			if len(r.Candidates) > 0 {
				st.LastError = ""
			}
		})
	}

	rs, err := selectAll(cfg, targets, func(domain, msg string) { rt.setProgressFor(domain, msg) }, publish, screenOnly)
	if err != nil {
		return nil, err
	}
	var problems []string
	for _, r := range rs {
		top := "—"
		if len(r.Candidates) > 0 {
			top = fmt.Sprintf("%s %s %.0fms", r.Candidates[0].IP, r.Candidates[0].Colo, r.Candidates[0].TTFBms)
		}
		logf("  %-28s 可用 %d/%d  最优 %s", r.Domain, r.OKCount, r.Total, top)
		if len(r.Candidates) == 0 && r.Note != "" {
			logf("  %-28s %s", "", r.Note)
			problems = append(problems, r.Domain+"："+r.Note)
		}
	}

	// 与已有结果合并：只测一个域名时不动其它域名的结果
	merged := mergeResults(store.Snapshot().Results, rs)
	store.Update(func(st *state.State) {
		st.Results = merged
		st.LastError = ""
		if len(problems) > 0 {
			st.LastError = problems[0]
		}
	})
	recordResults(store, rs, write, "测速")
	return merged, nil
}

func mergeResults(old, fresh []state.DomainResult) []state.DomainResult {
	out := make([]state.DomainResult, 0, len(fresh))
	for _, f := range fresh {
		out = append(out, f)
	}
	for _, o := range old {
		found := false
		for _, f := range fresh {
			if f.Domain == o.Domain {
				found = true
				break
			}
		}
		if !found {
			out = append(out, o)
		}
	}
	return out
}

// selectAll 每个域名分别测（并行），互不影响。
func selectAll(cfg Config, domains []string, report func(domain, msg string), publish func(state.DomainResult), screenOnly bool) ([]state.DomainResult, error) {
	addrs, err := candidates.Sample(cfg.CandidatesPerRange)
	if err != nil {
		return nil, err
	}
	total := len(addrs)
	out := make([]state.DomainResult, len(domains))
	var wg sync.WaitGroup
	for i, d := range domains {
		wg.Add(1)
		go func(i int, domain string) {
			defer wg.Done()
			out[i] = selectOne(cfg, domain, addrs, total, publish, screenOnly, func(msg string) {
				if report != nil {
					report(domain, msg)
				}
			})
		}(i, d)
	}
	wg.Wait()
	return out, nil
}

// selectOne 用该域名做 SNI：先筛可用，再按该域名的页面级 TTFB 排序。
func selectOne(cfg Config, domain string, addrs []netip.Addr, total int, publish func(state.DomainResult), screenOnly bool, report func(string)) state.DomainResult {
	if report != nil {
		report(fmt.Sprintf("正在筛可用节点（共 %d 个候选）", total))
	}
	// 先用三次握手粗筛一遍：丢包严重时完整 TLS 很容易超时，而握手只要 1 个 RTT
	reach := tcpScreen(addrs, cfg.Conc)
	if report != nil {
		report(fmt.Sprintf("TCP 可达 %d/%d，正在验证…", len(reach), total))
	}
	if len(reach) == 0 {
		dr := state.DomainResult{Domain: domain, Total: total}
		dr.Note = selfCheck(cfg, domain, addrs)
		return dr
	}

	res := probe.Run(reach, probe.Options{
		Domain:  domain,
		Path:    cfg.ProbePath,
		Timeout: time.Duration(cfg.TimeoutS) * time.Second,
	}, cfg.Conc)

	var ok []probe.Result
	for _, r := range res {
		if r.OK() {
			ok = append(ok, r)
		}
	}
	dr := state.DomainResult{Domain: domain, OKCount: len(ok), Total: total}
	if len(ok) == 0 {
		dr.Note = selfCheck(cfg, domain, addrs)
		return dr
	}
	sort.Slice(ok, func(i, j int) bool { return ok[i].TTFBms < ok[j].TTFBms })
	if len(ok) > cfg.TopN {
		ok = ok[:cfg.TopN]
	}
	traceRanked := append([]probe.Result(nil), ok...)

	// 只初筛（「一键测速」用）：按边缘握手/colo 排名直接返回，不做页面复测
	if screenOnly {
		dr.OKCount = len(ok)
		for _, r := range traceRanked {
			dr.Candidates = append(dr.Candidates, state.Candidate{IP: r.IP, Colo: r.Colo, TTFBms: r.TTFBms})
		}
		dr.Stage = "初筛"
		if publish != nil {
			publish(dr)
		}
		return dr
	}

	// 初筛结果立刻可见：先用握手/colo 排名顶上去，别让人干等页面级复测
	if publish != nil {
		partial := state.DomainResult{Domain: domain, OKCount: len(ok), Total: total, Stage: "初筛"}
		for _, r := range ok {
			partial.Candidates = append(partial.Candidates, state.Candidate{IP: r.IP, Colo: r.Colo, TTFBms: r.TTFBms})
		}
		publish(partial)
	}

	pageOpt := probe.Options{Domain: domain, Path: cfg.PagePath, Timeout: 8 * time.Second}
	for i := range ok {
		if report != nil {
			report(fmt.Sprintf("可用 %d 个，正在复测页面 %d/%d", len(ok), i+1, len(ok)))
		}
		var vals []float64
		for k := 0; k < cfg.Repeat; k++ {
			r := probe.One(mustAddr(ok[i].IP), pageOpt)
			if r.Code == 200 {
				vals = append(vals, r.TTFBms)
			}
		}
		if len(vals) == 0 {
			ok[i].TTFBms = 1e9
			continue
		}
		ok[i].TTFBms = median(vals)
	}
	if report != nil {
		report("整理结果…")
	}
	sort.Slice(ok, func(i, j int) bool { return ok[i].TTFBms < ok[j].TTFBms })

	for _, r := range ok {
		if r.TTFBms >= 1e8 {
			continue
		}
		dr.Candidates = append(dr.Candidates, state.Candidate{IP: r.IP, Colo: r.Colo, TTFBms: r.TTFBms})
	}
	// 页面级全失败（该域名的 / 不返回 200）时退回边缘排名，不整域名丢弃
	if len(dr.Candidates) == 0 {
		for _, r := range traceRanked {
			dr.Candidates = append(dr.Candidates, state.Candidate{IP: r.IP, Colo: r.Colo, TTFBms: r.TTFBms})
		}
	}
	dr.Stage = "复测完成"
	if publish != nil {
		publish(dr)
	}
	return dr
}

// tcpScreen 只做 TCP 443 三次握手，返回连得上的 IP（比完整 TLS 抗丢包）。
func tcpScreen(addrs []netip.Addr, conc int) []netip.Addr {
	if conc <= 0 {
		conc = 32
	}
	sem := make(chan struct{}, conc)
	var mu sync.Mutex
	var out []netip.Addr
	var wg sync.WaitGroup
	for _, a := range addrs {
		wg.Add(1)
		go func(a netip.Addr) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			c, err := net.DialTimeout("tcp", net.JoinHostPort(a.String(), "443"), 4*time.Second)
			if err != nil {
				return
			}
			_ = c.Close()
			mu.Lock()
			out = append(out, a)
			mu.Unlock()
		}(a)
	}
	wg.Wait()
	return out
}

// selfCheck 一个候选都筛不出来时，用较长超时试连几个 IP，把真实耗时变成一句人话。
func selfCheck(cfg Config, domain string, addrs []netip.Addr) string {
	limit := 3
	if len(addrs) < limit {
		limit = len(addrs)
	}
	opt := probe.Options{Domain: domain, Path: cfg.ProbePath, Timeout: 15 * time.Second}
	var best probe.Result
	var bestOK bool
	for i := 0; i < limit; i++ {
		r := probe.One(addrs[i], opt)
		if r.Code == 200 && r.Colo != "" {
			if !bestOK || r.TTFBms < best.TTFBms {
				best, bestOK = r, true
			}
		}
	}
	if bestOK {
		if float64(cfg.TimeoutS*1000) <= best.TTFBms {
			return fmt.Sprintf("本机到 Cloudflare 现在很慢：试连 %s 首字节用了 %.0f ms，超过了 %ds 超时，所以全部候选都被判超时。检查本机网络/代理，或把 timeout_s 调大再试。",
				best.IP, best.TTFBms, cfg.TimeoutS)
		}
		return fmt.Sprintf("试连 %s 能通（%.0f ms），但其它候选在 %ds 超时内都没成功——现在线路抖动很大，把 timeout_s 调大或稍后重测。", best.IP, best.TTFBms, cfg.TimeoutS)
	}
	return fmt.Sprintf("本机现在连不上 Cloudflare 边缘：连续试连 %d 个 IP 都失败了。先确认本机网络是否正常，再重新测速。", limit)
}

func recordResults(store *state.Store, rs []state.DomainResult, write bool, note string) {
	for _, d := range rs {
		if len(d.Candidates) == 0 {
			continue
		}
		c := d.Candidates[0]
		store.AddRecord(state.Record{
			Domain: d.Domain, At: time.Now().Format(time.RFC3339),
			BestIP: c.IP, Colo: c.Colo, TTFBms: c.TTFBms,
			OKCount: d.OKCount, Total: d.Total, Note: note, Applied: write,
		})
	}
}

// applyResults 写入每个域名的前 N 个候选（overrideDomain/overrideIP 可指定某个域名优先用它）。
func applyResults(rt *runtime, store *state.Store, write bool, rs []state.DomainResult, overrideDomain, overrideIP string) bool {
	cfg := rt.get()
	entries := buildEntries(cfg, rs, overrideDomain, overrideIP)
	if len(entries) == 0 {
		return false
	}
	if !write {
		logf("[预览] 将写入 %d 条（用 sudo -write 才会真正写入）", len(entries))
		setAppliedMap(rt, store, rs, overrideDomain, overrideIP)
		return true
	}
	rt.wmu.Lock()
	mgr := hostfile.Manager{Path: cfg.HostsPath, StateDir: filepath.Join(configDir(), "backup")}
	_, err := mgr.Apply(entries, fmt.Sprintf("manual %s", time.Now().Format(time.RFC3339)))
	rt.wmu.Unlock()
	if err != nil {
		logf("写入 hosts 失败：%v（是否以 root 运行？）", err)
		return false
	}
	logf("已写入 %d 条 hosts 记录", len(entries))
	setAppliedMap(rt, store, rs, overrideDomain, overrideIP)
	store.AddRecord(state.Record{At: time.Now().Format(time.RFC3339), BestIP: "写了 " + fmt.Sprint(len(entries)) + " 条", Note: "应用"})
	return true
}

// preferredN 是「应用优选」写入的条数（主 + 2 备）。
const preferredN = 3

func buildEntries(cfg Config, rs []state.DomainResult, overrideDomain, overrideIP string) []hostfile.Entry {
	var entries []hostfile.Entry
	for _, d := range rs {
		ips := make([]string, 0, len(d.Candidates))
		for _, c := range d.Candidates {
			ips = append(ips, c.IP)
		}
		if d.Domain == overrideDomain && overrideIP != "" {
			ips = []string{overrideIP} // 明确点了某一条 → 只应用这一条
		}
		if len(ips) > preferredN {
			ips = ips[:preferredN]
		}
		for _, ip := range ips {
			entries = append(entries, hostfile.Entry{IP: ip, Domain: d.Domain})
		}
	}
	return entries
}

func setAppliedMap(rt *runtime, store *state.Store, rs []state.DomainResult, overrideDomain, overrideIP string) {
	m := map[string]string{}
	for _, d := range rs {
		if len(d.Candidates) == 0 {
			continue
		}
		ip := d.Candidates[0].IP
		if d.Domain == overrideDomain && overrideIP != "" {
			ip = overrideIP
		}
		m[d.Domain] = ip
	}
	rt.setApplied(m)
	if len(rs) > 0 && len(rs[0].Candidates) > 0 {
		c := rs[0].Candidates[0]
		store.Update(func(st *state.State) {
			st.Current = state.Current{IP: c.IP, Colo: c.Colo, TTFBms: c.TTFBms,
				Since: time.Now().Format(time.RFC3339), Health: "ok"}
		})
	}
}

func removeStr(list []string, s string) []string {
	var out []string
	for _, v := range list {
		if v != s {
			out = append(out, v)
		}
	}
	return out
}

func openBrowser(url string) {
	if os.Getenv("DISPLAY") == "" && os.Getenv("WAYLAND_DISPLAY") == "" {
		return
	}
	time.Sleep(400 * time.Millisecond)
	_ = exec.Command("xdg-open", url).Start()
}

func logf(format string, a ...any) {
	fmt.Fprintf(os.Stderr, "%s %s\n", time.Now().Format("15:04:05"), fmt.Sprintf(format, a...))
}
