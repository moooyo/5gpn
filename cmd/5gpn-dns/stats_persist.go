package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"time"
)

// statsSchemaVersion is the exact stats.json schema version accepted.
const statsSchemaVersion = 1

// statsSnapshot is the serializable, cumulative-since-first-boot form of
// statsCounters. cache_entries is intentionally NOT included here: it's a
// live gauge (current cache occupancy), not a cumulative counter, so
// persisting/restoring it across a restart would be meaningless (the cache
// itself starts empty on every restart).
type statsSnapshot struct {
	Version         int    `json:"version"`
	Total           uint64 `json:"total"`
	Block           uint64 `json:"block"`
	ForceDirect     uint64 `json:"force_direct"`
	ForceProxy      uint64 `json:"force_proxy"`
	ChnrouteCN      uint64 `json:"chnroute_cn"`
	ChnrouteForeign uint64 `json:"chnroute_foreign"`
	ChinaOK         uint64 `json:"china_ok"`
	ChinaErr        uint64 `json:"china_err"`
	TrustOK         uint64 `json:"trust_ok"`
	TrustErr        uint64 `json:"trust_err"`
	// Observability counters (cumulative).
	CacheHits     uint64 `json:"cache_hits"`
	CacheMisses   uint64 `json:"cache_misses"`
	ChinaLatNanos uint64 `json:"china_lat_nanos"`
	ChinaLatCount uint64 `json:"china_lat_count"`
	TrustLatNanos uint64 `json:"trust_lat_nanos"`
	TrustLatCount uint64 `json:"trust_lat_count"`
}

// snapshot atomically reads every counter field into a statsSnapshot. Version
// is a serialization concern (set by SaveStats), not a counter, so it is left
// zero here — keeping snapshot() a pure counter view for equality checks.
func (s *statsCounters) snapshot() statsSnapshot {
	return statsSnapshot{
		Total:           s.total.Load(),
		Block:           s.block.Load(),
		ForceDirect:     s.forceDirect.Load(),
		ForceProxy:      s.forceProxy.Load(),
		ChnrouteCN:      s.chnrouteCN.Load(),
		ChnrouteForeign: s.chnrouteForeign.Load(),
		ChinaOK:         s.chinaOK.Load(),
		ChinaErr:        s.chinaErr.Load(),
		TrustOK:         s.trustOK.Load(),
		TrustErr:        s.trustErr.Load(),
		CacheHits:       s.cacheHits.Load(),
		CacheMisses:     s.cacheMisses.Load(),
		ChinaLatNanos:   s.chinaLatNanos.Load(),
		ChinaLatCount:   s.chinaLatCount.Load(),
		TrustLatNanos:   s.trustLatNanos.Load(),
		TrustLatCount:   s.trustLatCount.Load(),
	}
}

// restore atomically writes every field of snap into s's counters.
func (s *statsCounters) restore(snap statsSnapshot) {
	s.total.Store(snap.Total)
	s.block.Store(snap.Block)
	s.forceDirect.Store(snap.ForceDirect)
	s.forceProxy.Store(snap.ForceProxy)
	s.chnrouteCN.Store(snap.ChnrouteCN)
	s.chnrouteForeign.Store(snap.ChnrouteForeign)
	s.chinaOK.Store(snap.ChinaOK)
	s.chinaErr.Store(snap.ChinaErr)
	s.trustOK.Store(snap.TrustOK)
	s.trustErr.Store(snap.TrustErr)
	s.cacheHits.Store(snap.CacheHits)
	s.cacheMisses.Store(snap.CacheMisses)
	s.chinaLatNanos.Store(snap.ChinaLatNanos)
	s.chinaLatCount.Store(snap.ChinaLatCount)
	s.trustLatNanos.Store(snap.TrustLatNanos)
	s.trustLatCount.Store(snap.TrustLatCount)
}

// LoadStats reads a statsSnapshot from path and restores it into s. A missing
// file is not an error — it means a fresh start, and s is left untouched
// (all-zero). A malformed file returns an error so the caller can log it, but
// s is left untouched in that case too (restore is only called on success).
// An empty path is a no-op (persistence disabled).
func LoadStats(path string, s *statsCounters) error {
	if path == "" || s == nil {
		return nil
	}
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return fmt.Errorf("stats: read %s: %w", path, err)
	}
	var snap statsSnapshot
	if err := unmarshalStrictJSON(data, &snap); err != nil {
		return fmt.Errorf("stats: parse %s: %w", path, err)
	}
	if snap.Version != statsSchemaVersion {
		return fmt.Errorf("stats: %s: unsupported schema version %d (want %d)", path, snap.Version, statsSchemaVersion)
	}
	s.restore(snap)
	return nil
}

// SaveStats atomically writes s's current snapshot to path: marshal to JSON,
// write to a temp file in the same directory, then rename over the final path.
// An empty path or a nil s is a no-op.
func SaveStats(path string, s *statsCounters) error {
	if path == "" || s == nil {
		return nil
	}

	snap := s.snapshot()
	snap.Version = statsSchemaVersion
	data, err := json.MarshalIndent(snap, "", "  ")
	if err != nil {
		return fmt.Errorf("stats: marshal: %w", err)
	}

	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("stats: mkdir %s: %w", dir, err)
	}
	tmp, err := os.CreateTemp(dir, ".stats-*.tmp")
	if err != nil {
		return fmt.Errorf("stats: create temp file: %w", err)
	}
	tmpPath := tmp.Name()
	succeeded := false
	defer func() {
		if !succeeded {
			os.Remove(tmpPath)
		}
	}()

	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return fmt.Errorf("stats: write temp file: %w", err)
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return fmt.Errorf("stats: sync temp file: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("stats: close temp file: %w", err)
	}
	if err := os.Rename(tmpPath, path); err != nil {
		return fmt.Errorf("stats: rename %s -> %s: %w", tmpPath, path, err)
	}
	succeeded = true
	return nil
}

// RunStatsPersister periodically saves s to path every interval, and
// performs one final save when ctx is done before returning. It is
// best-effort: a save failure (disk full, read-only filesystem, ...) is
// logged as a warning and never crashes the resolver. An empty path or a nil
// s disables persistence entirely (returns immediately).
func RunStatsPersister(ctx context.Context, path string, s *statsCounters, interval time.Duration) {
	if path == "" || s == nil {
		return
	}

	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			if err := SaveStats(path, s); err != nil {
				log.Printf("stats: final save failed: %v", err)
			}
			return
		case <-ticker.C:
			if err := SaveStats(path, s); err != nil {
				log.Printf("stats: periodic save failed: %v", err)
			}
		}
	}
}
