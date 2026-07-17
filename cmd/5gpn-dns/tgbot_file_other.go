//go:build !linux

package main

import "io/fs"

func validateTGBotFileSecurity(_ string, _ fs.FileInfo) error {
	return nil
}
