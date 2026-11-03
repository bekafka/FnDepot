package main

import (
	"context"
	_ "embed"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"cloudflareip/internal/hostfile"
	"cloudflareip/internal/state"
)

//go:embed web_ui/index.html
var indexHTML []byte

var domainRE = regexp.MustCompile(`^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$`)

const maxDomains = 20

func serveUI(rt *runtime, store *state.Store, cfgPath string, write bool) *http.Server {
	mux := http.NewServeMux()

	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("Cache-Control", "no-store")
		_, _ = w.Write(indexHTML)
	})

	mux.HandleFunc("/api/state", func(w http.ResponseWriter, r *http.Request) {
		if !sameOrigin(r) {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		st := store.Snapshot()
		st.Domains = rt.get().Domains
		st.Mode = "preview"
		if write {
			st.Mode = "write"
		}
		st.TestingDomains = rt.testingDomains()
		st.Testing = len(st.TestingDomains) > 0
		st.ProgressByDom = rt.progressMap()
		if st.Testing {
			st.Progress = st.ProgressByDom[st.TestingDomains[0]]
		}
		writeJSON(w, st)
	})

	mux.HandleFunc("/api/hosts", func(w http.ResponseWriter, r *http.Request) {
		if !sameOrigin(r) {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		writeJSON(w, collectHosts(rt.get()))
	})

	// 添加 / 删除域名（允许清空）
	mux.HandleFunc("/api/domains", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		if !sameOrigin(r) {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		var body struct {
			Domains []string `json:"domains"`
		}
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 8<<10)).Decode(&body); err != nil {
			writeJSONStatus(w, http.StatusBadRequest, map[string]string{"error": "请求格式不正确"})
			return
		}
		clean, err := validateDomains(body.Domains)
		if err != nil {
			writeJSONStatus(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
			return
		}
		if err := saveDomains(cfgPath, clean); err != nil {
			writeJSONStatus(w, http.StatusInternalServerError, map[string]string{"error": "保存失败：" + err.Error()})
			return
		}
		rt.setDomains(clean)

		// 删掉的域名，其结果也一并清掉
		keep := map[string]bool{}
		for _, d := range clean {
			keep[d] = true
		}
		store.Update(func(st *state.State) {
			st.Domains = clean
			var rs []state.DomainResult
			for _, res := range st.Results {
				if keep[res.Domain] {
					rs = append(rs, res)
				}
			}
			st.Results = rs
		})
		logf("域名更新：%v", clean)
		writeJSONStatus(w, http.StatusOK, map[string]any{"domains": clean, "ok": true})
	})

	// 测速（同步执行：前端会等这一个请求返回，等不到超时也够用）
	mux.HandleFunc("/api/test", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		if !sameOrigin(r) {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		var body struct {
			Domain     string `json:"domain"`
			ScreenOnly bool   `json:"screen_only"`
		}
		_ = json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10)).Decode(&body)
		if len(rt.get().Domains) == 0 {
			writeJSONStatus(w, http.StatusBadRequest, map[string]string{"error": "先添加一个域名"})
			return
		}
		domain := strings.TrimSpace(body.Domain)
		targets := []string{domain}
		if domain == "" {
			targets = rt.get().Domains
		}
		if rt.isTestingDomain(targets) {
			writeJSONStatus(w, http.StatusConflict, map[string]string{"error": "这个域名正在测速中"})
			return
		}
		go func() {
			// 测速里任何 panic 都不能把整个服务带走，也不能把 testing 卡成 true
			defer func() {
				if r := recover(); r != nil {
					logf("测速异常退出：%v", r)
					rt.endTest(targets)
					store.Update(func(st *state.State) { st.LastError = "测速异常退出，请再试一次" })
				}
			}()
			if _, err := runTest(rt, store, write, domain, body.ScreenOnly); err != nil {
				logf("测速失败：%v", err)
				store.Update(func(st *state.State) { st.LastError = err.Error() })
			}
		}()
		writeJSONStatus(w, http.StatusAccepted, map[string]any{"ok": true})
	})

	// 删除 hosts 里某一条本工具写入的记录
	mux.HandleFunc("/api/hosts/delete", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		if !sameOrigin(r) {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		var body struct {
			IP     string `json:"ip"`
			Domain string `json:"domain"`
		}
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10)).Decode(&body); err != nil {
			writeJSONStatus(w, http.StatusBadRequest, map[string]string{"error": "请求格式不正确"})
			return
		}
		ip, domain := strings.TrimSpace(body.IP), strings.TrimSpace(body.Domain)
		if net.ParseIP(ip) == nil || domain == "" {
			writeJSONStatus(w, http.StatusBadRequest, map[string]string{"error": "IP 或域名不对"})
			return
		}
		if !write {
			writeJSONStatus(w, http.StatusForbidden,
				map[string]string{"error": "当前是预览模式，用 sudo ./cloudflareip -write 打开后才能改 hosts"})
			return
		}
		if err := deleteManaged(rt, ip, domain); err != nil {
			code := http.StatusInternalServerError
			if _, ok := err.(errString); ok {
				code = http.StatusNotFound
			}
			writeJSONStatus(w, code, map[string]string{"error": humanErr(err)})
			return
		}
		writeJSONStatus(w, http.StatusOK, map[string]any{"ok": true})
	})

	// 清空历史（不动域名与 hosts）
	mux.HandleFunc("/api/history/clear", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		if !sameOrigin(r) {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		store.Update(func(st *state.State) { st.History = nil })
		logf("历史已清空")
		writeJSONStatus(w, http.StatusOK, map[string]any{"ok": true})
	})

	mux.HandleFunc("/api/apply", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		if !sameOrigin(r) {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		var body struct {
			Domain string `json:"domain"`
			IP     string `json:"ip"`
		}
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10)).Decode(&body); err != nil {
			writeJSONStatus(w, http.StatusBadRequest, map[string]string{"error": "请求格式不正确"})
			return
		}
		domain := strings.TrimSpace(body.Domain)
		ip := strings.TrimSpace(body.IP)
		if ip != "" && net.ParseIP(ip) == nil {
			writeJSONStatus(w, http.StatusBadRequest, map[string]string{"error": "IP 格式不对"})
			return
		}
		if !write {
			writeJSONStatus(w, http.StatusForbidden,
				map[string]string{"error": "当前是预览模式，关掉后用 sudo ./cloudflareip -write 重新打开才能应用"})
			return
		}
		if err := applyNow(rt, store, domain, ip); err != nil {
			writeJSONStatus(w, http.StatusInternalServerError, map[string]string{"error": humanErr(err)})
			return
		}
		writeJSONStatus(w, http.StatusOK, map[string]any{"ok": true})
	})

	mux.HandleFunc("/api/restore", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		if !sameOrigin(r) {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		if !write {
			writeJSONStatus(w, http.StatusForbidden,
				map[string]string{"error": "当前是预览模式，用 sudo ./cloudflareip -write 打开后才能还原"})
			return
		}
		if err := restoreNow(rt, store); err != nil {
			writeJSONStatus(w, http.StatusInternalServerError, map[string]string{"error": humanErr(err)})
			return
		}
		writeJSONStatus(w, http.StatusOK, map[string]any{"ok": true})
	})

	srv := &http.Server{Addr: rt.get().Listen, Handler: mux, ReadHeaderTimeout: 10 * time.Second}
	if host, _, err := net.SplitHostPort(srv.Addr); err == nil && host != "127.0.0.1" && host != "localhost" && host != "::1" {
		logf("提醒：网页监听在 %s，能访问它的人都能改域名，别暴露到公网", srv.Addr)
	}
	go func() {
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			fmt.Fprintf(os.Stderr, "网页启动失败：%v\n如果之前已经启动过，请先关掉旧进程再启动。\n", err)
			os.Exit(1)
		}
	}()
	return srv
}

func applyNow(rt *runtime, store *state.Store, domain, ip string) error {
	cfg := rt.get()
	rs := store.Snapshot().Results
	if len(rs) == 0 {
		return errString("还没有测速结果")
	}
	entries := buildEntries(cfg, rs, domain, ip)
	if len(entries) == 0 {
		return errString("没有可写入的节点")
	}
	rt.wmu.Lock()
	mgr := hostfile.Manager{Path: cfg.HostsPath, StateDir: filepath.Join(configDir(), "backup")}
	_, err := mgr.Apply(entries, fmt.Sprintf("manual %s", time.Now().Format(time.RFC3339)))
	rt.wmu.Unlock()
	if err != nil {
		return err
	}
	setAppliedMap(rt, store, rs, domain, ip)
	store.AddRecord(state.Record{
		Domain: domain, At: time.Now().Format(time.RFC3339), BestIP: ip,
		Note: "已应用", Applied: true,
	})
	logf("已应用%s → %s", pick(domain, "（全部域名）"), ip)
	return nil
}

// deleteManaged 从受管区块里删掉一条记录（其余保持原样，删空则整块移除）。
func deleteManaged(rt *runtime, ip, domain string) error {
	cfg := rt.get()
	rt.wmu.Lock()
	defer rt.wmu.Unlock()
	mgr := hostfile.Manager{Path: cfg.HostsPath, StateDir: filepath.Join(configDir(), "backup")}
	cur, found, err := mgr.Current()
	if err != nil {
		return err
	}
	if !found {
		return errString("hosts 里没有本工具写入的记录")
	}
	var keep []hostfile.Entry
	removed := false
	for _, e := range cur {
		if e.IP == ip && e.Domain == domain {
			removed = true
			continue
		}
		keep = append(keep, e)
	}
	if !removed {
		return errString("没找到这条记录")
	}
	if len(keep) == 0 {
		_, err = mgr.Clear()
	} else {
		_, err = mgr.Apply(keep, fmt.Sprintf("manual %s", time.Now().Format(time.RFC3339)))
	}
	if err != nil {
		return err
	}
	logf("已从 hosts 删除：%s %s", ip, domain)
	return nil
}

func restoreNow(rt *runtime, store *state.Store) error {
	cfg := rt.get()
	rt.wmu.Lock()
	mgr := hostfile.Manager{Path: cfg.HostsPath, StateDir: filepath.Join(configDir(), "backup")}
	_, err := mgr.Clear()
	rt.wmu.Unlock()
	if err != nil {
		return err
	}
	rt.setApplied(map[string]string{})
	store.Update(func(st *state.State) { st.Current = state.Current{} })
	store.AddRecord(state.Record{At: time.Now().Format(time.RFC3339), BestIP: "-", Note: "已还原默认"})
	logf("已还原为系统默认解析")
	return nil
}

func pick(s, dflt string) string {
	if s == "" {
		return dflt
	}
	return s
}

type hostsResp struct {
	Path      string            `json:"path"`
	Exists    bool              `json:"exists"`
	Rows      []hostRow         `json:"rows"`
	Managed   []hostRow         `json:"managed"`
	Effective map[string]string `json:"effective"`
	Matches   map[string]bool   `json:"matches"`
	Error     string            `json:"error,omitempty"`
}

type hostRow struct {
	IP      string `json:"ip"`
	Names   string `json:"names"`
	Managed bool   `json:"managed"`
	Comment bool   `json:"comment,omitempty"`
	Text    string `json:"text,omitempty"`
}

func collectHosts(cfg Config) hostsResp {
	out := hostsResp{Path: cfg.HostsPath, Effective: map[string]string{}, Matches: map[string]bool{},
		Rows: []hostRow{}, Managed: []hostRow{}}
	data, err := os.ReadFile(cfg.HostsPath)
	if err != nil {
		out.Error = err.Error()
		return out
	}
	out.Exists = true

	inManaged := false
	for _, raw := range strings.Split(string(data), "\n") {
		line := strings.TrimSpace(raw)
		if line == "" {
			continue
		}
		switch {
		case strings.HasPrefix(line, "# >>> cloudflareip"):
			inManaged = true
			out.Rows = append(out.Rows, hostRow{Comment: true, Managed: true, Text: line, Names: line})
			continue
		case strings.HasPrefix(line, "# <<< cloudflareip"):
			inManaged = false
			out.Rows = append(out.Rows, hostRow{Comment: true, Managed: true, Text: line, Names: line})
			continue
		case strings.HasPrefix(line, "#"):
			out.Rows = append(out.Rows, hostRow{Comment: true, Text: line, Names: line})
			continue
		}
		f := strings.Fields(line)
		if len(f) < 2 {
			continue
		}
		row := hostRow{IP: f[0], Names: strings.Join(f[1:], " "), Managed: inManaged, Text: line}
		out.Rows = append(out.Rows, row)
		if inManaged {
			out.Managed = append(out.Managed, row)
		}
	}

	for _, row := range out.Managed {
		for _, name := range strings.Fields(row.Names) {
			ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			ips, err := net.DefaultResolver.LookupHost(ctx, name)
			cancel()
			if err == nil && len(ips) > 0 {
				out.Effective[name] = ips[0]
				out.Matches[name] = sameIP(ips, row.IP)
			}
		}
	}
	return out
}

func sameIP(ips []string, want string) bool {
	for _, ip := range ips {
		if ip == want {
			return true
		}
	}
	return false
}

func sameOrigin(r *http.Request) bool {
	o := r.Header.Get("Origin")
	if o == "" {
		return true
	}
	h := r.Host
	return o == "http://"+h || o == "https://"+h
}

func writeJSON(w http.ResponseWriter, v any) { writeJSONStatus(w, http.StatusOK, v) }

func writeJSONStatus(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

// cleanDomain 把 https://gemini.fnnas.bond/ 、gemini.fnnas.bond:443 之类收敛成裸域名。
func cleanDomain(raw string) string {
	s := strings.TrimSpace(raw)
	if i := strings.Index(s, "://"); i >= 0 {
		s = s[i+3:]
	}
	if i := strings.IndexAny(s, "/?#"); i >= 0 {
		s = s[:i]
	}
	if i := strings.LastIndex(s, "@"); i >= 0 {
		s = s[i+1:]
	}
	if host, _, err := net.SplitHostPort(s); err == nil {
		s = host
	}
	s = strings.TrimSuffix(s, ".")
	return strings.ToLower(strings.TrimSpace(s))
}

// validateDomains 允许空列表（删光也算合法）。
func validateDomains(in []string) ([]string, error) {
	if len(in) > maxDomains {
		return nil, errString("域名最多 20 个")
	}
	seen := map[string]bool{}
	out := []string{}
	for _, d := range in {
		d = cleanDomain(d)
		if d == "" || seen[d] {
			continue
		}
		if len(d) > 253 || !domainRE.MatchString(d) {
			return nil, errString("“" + d + "” 不像一个域名")
		}
		seen[d] = true
		out = append(out, d)
	}
	return out, nil
}

func saveDomains(cfgPath string, domains []string) error {
	data, err := os.ReadFile(cfgPath)
	if err != nil {
		return err
	}
	var cfg Config
	if err := json.Unmarshal(data, &cfg); err != nil {
		return err
	}
	cfg.Domains = domains
	out, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return err
	}
	out = append(out, '\n')
	tmp, err := os.CreateTemp(filepath.Dir(cfgPath), ".config-*")
	if err != nil {
		return err
	}
	name := tmp.Name()
	if _, err := tmp.Write(out); err != nil {
		tmp.Close()
		_ = os.Remove(name)
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		_ = os.Remove(name)
		return err
	}
	tmp.Close()
	if st, err := os.Stat(cfgPath); err == nil {
		_ = os.Chmod(name, st.Mode().Perm())
	}
	return os.Rename(name, cfgPath)
}

func humanErr(err error) string {
	msg := err.Error()
	if strings.Contains(msg, "permission denied") {
		return "没有权限修改 hosts，请用 sudo 启动"
	}
	return msg
}

type errString string

func (e errString) Error() string { return string(e) }
