//go:build linux

package main

import (
	"fmt"
	"io/fs"
	"os"
	"syscall"
)

func validateTGBotFileSecurity(_ string, info fs.FileInfo) error {
	if info.Mode().Perm() != 0o600 {
		return fmt.Errorf("mode is %04o, want 0600", info.Mode().Perm())
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return fmt.Errorf("owner metadata unavailable")
	}
	if stat.Uid != uint32(os.Geteuid()) {
		return fmt.Errorf("owner uid is %d, want %d", stat.Uid, os.Geteuid())
	}
	return nil
}
