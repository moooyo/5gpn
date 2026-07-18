package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
)

const interceptConfigVersion = 1
const maxInterceptConfigBytes = 16 << 20

type interceptProxyConfig struct {
	Address  string `json:"address"`
	Username string `json:"username"`
	Password string `json:"password"`
}

type interceptWLOCSettings struct {
	Enabled      bool     `json:"enabled"`
	Longitude    *float64 `json:"longitude"`
	Latitude     *float64 `json:"latitude"`
	Accuracy     uint32   `json:"accuracy"`
	FailClosed   bool     `json:"fail_closed"`
	MaxBodyBytes int64    `json:"max_body_bytes"`
}

type interceptConfigDocument struct {
	Version       int                       `json:"version"`
	Listen        string                    `json:"listen"`
	Username      string                    `json:"username"`
	Password      string                    `json:"password"`
	TLSCert       string                    `json:"tls_cert"`
	TLSKey        string                    `json:"tls_key"`
	UpstreamProxy interceptProxyConfig      `json:"upstream_proxy"`
	WLOC          interceptWLOCSettings     `json:"wloc"`
	Modules       []interceptModuleSnapshot `json:"modules,omitempty"`
}

type interceptWLOCView struct {
	Revision     string   `json:"revision"`
	Enabled      bool     `json:"enabled"`
	Longitude    *float64 `json:"longitude"`
	Latitude     *float64 `json:"latitude"`
	Accuracy     uint32   `json:"accuracy"`
	FailClosed   bool     `json:"fail_closed"`
	MaxBodyBytes int64    `json:"max_body_bytes"`
	Hosts        []string `json:"hosts"`
}

type interceptWLOCUpdate struct {
	Revision     string   `json:"revision"`
	Enabled      *bool    `json:"enabled"`
	Longitude    *float64 `json:"longitude"`
	Latitude     *float64 `json:"latitude"`
	Accuracy     *uint32  `json:"accuracy"`
	FailClosed   *bool    `json:"fail_closed"`
	MaxBodyBytes *int64   `json:"max_body_bytes"`
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
	if err := validateInterceptWLOC(document.WLOC); err != nil {
		return err
	}
	if err := validateInterceptModules(document.Modules); err != nil {
		return err
	}
	if len(certificateInterceptHosts(document)) > maxInterceptModuleHosts {
		return fmt.Errorf("enabled interception modules exceed %d unique certificate hosts", maxInterceptModuleHosts)
	}
	return nil
}

func validateInterceptWLOC(settings interceptWLOCSettings) error {
	if settings.Accuracy == 0 || settings.Accuracy > 100000 {
		return errors.New("accuracy must be between 1 and 100000")
	}
	if settings.MaxBodyBytes < 1024 || settings.MaxBodyBytes > 64<<20 {
		return errors.New("max_body_bytes must be between 1024 and 67108864")
	}
	if settings.Longitude != nil && (math.IsNaN(*settings.Longitude) || math.IsInf(*settings.Longitude, 0) || *settings.Longitude < -180 || *settings.Longitude > 180) {
		return errors.New("longitude must be between -180 and 180")
	}
	if settings.Latitude != nil && (math.IsNaN(*settings.Latitude) || math.IsInf(*settings.Latitude, 0) || *settings.Latitude < -90 || *settings.Latitude > 90) {
		return errors.New("latitude must be between -90 and 90")
	}
	if settings.Enabled && (settings.Longitude == nil || settings.Latitude == nil) {
		return errors.New("enabled WLOC interception requires longitude and latitude")
	}
	return nil
}

func interceptRevision(body []byte) string {
	sum := sha256.Sum256(body)
	return hex.EncodeToString(sum[:])
}

func interceptView(document interceptConfigDocument, body []byte) interceptWLOCView {
	return interceptWLOCView{
		Revision:     interceptRevision(body),
		Enabled:      document.WLOC.Enabled,
		Longitude:    document.WLOC.Longitude,
		Latitude:     document.WLOC.Latitude,
		Accuracy:     document.WLOC.Accuracy,
		FailClosed:   document.WLOC.FailClosed,
		MaxBodyBytes: document.WLOC.MaxBodyBytes,
		Hosts:        []string{"gs-loc.apple.com", "gs-loc-cn.apple.com"},
	}
}

func (s *ControlServer) handleInterceptWLOCGet(w http.ResponseWriter, _ *http.Request) {
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
	writeJSON(w, http.StatusOK, interceptView(document, body))
}

func (s *ControlServer) handleInterceptWLOCPut(w http.ResponseWriter, r *http.Request) {
	if s.interceptStore == nil {
		writeErr(w, http.StatusServiceUnavailable, "interception config management unavailable")
		return
	}
	var update interceptWLOCUpdate
	if !decodeJSONBody(w, r, &update) {
		return
	}
	if !validMihomoConfigRevision(update.Revision) || update.Enabled == nil || update.Accuracy == nil || update.FailClosed == nil || update.MaxBodyBytes == nil {
		writeErr(w, http.StatusBadRequest, "revision, enabled, accuracy, fail_closed, and max_body_bytes are required")
		return
	}
	next := interceptWLOCSettings{
		Enabled:      *update.Enabled,
		Longitude:    update.Longitude,
		Latitude:     update.Latitude,
		Accuracy:     *update.Accuracy,
		FailClosed:   *update.FailClosed,
		MaxBodyBytes: *update.MaxBodyBytes,
	}
	if err := validateInterceptWLOC(next); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if s.interceptModules != nil {
		if _, err := s.interceptModules.UpdateWLOC(r.Context(), update.Revision, next); err != nil {
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
		writeJSON(w, http.StatusOK, interceptView(document, body))
		return
	}

	s.interceptStore.mu.Lock()
	defer s.interceptStore.mu.Unlock()
	document, oldBody, err := s.interceptStore.Read()
	if err != nil {
		writeErr(w, http.StatusServiceUnavailable, err.Error())
		return
	}
	if update.Revision != interceptRevision(oldBody) {
		writeJSON(w, http.StatusConflict, interceptView(document, oldBody))
		return
	}
	document.WLOC = next
	newBody, err := json.MarshalIndent(document, "", "  ")
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	newBody = append(newBody, '\n')
	if err := writeInterceptConfigAtomic(s.interceptStore.Path, newBody); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, interceptView(document, newBody))
}

func writeInterceptConfigAtomic(path string, body []byte) error {
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
	if err := os.Rename(tempPath, path); err != nil {
		cleanup()
		return fmt.Errorf("publish interception config: %w", err)
	}
	return nil
}
