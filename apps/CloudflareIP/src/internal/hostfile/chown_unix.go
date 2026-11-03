//go:build unix

package hostfile

import (
	"os"
	"syscall"
)

func chown(path string, st os.FileInfo) error {
	if s, ok := st.Sys().(*syscall.Stat_t); ok {
		return os.Chown(path, int(s.Uid), int(s.Gid))
	}
	return nil
}
