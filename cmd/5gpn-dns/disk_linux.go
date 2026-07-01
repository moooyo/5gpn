//go:build linux

package main

import "syscall"

// diskUsage returns (used, total) bytes for the filesystem containing path,
// via statfs. Linux-only; see disk_other.go for the non-Linux stub. Returns
// (0,0) on any error so the caller (systemMetrics) simply drops the disk line.
func diskUsage(path string) (used, total uint64) {
	var st syscall.Statfs_t
	if err := syscall.Statfs(path, &st); err != nil {
		return 0, 0
	}
	bsize := uint64(st.Frsize)
	total = st.Blocks * bsize
	used = total - st.Bavail*bsize
	return used, total
}
