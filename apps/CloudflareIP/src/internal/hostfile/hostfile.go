// Package hostfile 把优选结果写进 /etc/hosts 的受管区块。
//
// 纪律（都是踩过的坑）：
//   - 只增删自己标记之间的那段，块外一字不动（别人的 hosts 内容可能由发行版、
//     容器运行时、别的工具维护，做行级手术必然出事）；
//   - 原子替换：同目录临时文件 + rename，避免写一半留个残缺 hosts；
//   - 幂等：内容没变就不落盘（mtime 不变，systemd-resolved 不会白白重载）；
//   - 写前备份、写后读回校验。
package hostfile

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const (
	beginMarker = "# >>> cloudflareip managed block (do not edit) >>>"
	endMarker   = "# <<< cloudflareip managed block <<<"
)

// Entry 是一条 hosts 记录。
type Entry struct {
	IP     string
	Domain string
}

// Manager 操作一个 hosts 文件。
type Manager struct {
	Path     string
	StateDir string // 非空则每次真正改动前备份原文件
}

// Render 生成受管区块文本（不含前后空行）。
func Render(entries []Entry, meta string) string {
	var b strings.Builder
	b.WriteString(beginMarker + "\n")
	if meta != "" {
		b.WriteString("# " + meta + "\n")
	}
	for _, e := range entries {
		b.WriteString(fmt.Sprintf("%-15s %s\n", e.IP, e.Domain))
	}
	b.WriteString(endMarker + "\n")
	return b.String()
}

// Current 返回当前受管区块里的条目；found 表示文件里存在区块。
func (m Manager) Current() (entries []Entry, found bool, err error) {
	data, err := os.ReadFile(m.Path)
	if err != nil {
		return nil, false, err
	}
	lines := strings.Split(string(data), "\n")
	in := false
	for _, line := range lines {
		switch {
		case strings.TrimSpace(line) == beginMarker:
			in, found = true, true
		case strings.TrimSpace(line) == endMarker:
			in = false
		case in && strings.TrimSpace(line) != "" && !strings.HasPrefix(strings.TrimSpace(line), "#"):
			f := strings.Fields(line)
			if len(f) >= 2 {
				entries = append(entries, Entry{IP: f[0], Domain: f[1]})
			}
		}
	}
	return entries, found, nil
}

// Apply 用 entries 替换受管区块。changed=false 表示内容本来就一致、没动磁盘。
func (m Manager) Apply(entries []Entry, meta string) (changed bool, err error) {
	orig, err := os.ReadFile(m.Path)
	if err != nil {
		return false, fmt.Errorf("读取 %s: %w", m.Path, err)
	}
	st, err := os.Stat(m.Path)
	if err != nil {
		return false, err
	}

	block := Render(entries, meta)
	oldText := string(orig)

	var next string
	if i := strings.Index(oldText, beginMarker); i >= 0 {
		j := strings.Index(oldText, endMarker)
		if j < 0 || j < i {
			return false, fmt.Errorf("受管区块标记不完整，拒绝改动；请人工检查 %s", m.Path)
		}
		j += len(endMarker)
		// 吃掉 endMarker 后面的换行
		if j < len(oldText) && oldText[j] == '\n' {
			j++
		}
		next = oldText[:i] + block + oldText[j:]
	} else {
		sep := ""
		if len(oldText) > 0 && !strings.HasSuffix(oldText, "\n") {
			sep = "\n"
		}
		if len(oldText) > 0 && !strings.HasSuffix(oldText, "\n\n") {
			sep += "\n"
		}
		next = oldText + sep + block
	}

	if next == oldText {
		return false, nil
	}
	if m.StateDir != "" {
		if _, err := Backup(m.Path, m.StateDir); err != nil {
			return false, fmt.Errorf("备份失败，拒绝改动: %w", err)
		}
	}

	dir := filepath.Dir(m.Path)
	tmp, err := os.CreateTemp(dir, ".hosts.cfpick-*")
	if err != nil {
		return false, fmt.Errorf("创建临时文件: %w（是否以 root 运行？）", err)
	}
	tmpName := tmp.Name()
	defer func() { _ = os.Remove(tmpName) }() // rename 成功后这里是 no-op

	if _, err := tmp.WriteString(next); err != nil {
		tmp.Close()
		return false, err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return false, err
	}
	if err := tmp.Close(); err != nil {
		return false, err
	}
	if err := os.Chmod(tmpName, st.Mode().Perm()); err != nil {
		return false, err
	}
	// rename 会改变 inode，属主继承自进程；以 root 运行时显式对齐原文件属主。
	if err := chownLike(tmpName, st); err != nil {
		return false, err
	}
	if err := os.Rename(tmpName, m.Path); err != nil {
		return false, fmt.Errorf("替换 %s: %w", m.Path, err)
	}

	// 写后读回校验
	got, found, err := m.Current()
	if err != nil || !found {
		return true, fmt.Errorf("写后校验失败：区块未写入")
	}
	if len(got) != len(entries) {
		return true, fmt.Errorf("写后校验失败：期望 %d 条，实际 %d 条", len(entries), len(got))
	}
	for i := range got {
		if got[i] != entries[i] {
			return true, fmt.Errorf("写后校验失败：第 %d 条期望 %v，实际 %v", i+1, entries[i], got[i])
		}
	}
	return true, nil
}

// Clear 删除受管区块（回滚到默认解析）。
func (m Manager) Clear() (bool, error) {
	orig, err := os.ReadFile(m.Path)
	if err != nil {
		return false, err
	}
	text := string(orig)
	i := strings.Index(text, beginMarker)
	if i < 0 {
		return false, nil
	}
	j := strings.Index(text, endMarker)
	if j < i {
		return false, fmt.Errorf("受管区块标记不完整，拒绝改动")
	}
	j += len(endMarker)
	if j < len(text) && text[j] == '\n' {
		j++
	}
	next := text[:i] + text[j:]
	// 只补一个缺失的结尾换行，不要把文件原有的空行吃掉
	if next != "" && !strings.HasSuffix(next, "\n") {
		next += "\n"
	}
	if next == text {
		return false, nil
	}
	if m.StateDir != "" {
		if _, err := Backup(m.Path, m.StateDir); err != nil {
			return false, fmt.Errorf("备份失败，拒绝改动: %w", err)
		}
	}
	return m.ApplyRaw(next)
}

// ApplyRaw 直接写入整份内容（供 Clear 复用原子写与备份）。
func (m Manager) ApplyRaw(next string) (bool, error) {
	st, err := os.Stat(m.Path)
	if err != nil {
		return false, err
	}
	dir := filepath.Dir(m.Path)
	tmp, err := os.CreateTemp(dir, ".hosts.cfpick-*")
	if err != nil {
		return false, err
	}
	tmpName := tmp.Name()
	defer func() { _ = os.Remove(tmpName) }()
	if _, err := tmp.WriteString(next); err != nil {
		tmp.Close()
		return false, err
	}
	tmp.Close()
	_ = os.Chmod(tmpName, st.Mode().Perm())
	_ = chownLike(tmpName, st)
	if err := os.Rename(tmpName, m.Path); err != nil {
		return false, err
	}
	return true, nil
}

// Backup 在改动前把当前 hosts 存一份到状态目录。
func Backup(hostsPath, stateDir string) (string, error) {
	data, err := os.ReadFile(hostsPath)
	if err != nil {
		return "", err
	}
	if err := os.MkdirAll(stateDir, 0o750); err != nil {
		return "", err
	}
	dst := filepath.Join(stateDir, fmt.Sprintf("hosts.bak.%s", time.Now().Format("20060102-150405.000000000")))
	if err := os.WriteFile(dst, data, 0o644); err != nil {
		return "", err
	}
	return dst, nil
}

func chownLike(path string, st os.FileInfo) error {
	// 仅在 Unix 上有意义；失败不致命（权限已由 chmod 处理）。
	return chown(path, st)
}
