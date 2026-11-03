// Package candidates 提供 Cloudflare 边缘 IP 的候选池。
//
// 候选不是「越多越好」：CF 全网边缘有上万个地址，但真正参与 Anycast HTTP 服务
// 的只是其中很窄的一部分（官方公布的 15 个 IPv4 段）。本包按段均匀抽样，
// 保证覆盖面而不是堆数量。
package candidates

import (
	"fmt"
	"net/netip"
)

// DefaultRanges 是 Cloudflare 官方公布的 IPv4 段（https://www.cloudflare.com/ips-v4）。
// 顺序按经验上「容易被调度到东亚机房」的段靠前排列，抽样时也会先取这些段。
var DefaultRanges = []string{
	"104.16.0.0/13",  // 104.16–104.23，绝大多数 zone 的默认解析就在这里
	"172.64.0.0/13",  // 172.64–172.71
	"162.158.0.0/15", // 162.158–162.159
	"162.159.0.0/16", // 部分「受限边缘」也在这里，必须靠 1034 判定筛掉
	"188.114.96.0/20",
	"190.93.240.0/20",
	"198.41.128.0/17",
	"141.101.64.0/18",
	"108.162.192.0/18",
	"173.245.48.0/20",
	"131.0.72.0/22",
	"103.21.244.0/22",
	"103.22.200.0/22",
	"103.31.4.0/22",
	"197.234.240.0/22",
	"104.24.0.0/14",
}

// Sample 在每个段内均匀抽取 perRange 个地址，返回去重后的候选列表。
//
// 用均匀抽样而不是取段首：段首地址（x.y.0.1）经常是不对外服务的网络地址，
// 直接取会把大量候选浪费在死地址上。
func Sample(perRange int) ([]netip.Addr, error) {
	if perRange < 1 {
		return nil, fmt.Errorf("perRange 必须 >= 1")
	}
	seen := make(map[netip.Addr]struct{})
	var out []netip.Addr

	for _, cidr := range DefaultRanges {
		p, err := netip.ParsePrefix(cidr)
		if err != nil {
			return nil, fmt.Errorf("解析段 %s: %w", cidr, err)
		}
		p = p.Masked()
		total := prefixSize(p)
		if total < 2 {
			continue
		}
		n := perRange
		if total-2 < uint64(n) {
			n = int(total - 2)
		}
		if n <= 0 {
			continue
		}
		base := p.Addr()
		for i := 1; i <= n; i++ {
			// 跳过网络地址与广播地址，按等距步长取样
			step := total / uint64(n+1)
			off := step * uint64(i)
			addr := addOffset(base, off)
			if !p.Contains(addr) {
				continue
			}
			if _, dup := seen[addr]; dup {
				continue
			}
			seen[addr] = struct{}{}
			out = append(out, addr)
		}
	}
	return out, nil
}

func prefixSize(p netip.Prefix) uint64 {
	bits := p.Bits()
	if bits < 0 || bits > 32 {
		return 0
	}
	return uint64(1) << uint(32-bits)
}

func addOffset(base netip.Addr, off uint64) netip.Addr {
	b := base.As4()
	v := uint64(b[0])<<24 | uint64(b[1])<<16 | uint64(b[2])<<8 | uint64(b[3])
	v += off
	return netip.AddrFrom4([4]byte{byte(v >> 24), byte(v >> 16), byte(v >> 8), byte(v)})
}
