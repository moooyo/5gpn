//go:build !linux

package main

// diskUsage is the non-Linux stub: statfs is Linux-specific, and 5gpn-dns only
// runs the bot's server-metrics card on the Linux gateway. On the Windows dev
// box (where `go test ./...` runs) there is no /proc and no statfs, so this
// returns (0,0) and systemMetrics omits the disk line. See disk_linux.go for
// the real implementation.
func diskUsage(path string) (used, total uint64) {
	return 0, 0
}
