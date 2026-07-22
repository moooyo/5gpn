package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
)

const interceptConfigVersion = 5
const maxInterceptConfigBytes = 16 << 20

type interceptProxyConfig struct {
	Address  string `json:"address"`
	Username string `json:"username"`
	Password string `json:"password"`
}

type interceptMITMSettings struct {
	Enabled                bool `json:"enabled"`
	HTTP2                  bool `json:"http2"`
	QUICFallbackProtection bool `json:"quic_fallback_protection"`
}

type interceptConfigDocument struct {
	Version        int                       `json:"version"`
	Listen         string                    `json:"listen"`
	Username       string                    `json:"username"`
	Password       string                    `json:"password"`
	TLSCert        string                    `json:"tls_cert"`
	TLSKey         string                    `json:"tls_key"`
	UpstreamProxy  interceptProxyConfig      `json:"upstream_proxy"`
	MITM           interceptMITMSettings     `json:"mitm"`
	ExecutionOrder []string                  `json:"execution_order"`
	Modules        []interceptModuleSnapshot `json:"modules,omitempty"`
}

type interceptSettingsView struct {
	Revision               string `json:"revision"`
	Enabled                bool   `json:"enabled"`
	HTTP2                  bool   `json:"http2"`
	QUICFallbackProtection bool   `json:"quic_fallback_protection"`
}

type interceptSettingsUpdate struct {
	Revision               string `json:"revision"`
	Enabled                *bool  `json:"enabled"`
	HTTP2                  *bool  `json:"http2"`
	QUICFallbackProtection *bool  `json:"quic_fallback_protection"`
}

type InterceptConfigStore struct {
	Path string
	mu   sync.Mutex
}

func NewInterceptConfigStore(path string) *InterceptConfigStore {
	return &InterceptConfigStore{Path: path}
}

func (s *InterceptConfigStore) Read() (interceptConfigDocument, []byte, error) {
	if s == nil || strings.TrimSpace(s.Path) == "" {
		return interceptConfigDocument{}, nil, errors.New("interception config management unavailable")
	}
	file, err := os.Open(s.Path)
	if err != nil {
		return interceptConfigDocument{}, nil, fmt.Errorf("read interception config: %w", err)
	}
	defer file.Close()
	body, err := io.ReadAll(io.LimitReader(file, maxInterceptConfigBytes+1))
	if err != nil {
		return interceptConfigDocument{}, nil, fmt.Errorf("read interception config: %w", err)
	}
	if len(body) > maxInterceptConfigBytes {
		return interceptConfigDocument{}, nil, fmt.Errorf("interception config exceeds %d bytes", maxInterceptConfigBytes)
	}
	document, err := decodeInterceptConfig(body)
	if err != nil {
		return interceptConfigDocument{}, nil, err
	}
	return document, body, nil
}

func decodeInterceptConfig(body []byte) (interceptConfigDocument, error) {
	var document interceptConfigDocument
	if err := unmarshalStrictJSON(body, &document); err != nil {
		return interceptConfigDocument{}, fmt.Errorf("decode interception config: %w", err)
	}
	if err := validateInterceptDocument(document); err != nil {
		return interceptConfigDocument{}, err
	}
	return document, nil
}

func validateInterceptDocument(document interceptConfigDocument) error {
	if document.Version != interceptConfigVersion {
		return fmt.Errorf("interception config version must be %d", interceptConfigVersion)
	}
	if document.Listen != "127.0.0.1:18080" || document.UpstreamProxy.Address != "127.0.0.1:17890" {
		return errors.New("interception SOCKS addresses do not match the fixed loopback boundary")
	}
	if len(document.Username) < 16 || len(document.Password) < 24 ||
		len(document.UpstreamProxy.Username) < 16 || len(document.UpstreamProxy.Password) < 24 {
		return errors.New("interception SOCKS credentials are missing or too short")
	}
	if document.TLSCert != "/etc/5gpn/intercept/tls/fullchain.pem" || document.TLSKey != "/etc/5gpn/intercept/tls/privkey.pem" {
		return errors.New("interception TLS paths do not match the fixed runtime boundary")
	}
	if err := validateInterceptModules(document.Modules); err != nil {
		return err
	}
	if err := validateInterceptExecutionOrder(document.Modules, document.ExecutionOrder); err != nil {
		return err
	}
	if len(certificateInterceptHosts(document)) > maxInterceptModuleHosts {
		return fmt.Errorf("enabled interception modules exceed %d unique certificate hosts", maxInterceptModuleHosts)
	}
	return nil
}

func validateInterceptExecutionOrder(modules []interceptModuleSnapshot, executionOrder []string) error {
	if executionOrder == nil {
		return errors.New("execution_order is required")
	}
	if len(executionOrder) != len(modules) {
		return errors.New("execution_order must contain every interception extension id exactly once")
	}
	moduleIDs := make(map[string]struct{}, len(modules))
	for _, module := range modules {
		moduleIDs[module.ID] = struct{}{}
	}
	seen := make(map[string]struct{}, len(executionOrder))
	for _, id := range executionOrder {
		if _, exists := moduleIDs[id]; !exists {
			return fmt.Errorf("execution_order contains unknown interception extension id %q", id)
		}
		if _, duplicate := seen[id]; duplicate {
			return fmt.Errorf("execution_order contains duplicate interception extension id %q", id)
		}
		seen[id] = struct{}{}
	}
	return nil
}

func removeInterceptModuleID(ids []string, remove string) []string {
	result := make([]string, 0, len(ids))
	for _, id := range ids {
		if id != remove {
			result = append(result, id)
		}
	}
	return result
}

func stringSlicesEqual(left, right []string) bool {
	if len(left) != len(right) {
		return false
	}
	for index := range left {
		if left[index] != right[index] {
			return false
		}
	}
	return true
}

func orderedInterceptModules(document interceptConfigDocument) []interceptModuleSnapshot {
	byID := make(map[string]interceptModuleSnapshot, len(document.Modules))
	for _, module := range document.Modules {
		byID[module.ID] = module
	}
	ordered := make([]interceptModuleSnapshot, 0, len(document.ExecutionOrder))
	for _, id := range document.ExecutionOrder {
		if module, exists := byID[id]; exists {
			ordered = append(ordered, module)
		}
	}
	return ordered
}

func interceptRevision(body []byte) string {
	sum := sha256.Sum256(body)
	return hex.EncodeToString(sum[:])
}

func interceptSettings(document interceptConfigDocument, body []byte) interceptSettingsView {
	return interceptSettingsView{
		Revision:               interceptRevision(body),
		Enabled:                document.MITM.Enabled,
		HTTP2:                  document.MITM.HTTP2,
		QUICFallbackProtection: document.MITM.QUICFallbackProtection,
	}
}

func (s *ControlServer) handleInterceptSettingsGet(w http.ResponseWriter, _ *http.Request) {
	if s.interceptStore == nil {
		writeErr(w, http.StatusServiceUnavailable, "interception config management unavailable")
		return
	}
	s.interceptStore.mu.Lock()
	defer s.interceptStore.mu.Unlock()
	document, body, err := s.interceptStore.Read()
	if err != nil {
		writeErr(w, http.StatusServiceUnavailable, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, interceptSettings(document, body))
}

func (s *ControlServer) handleInterceptSettingsPut(w http.ResponseWriter, r *http.Request) {
	if s.interceptStore == nil || s.interceptModules == nil {
		writeErr(w, http.StatusServiceUnavailable, "interception config management unavailable")
		return
	}
	var update interceptSettingsUpdate
	if !decodeJSONBody(w, r, &update) {
		return
	}
	if !validMihomoConfigRevision(update.Revision) || update.Enabled == nil || update.HTTP2 == nil || update.QUICFallbackProtection == nil {
		writeErr(w, http.StatusBadRequest, "revision, enabled, http2, and quic_fallback_protection are required")
		return
	}
	next := interceptMITMSettings{
		Enabled:                *update.Enabled,
		HTTP2:                  *update.HTTP2,
		QUICFallbackProtection: *update.QUICFallbackProtection,
	}
	if _, err := s.interceptModules.UpdateSettings(r.Context(), update.Revision, next); err != nil {
		writeInterceptModuleError(w, err)
		return
	}
	s.interceptStore.mu.Lock()
	document, body, err := s.interceptStore.Read()
	s.interceptStore.mu.Unlock()
	if err != nil {
		writeErr(w, http.StatusServiceUnavailable, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, interceptSettings(document, body))
}

func writeInterceptConfigAtomic(path string, body []byte) error {
	return writeInterceptConfigAtomicContext(context.Background(), path, body)
}

func writeInterceptConfigAtomicContext(ctx context.Context, path string, body []byte) error {
	if ctx == nil {
		return errors.New("interception config write context is required")
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	dir := filepath.Dir(path)
	info, err := os.Stat(path)
	if err != nil {
		return fmt.Errorf("stat interception config: %w", err)
	}
	temp, err := os.CreateTemp(dir, ".config.json.*")
	if err != nil {
		return fmt.Errorf("create interception config candidate: %w", err)
	}
	tempPath := temp.Name()
	cleanup := func() { _ = os.Remove(tempPath) }
	if err := temp.Chmod(info.Mode().Perm()); err != nil {
		temp.Close()
		cleanup()
		return err
	}
	if _, err := temp.Write(body); err != nil {
		temp.Close()
		cleanup()
		return err
	}
	if err := temp.Sync(); err != nil {
		temp.Close()
		cleanup()
		return err
	}
	if err := temp.Close(); err != nil {
		cleanup()
		return err
	}
	// The rename is the commit point. Observe cancellation after all candidate
	// I/O and immediately before entering that non-interruptible operation.
	if err := ctx.Err(); err != nil {
		cleanup()
		return err
	}
	if err := os.Rename(tempPath, path); err != nil {
		cleanup()
		return fmt.Errorf("publish interception config: %w", err)
	}
	return nil
}
