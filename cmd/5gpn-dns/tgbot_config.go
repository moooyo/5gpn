package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
)

// tgbotSchemaVersion is the exact tgbot.json schema version accepted.
const tgbotSchemaVersion = 1

// TGBotConfig is the on-disk shape of /etc/5gpn/tgbot.json — the web-console
// managed runtime override for the Telegram bot's token + admin set. dns.env's
// TGBOT_TOKEN/TGBOT_ADMINS stay the install-time defaults; this file, when
// present, wins at startup and is rewritten by PUT /api/tgbot. It lives in the
// daemon-writable part of /etc/5gpn (the systemd sandbox keeps dns.env itself
// read-only), mirroring upstreams.json / ecs.json. The token is a secret, so the
// file is written 0600 and is NEVER echoed back by GET /api/tgbot.
type TGBotConfig struct {
	Version int     `json:"version"`
	Token   string  `json:"token"`
	Admins  []int64 `json:"admins"`
}

// TGBotView is the read model for GET /api/tgbot. It deliberately omits the raw
// token — a client only learns WHETHER one is set, never its value.
type TGBotView struct {
	AdminIDs  []int64 `json:"admins"`
	TokenSet  bool    `json:"token_set"`
	State     string  `json:"state"`
	LastError string  `json:"last_error,omitempty"`
}

// LoadTGBot reads the runtime tgbot-override file. A missing file (or an empty
// path — the override disabled) returns (nil, nil): dns.env values apply. A
// malformed file is an error the caller should log and ignore, never a reason to
// crash the sole resolver.
func LoadTGBot(path string) (*TGBotConfig, error) {
	if path == "" {
		return nil, nil
	}
	info, err := os.Lstat(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, fmt.Errorf("tgbot: inspect %s: %w", path, err)
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
		return nil, fmt.Errorf("tgbot: %s must be a regular non-symlink file", path)
	}
	if err := validateTGBotFileSecurity(path, info); err != nil {
		return nil, fmt.Errorf("tgbot: insecure %s: %w", path, err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("tgbot: read %s: %w", path, err)
	}
	var tc TGBotConfig
	if err := unmarshalStrictJSON(data, &tc); err != nil {
		return nil, fmt.Errorf("tgbot: parse %s: %w", path, err)
	}
	if tc.Version != tgbotSchemaVersion {
		return nil, fmt.Errorf("tgbot: %s: unsupported schema version %d (want %d)", path, tc.Version, tgbotSchemaVersion)
	}
	tc.Admins = normalizeAdminIDs(tc.Admins)
	return &tc, nil
}

// SaveTGBot atomically writes the runtime tgbot-override file (create-temp +
// rename, like upstreams.json / ecs.json) with 0600 permissions (it holds the
// bot token). An empty path means persistence is disabled and the save is a
// silent no-op.
func SaveTGBot(path string, tc TGBotConfig) error {
	if path == "" {
		return nil
	}
	tc.Version = tgbotSchemaVersion
	tc.Admins = normalizeAdminIDs(tc.Admins)
	data, err := json.MarshalIndent(tc, "", "  ")
	if err != nil {
		return fmt.Errorf("tgbot: marshal: %w", err)
	}
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, ".tgbot-*.tmp")
	if err != nil {
		return fmt.Errorf("tgbot: create temp in %s: %w", dir, err)
	}
	tmpPath := tmp.Name()
	// Tighten the temp file to 0600 BEFORE writing the token into it (CreateTemp
	// makes it 0600 already on Unix, but be explicit so the secret is never
	// briefly group/world-readable on a permissive umask).
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		os.Remove(tmpPath)
		return fmt.Errorf("tgbot: chmod %s: %w", tmpPath, err)
	}
	if _, err := tmp.Write(append(data, '\n')); err != nil {
		tmp.Close()
		os.Remove(tmpPath)
		return fmt.Errorf("tgbot: write %s: %w", tmpPath, err)
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		os.Remove(tmpPath)
		return fmt.Errorf("tgbot: sync %s: %w", tmpPath, err)
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmpPath)
		return fmt.Errorf("tgbot: close %s: %w", tmpPath, err)
	}
	if err := os.Rename(tmpPath, path); err != nil {
		os.Remove(tmpPath)
		return fmt.Errorf("tgbot: rename to %s: %w", path, err)
	}
	// The rename already published a complete 0600 file. Directory fsync is a
	// best-effort durability barrier: after publication, reporting failure would
	// make the supervisor keep the old live bot even though restart would load
	// the new file, creating a worse live/disk split that cannot be rolled back
	// safely here.
	if dirHandle, openErr := os.Open(dir); openErr == nil {
		_ = dirHandle.Sync()
		_ = dirHandle.Close()
	}
	return nil
}

// normalizeAdminIDs drops non-positive IDs (a Telegram user ID is always a
// positive int64) and duplicates, and returns them sorted for a stable on-disk
// and on-wire order.
func normalizeAdminIDs(ids []int64) []int64 {
	seen := make(map[int64]bool, len(ids))
	out := make([]int64, 0, len(ids))
	for _, id := range ids {
		if id <= 0 || seen[id] {
			continue
		}
		seen[id] = true
		out = append(out, id)
	}
	sort.Slice(out, func(i, j int) bool { return out[i] < out[j] })
	return out
}

// adminSetFromIDs turns an admin-ID slice into the map[int64]bool set the bot's
// isAdmin check uses.
func adminSetFromIDs(ids []int64) map[int64]bool {
	m := make(map[int64]bool, len(ids))
	for _, id := range ids {
		if id > 0 {
			m[id] = true
		}
	}
	return m
}

// adminIDsFromSet returns the sorted admin IDs of a set (for the API view and
// the supervisor's startup snapshot).
func adminIDsFromSet(m map[int64]bool) []int64 {
	out := make([]int64, 0, len(m))
	for id := range m {
		out = append(out, id)
	}
	return normalizeAdminIDs(out)
}
