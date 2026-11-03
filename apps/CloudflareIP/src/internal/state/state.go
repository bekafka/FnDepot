// Package state 把守护进程的运行态落成一份 JSON，供 CLI 查看与单页面板读取。
//
// 设计约束：
//   - 写入必须是原子的（临时文件 + rename），面板随时可能在读；
//   - 历史只保留最近 N 条，避免文件无限增长；
//   - 结构体字段全部导出，方便 `cat` + `jq` 直接看。
package state

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// MaxHistory 是历史测速记录的保留条数。
const MaxHistory = 50

// Candidate 是一条候选 IP 的测量结果。
type Candidate struct {
	IP     string  `json:"ip"`
	Colo   string  `json:"colo"`
	TTFBms float64 `json:"ttfb_ms"`
}

// DomainResult 是某个域名的测速结果（每个域名分开测，互不影响）。
type DomainResult struct {
	Domain     string      `json:"domain"`
	Candidates []Candidate `json:"candidates"`
	Note       string      `json:"note,omitempty"`
	Stage      string      `json:"stage,omitempty"`
	OKCount    int         `json:"ok_count"`
	Total      int         `json:"total"`
}

// Record 是一次选点/切换的历史记录。
type Record struct {
	Domain  string  `json:"domain,omitempty"`
	At      string  `json:"at"`
	BestIP  string  `json:"best_ip"`
	Colo    string  `json:"colo"`
	TTFBms  float64 `json:"ttfb_ms"`
	OKCount int     `json:"ok_count"`
	Total   int     `json:"total"`
	Note    string  `json:"note,omitempty"`
	Applied bool    `json:"applied"`
}

// Current 是当前生效的解析状态。
type Current struct {
	IP     string  `json:"ip"`
	Colo   string  `json:"colo"`
	TTFBms float64 `json:"ttfb_ms"`
	Since  string  `json:"since"`
	Health string  `json:"health"` // ok / failing / unknown
}

// State 是整份运行态。
type State struct {
	UpdatedAt      string            `json:"updated_at"`
	StartedAt      string            `json:"started_at"`
	Mode           string            `json:"mode"` // dry-run / write
	Domains        []string          `json:"domains"`
	HostsPath      string            `json:"hosts_path"`
	Current        Current           `json:"current"`
	Results        []DomainResult    `json:"results"`
	History        []Record          `json:"history"`
	NextRetest     string            `json:"next_retest,omitempty"`
	LastError      string            `json:"last_error,omitempty"`
	Testing        bool              `json:"testing"`
	TestingDomains []string          `json:"testing_domains,omitempty"`
	Progress       string            `json:"progress,omitempty"`
	ProgressByDom  map[string]string `json:"progress_by_domain,omitempty"`
	IPsPerDomain   int               `json:"ips_per_domain"`
	ProbeSec       int               `json:"probe_interval_s"`
	RetestSec      int               `json:"retest_interval_s"`
}

// Store 是带锁的状态容器。
type Store struct {
	mu   sync.Mutex
	path string
	st   State
}

// New 创建（或加载）状态存储。
func New(dir string) *Store {
	s := &Store{path: filepath.Join(dir, "state.json")}
	if data, err := os.ReadFile(s.path); err == nil {
		_ = json.Unmarshal(data, &s.st) // 读坏了就当空状态，不阻塞启动
	}
	now := time.Now().Format(time.RFC3339)
	s.st.UpdatedAt = now
	if s.st.StartedAt == "" {
		s.st.StartedAt = now
	}
	return s
}

// Path 返回状态文件路径。
func (s *Store) Path() string { return s.path }

// Update 在锁内修改状态并落盘。
func (s *Store) Update(fn func(*State)) {
	s.mu.Lock()
	defer s.mu.Unlock()
	fn(&s.st)
	s.st.UpdatedAt = time.Now().Format(time.RFC3339)
	s.persistLocked()
}

// Snapshot 返回状态副本。
func (s *Store) Snapshot() State {
	s.mu.Lock()
	defer s.mu.Unlock()
	cp := s.st
	cp.Domains = append([]string(nil), s.st.Domains...)
	cp.Results = append([]DomainResult(nil), s.st.Results...)
	cp.History = append([]Record(nil), s.st.History...)
	return cp
}

func (s *Store) persistLocked() {
	if err := os.MkdirAll(filepath.Dir(s.path), 0o750); err != nil {
		return
	}
	data, err := json.MarshalIndent(s.st, "", "  ")
	if err != nil {
		return
	}
	tmp, err := os.CreateTemp(filepath.Dir(s.path), ".state-*")
	if err != nil {
		return
	}
	name := tmp.Name()
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		_ = os.Remove(name)
		return
	}
	tmp.Close()
	_ = os.Chmod(name, 0o644)
	_ = os.Rename(name, s.path)
}

// AddRecord 追加一条历史（自动裁剪到 MaxHistory）。
func (s *Store) AddRecord(r Record) {
	s.Update(func(st *State) {
		st.History = append([]Record{r}, st.History...)
		if len(st.History) > MaxHistory {
			st.History = st.History[:MaxHistory]
		}
	})
}
