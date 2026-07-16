# Mihomo API TLS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every zashboard and daemon connection to the mihomo controller use strictly verified TLS with the existing zash wildcard certificate.

**Architecture:** New seeds expose only `external-controller-tls` on loopback and point mihomo at the zash role certificate. A shared Go HTTP transport dials the configured loopback address while verifying `DNS_ZASH_DOMAIN`, and both REST/WebSocket reverse proxying and daemon control calls use that transport. Existing operator-owned configurations remain byte-identical on ordinary reinstall; the raw editor enforces the new TLS-only controller invariant.

**Tech Stack:** Go standard library (`crypto/tls`, `crypto/x509`, `net/http`, `httputil`), Bash, mihomo v1.19.28 configuration, existing wildcard PEM files.

## Global Constraints

- Do not execute `install.sh`, systemd commands, SSH deployment, live gateway tests, or any other deployment test on the current machine.
- Keep Go direct dependencies limited to `github.com/miekg/dns` and `github.com/go-telegram/bot`; add no dependency.
- Require TLS 1.2 or newer and full hostname/certificate verification; never use `InsecureSkipVerify`.
- Use `DNS_MIHOMO_CONTROLLER` only as the loopback dial address, `DNS_ZASH_DOMAIN` as the TLS server name, and `DNS_ZASH_CERT` as additional trust material.
- New installs and explicit `mihomo-reset` use the TLS-only seed. Ordinary reinstall and `change-*` preserve an existing operator-owned mihomo config byte-for-byte.
- Keep zashboard pass-through authentication and console secret injection unchanged.
- Preserve REST and WebSocket behavior and do not add an HTTP fallback.

---

### Task 1: Verified Mihomo TLS Transport

**Files:**
- Create: `cmd/5gpn-dns/mihomo_tls.go`
- Create: `cmd/5gpn-dns/mihomo_tls_test.go`
- Modify: `cmd/5gpn-dns/cert_test.go:27-32`
- Modify: `cmd/5gpn-dns/mihomo_client.go:3-52`
- Modify: `cmd/5gpn-dns/mihomo_client_test.go`
- Modify: `cmd/5gpn-dns/mihomo_proxy.go:3-40`
- Modify: `cmd/5gpn-dns/mihomo_proxy_test.go`
- Modify: `cmd/5gpn-dns/api.go:126-221`
- Modify: `cmd/5gpn-dns/main.go:366-386`

**Interfaces:**
- Produces: `newMihomoTransport(controller, serverName, certFile string) (*http.Transport, error)`.
- Produces: `NewMihomoClient(controller, secret, serverName, certFile string) (*MihomoClient, error)`.
- Produces: `newMihomoProxy(upstreamHost, secret, mountPrefix string, inject bool, transport http.RoundTripper) http.Handler`.
- Consumes: `Config.MihomoController`, `Config.ZashDomain`, and the existing zash certificate fallback resolved by `NewControlServer`.

- [ ] **Step 1: Add a DNS SAN to the shared test certificate**

Add the SAN to `generateSelfSignedCert` so it can be verified instead of bypassed:

```go
tmpl := &x509.Certificate{
	SerialNumber: big.NewInt(1),
	Subject:      pkix.Name{CommonName: "test"},
	DNSNames:     []string{"test.local"},
	NotBefore:    time.Now().Add(-time.Hour),
	NotAfter:     time.Now().Add(time.Hour),
}
```

- [ ] **Step 2: Write TLS transport and client failure tests**

Create `mihomo_tls_test.go` with a reusable TLS controller fixture:

```go
type mihomoTLSTestServer struct {
	server     *httptest.Server
	controller string
	serverName string
	certFile   string
}

func newMihomoTLSTestServer(t *testing.T, handler http.Handler) mihomoTLSTestServer {
	t.Helper()
	certFile, keyFile := generateSelfSignedCert(t, t.TempDir())
	pair, err := tls.LoadX509KeyPair(certFile, keyFile)
	if err != nil {
		t.Fatalf("load test certificate: %v", err)
	}
	server := httptest.NewUnstartedServer(handler)
	server.TLS = &tls.Config{
		Certificates: []tls.Certificate{pair},
		MinVersion:   tls.VersionTLS12,
	}
	server.StartTLS()
	t.Cleanup(server.Close)
	return mihomoTLSTestServer{
		server:     server,
		controller: strings.TrimPrefix(server.URL, "https://"),
		serverName: "test.local",
		certFile:   certFile,
	}
}
```

Add tests that:

```go
func TestMihomoClientUsesVerifiedTLS(t *testing.T) {
	var gotAuth string
	upstream := newMihomoTLSTestServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth = r.Header.Get("Authorization")
		w.WriteHeader(http.StatusNoContent)
	}))
	client, err := NewMihomoClient(upstream.controller, "s3cr3t", upstream.serverName, upstream.certFile)
	if err != nil {
		t.Fatal(err)
	}
	if err := client.PutConfigs(context.Background(), "/etc/5gpn/mihomo/config.yaml"); err != nil {
		t.Fatal(err)
	}
	if gotAuth != "******" {
		t.Fatalf("Authorization = %q", gotAuth)
	}
}

func TestMihomoClientRejectsWrongServerName(t *testing.T) {
	upstream := newMihomoTLSTestServer(t, http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
	client, err := NewMihomoClient(upstream.controller, "", "wrong.test", upstream.certFile)
	if err != nil {
		t.Fatal(err)
	}
	if client.Reachable(context.Background()) {
		t.Fatal("wrong certificate identity must be unreachable")
	}
}

func TestMihomoTransportRejectsMissingTrustFile(t *testing.T) {
	_, err := newMihomoTransport("127.0.0.1:9090", "zash.example.com", filepath.Join(t.TempDir(), "missing.pem"))
	if err == nil {
		t.Fatal("missing trust file must fail")
	}
}
```

Convert the existing `mihomo_client_test.go` servers to `newMihomoTLSTestServer` and update every constructor call to the four-argument, error-returning form.

- [ ] **Step 3: Run the focused tests and confirm the red state**

Run from `cmd/5gpn-dns`:

```powershell
go test -run 'TestMihomo(Client|Transport)' ./...
```

Expected: compile failure because `newMihomoTransport` and the new `NewMihomoClient` signature do not exist.

- [ ] **Step 4: Implement the strict shared transport**

Create `mihomo_tls.go`:

```go
package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"net"
	"net/http"
	"os"
	"strings"
	"time"
)

func newMihomoTransport(controller, serverName, certFile string) (*http.Transport, error) {
	controller = strings.TrimSpace(controller)
	serverName = strings.TrimSuffix(strings.TrimSpace(serverName), ".")
	if controller == "" {
		return nil, fmt.Errorf("mihomo TLS: controller address is required")
	}
	host, _, err := net.SplitHostPort(controller)
	if err != nil {
		return nil, fmt.Errorf("mihomo TLS: invalid controller address %q: %w", controller, err)
	}
	ip := net.ParseIP(host)
	if ip == nil || !ip.IsLoopback() {
		return nil, fmt.Errorf("mihomo TLS: controller must be a loopback IP: %q", controller)
	}
	if serverName == "" {
		return nil, fmt.Errorf("mihomo TLS: server name is required")
	}
	pemBytes, err := os.ReadFile(certFile)
	if err != nil {
		return nil, fmt.Errorf("mihomo TLS: read trust certificate: %w", err)
	}
	roots, err := x509.SystemCertPool()
	if err != nil {
		return nil, fmt.Errorf("mihomo TLS: load system roots: %w", err)
	}
	if !roots.AppendCertsFromPEM(pemBytes) {
		return nil, fmt.Errorf("mihomo TLS: trust certificate contains no certificate")
	}
	dialer := &net.Dialer{Timeout: 10 * time.Second, KeepAlive: 30 * time.Second}
	return &http.Transport{
		Proxy:               nil,
		ForceAttemptHTTP2:   true,
		TLSHandshakeTimeout: 10 * time.Second,
		IdleConnTimeout:     90 * time.Second,
		TLSClientConfig: &tls.Config{
			MinVersion: tls.VersionTLS12,
			ServerName: serverName,
			RootCAs:    roots,
		},
		DialContext: func(ctx context.Context, network, _ string) (net.Conn, error) {
			return dialer.DialContext(ctx, network, controller)
		},
	}, nil
}
```

- [ ] **Step 5: Switch the daemon client to HTTPS**

Change the constructor and base URL in `mihomo_client.go`:

```go
func NewMihomoClient(controller, secret, serverName, certFile string) (*MihomoClient, error) {
	transport, err := newMihomoTransport(controller, serverName, certFile)
	if err != nil {
		return nil, err
	}
	return &MihomoClient{
		base:   "https://" + serverName,
		secret: secret,
		hc: &http.Client{
			Transport: transport,
			Timeout:   10 * time.Second,
		},
	}, nil
}
```

Update comments so they describe verified loopback TLS rather than plain HTTP.

- [ ] **Step 6: Switch reverse proxying to HTTPS**

Change `newMihomoProxy` to accept the shared transport:

```go
func newMihomoProxy(upstreamHost, secret, mountPrefix string, inject bool, transport http.RoundTripper) http.Handler {
	prefix := strings.TrimSuffix(mountPrefix, "/")
	return &httputil.ReverseProxy{
		Transport: transport,
		Rewrite: func(pr *httputil.ProxyRequest) {
			pr.Out.URL.Scheme = "https"
			pr.Out.URL.Host = upstreamHost
			pr.Out.Host = upstreamHost
			path := strings.TrimPrefix(pr.In.URL.Path, prefix)
			if path == "" || path[0] != '/' {
				path = "/" + path
			}
			pr.Out.URL.Path = path
			pr.Out.URL.RawPath = ""
			if !inject {
				return
			}
			pr.Out.Header.Del("Authorization")
			if secret != "" {
				pr.Out.Header.Set("Authorization", "Bearer "+secret)
			}
		},
		ModifyResponse: func(resp *http.Response) error {
			if !inject || (resp.StatusCode != http.StatusUnauthorized && resp.StatusCode != http.StatusForbidden) {
				return nil
			}
			const body = `{"error":"mihomo controller authentication failed"}`
			resp.StatusCode = http.StatusBadGateway
			resp.Status = "502 Bad Gateway"
			resp.Header.Del("Www-Authenticate")
			resp.Header.Set("Content-Type", "application/json")
			resp.Header.Set("Content-Length", strconv.Itoa(len(body)))
			resp.Body = io.NopCloser(strings.NewReader(body))
			resp.ContentLength = int64(len(body))
			return nil
		},
	}
}
```

In `NewControlServer`, resolve the zash cert fallback before constructing either
proxy, build one transport when `cfg.MihomoController != ""`, and pass it to the
console and zash proxies:

```go
zashCert, zashKey := cfg.ZashCertFile, cfg.ZashKeyFile
if zashCert == "" || zashKey == "" {
	zashCert, zashKey = webCert, webKey
}
var mihomoTransport http.RoundTripper
if cfg.MihomoController != "" {
	transport, transportErr := newMihomoTransport(cfg.MihomoController, cfg.ZashDomain, zashCert)
	if transportErr != nil {
		return nil, fmt.Errorf("control server: %w", transportErr)
	}
	mihomoTransport = transport
}
s.mihomoProxy = newMihomoProxy(cfg.ZashDomain, cfg.MihomoSecret, "/proxy", true, mihomoTransport)
```

Reuse `zashCert` and `zashKey` for the zash listener and pass the same transport
to its pass-through proxy.

- [ ] **Step 7: Wire the error-returning daemon client**

In `main.go`, create the client before `SetMihomoConfig` and fail startup
explicitly if trust setup fails:

```go
mihomoClient, err := NewMihomoClient(
	cfg.MihomoController,
	cfg.MihomoSecret,
	cfg.ZashDomain,
	cfg.ZashCertFile,
)
if err != nil {
	log.Fatalf("mihomo client: %v", err)
}
controlSrv.SetMihomoConfig(
	NewMihomoConfigStore(cfg.MihomoConfigFile),
	InfraParamsFromConfig(cfg),
	realMihomoTester{},
	mihomoClient,
)
```

- [ ] **Step 8: Convert proxy tests to TLS**

Build every proxy test upstream with `newMihomoTLSTestServer`, construct a
transport with `newMihomoTransport`, and call:

```go
transport, err := newMihomoTransport(upstream.controller, upstream.serverName, upstream.certFile)
if err != nil {
	t.Fatal(err)
}
h := newMihomoProxy(upstream.serverName, "s3cr3t", "/proxy", true, transport)
```

For the raw WebSocket test, wrap its listener with `tls.NewListener` using the
same generated certificate before accepting and reading the HTTP upgrade.

- [ ] **Step 9: Run focused Go tests**

Run from `cmd/5gpn-dns`:

```powershell
gofmt -w mihomo_tls.go mihomo_tls_test.go mihomo_client.go mihomo_client_test.go mihomo_proxy.go mihomo_proxy_test.go api.go main.go cert_test.go
go test -race -run 'TestMihomo(Client|Transport|Proxy)' ./...
```

Expected: all selected tests pass, including strict identity rejection and TLS
WebSocket upgrade.

- [ ] **Step 10: Commit**

```powershell
git add cmd/5gpn-dns
git commit -m "feat: secure mihomo controller clients with TLS"
```

Include the required Copilot commit trailers.

---

### Task 2: TLS-Only Seed and Raw-Editor Invariant

**Files:**
- Modify: `etc/mihomo/config.yaml.tmpl:8-12`
- Modify: `cmd/5gpn-dns/mihomo_config.go:256-327,366-388,482-518`
- Modify: `cmd/5gpn-dns/mihomo_config_test.go`
- Modify: `cmd/5gpn-dns/api_mihomo_config_test.go:213-249`

**Interfaces:**
- Produces: a byte-identical installer and Go seed containing TLS-only controller fields.
- Produces: `hasControllerInvariant(text string) bool`, enforcing disabled plaintext, TLS loopback, and exact zash cert/key paths.
- Consumes: existing `ValidateInvariants`, `MihomoConfigStore.Default`, and raw config API flow.

- [ ] **Step 1: Write failing seed and invariant tests**

Update the golden/invariant tests to require:

```yaml
external-controller: ""
external-controller-tls: 127.0.0.1:9090
tls:
  certificate: /etc/5gpn/cert/zash/fullchain.pem
  private-key: /etc/5gpn/cert/zash/privkey.pem
```

Add table cases that independently:

```go
{
	name: "plaintext controller enabled",
	mutate: func(cfg string) string {
		return strings.Replace(cfg, `external-controller: ""`, `external-controller: 127.0.0.1:9090`, 1)
	},
	wantName: "controller",
},
{
	name: "TLS controller removed",
	mutate: func(cfg string) string {
		return strings.Replace(cfg, "external-controller-tls: 127.0.0.1:9090\n", "", 1)
	},
	wantName: "controller",
},
{
	name: "controller certificate changed",
	mutate: func(cfg string) string {
		return strings.Replace(cfg, "/etc/5gpn/cert/zash/fullchain.pem", "/tmp/controller.pem", 1)
	},
	wantName: "controller",
},
{
	name: "controller private key changed",
	mutate: func(cfg string) string {
		return strings.Replace(cfg, "/etc/5gpn/cert/zash/privkey.pem", "/tmp/controller.key", 1)
	},
	wantName: "controller",
},
```

Update `TestMihomoConfigAPI_Put_MissingController` to remove
`external-controller-tls` and retain its assertions that validation, disk, and
runtime remain untouched.

- [ ] **Step 2: Run focused tests and confirm failure**

Run from `cmd/5gpn-dns`:

```powershell
go test -run 'TestMihomo(Invariants|ConfigSeed)|TestMihomoConfigAPI_Put_MissingController' ./...
```

Expected: failures because the current seed and invariant still require the
plaintext controller.

- [ ] **Step 3: Update both seed copies**

Replace the current controller stanza in both `etc/mihomo/config.yaml.tmpl` and
`mihomoConfigSeedTemplate` with:

```yaml
external-controller: ""
external-controller-tls: 127.0.0.1:9090
secret: __CONTROLLER_SECRET__
tls:
  certificate: /etc/5gpn/cert/zash/fullchain.pem
  private-key: /etc/5gpn/cert/zash/privkey.pem
```

Keep both files byte-identical so
`TestMihomoConfigSeedTemplate_MatchesRepoFile` remains the drift gate.

- [ ] **Step 4: Implement scalar-aware TLS invariant checks**

Add exact constants:

```go
const (
	literalControllerTLSAddr = "127.0.0.1:9090"
	literalControllerCert    = "/etc/5gpn/cert/zash/fullchain.pem"
	literalControllerKey     = "/etc/5gpn/cert/zash/privkey.pem"
)
```

Add small line-oriented helpers that only accept unique top-level keys and
direct children of the top-level `tls` block. They must unquote single- and
double-quoted scalars with the same behavior already used for `secret`.

```go
func parseYAMLScalar(raw string) (string, bool) {
	raw = strings.TrimSpace(raw)
	switch {
	case len(raw) >= 2 && raw[0] == '\'' && raw[len(raw)-1] == '\'':
		return strings.ReplaceAll(raw[1:len(raw)-1], "''", "'"), true
	case len(raw) >= 2 && raw[0] == '"' && raw[len(raw)-1] == '"':
		value, err := strconv.Unquote(raw)
		return value, err == nil
	default:
		return raw, true
	}
}

func topLevelYAMLScalar(text, key string) (string, bool) {
	var value string
	found := false
	prefix := key + ":"
	for _, raw := range strings.Split(stripYAMLComments(text), "\n") {
		if raw != strings.TrimLeft(raw, " \t") || !strings.HasPrefix(raw, prefix) {
			continue
		}
		if found {
			return "", false
		}
		var ok bool
		value, ok = parseYAMLScalar(strings.TrimPrefix(raw, prefix))
		if !ok {
			return "", false
		}
		found = true
	}
	return value, found
}

func topLevelYAMLMapScalar(text, mapKey, key string) (string, bool) {
	lines := strings.Split(stripYAMLComments(text), "\n")
	inMap := false
	mapFound := false
	childIndent := -1
	var value string
	valueFound := false
	for _, raw := range lines {
		if strings.TrimSpace(raw) == "" {
			continue
		}
		trimmed := strings.TrimLeft(raw, " \t")
		indent := len(raw) - len(trimmed)
		if indent == 0 {
			if inMap {
				inMap = false
			}
			if !strings.HasPrefix(trimmed, mapKey+":") {
				continue
			}
			if mapFound || strings.TrimSpace(strings.TrimPrefix(trimmed, mapKey+":")) != "" {
				return "", false
			}
			mapFound = true
			inMap = true
			childIndent = -1
			continue
		}
		if !inMap {
			continue
		}
		if childIndent == -1 {
			childIndent = indent
		}
		if indent != childIndent || !strings.HasPrefix(trimmed, key+":") {
			continue
		}
		if valueFound {
			return "", false
		}
		var ok bool
		value, ok = parseYAMLScalar(strings.TrimPrefix(trimmed, key+":"))
		if !ok {
			return "", false
		}
		valueFound = true
	}
	return value, mapFound && valueFound
}
```

Implement the final predicate as:

```go
func hasControllerInvariant(text string) bool {
	plain, plainOK := topLevelYAMLScalar(text, "external-controller")
	tlsAddr, tlsOK := topLevelYAMLScalar(text, "external-controller-tls")
	cert, certOK := topLevelYAMLMapScalar(text, "tls", "certificate")
	key, keyOK := topLevelYAMLMapScalar(text, "tls", "private-key")
	return plainOK && plain == "" &&
		tlsOK && tlsAddr == literalControllerTLSAddr &&
		certOK && cert == literalControllerCert &&
		keyOK && key == literalControllerKey
}
```

Pass raw `text` rather than normalized text from `ValidateInvariants`:

```go
case !hasControllerInvariant(text):
	return &ErrMissingInfra{Name: "controller"}
```

Keep the existing no-YAML-library policy and reject duplicate, nested-only, or
unsupported flow-style substitutions fail-closed.

- [ ] **Step 5: Run focused tests**

Run from `cmd/5gpn-dns`:

```powershell
gofmt -w mihomo_config.go mihomo_config_test.go api_mihomo_config_test.go
go test -race -run 'TestMihomo(Invariants|ConfigSeed)|TestMihomoConfigAPI_Put_MissingController' ./...
```

Expected: all selected tests pass, including template parity.

- [ ] **Step 6: Commit**

```powershell
git add etc/mihomo/config.yaml.tmpl cmd/5gpn-dns/mihomo_config.go cmd/5gpn-dns/mihomo_config_test.go cmd/5gpn-dns/api_mihomo_config_test.go
git commit -m "feat: seed a TLS-only mihomo controller"
```

Include the required Copilot commit trailers.

---

### Task 3: Installer HTTPS Controller Calls

**Files:**
- Modify: `install.sh:998-1008,2203-2213`
- Modify: `tests/test_install_policy.sh:110-140,223-245`
- Modify: `tests/test_mihomo_policy.sh:22-39`

**Interfaces:**
- Produces: `mihomo_controller_curl(path string, curl arguments...)`.
- Consumes: `DNS_MIHOMO_CONTROLLER`, `DNS_ZASH_DOMAIN`, `DNS_ZASH_CERT`, and `DNS_MIHOMO_SECRET` from environment/dns.env.
- Used by: `apply_whitelist` and `probe_mihomo_ready`.

- [ ] **Step 1: Add failing shell policy assertions**

Require the seed to contain TLS-only fields and the installer helper to contain
strict HTTPS arguments:

```bash
grep -Fq 'external-controller: ""' "$MIHOMO_TMPL" \
    || fail "mihomo plaintext controller is not disabled"
grep -Fq 'external-controller-tls: 127.0.0.1:9090' "$MIHOMO_TMPL" \
    || fail "mihomo TLS controller is missing"
grep -Fq 'certificate: /etc/5gpn/cert/zash/fullchain.pem' "$MIHOMO_TMPL" \
    || fail "mihomo controller does not use the zash certificate"
grep -Fq 'private-key: /etc/5gpn/cert/zash/privkey.pem' "$MIHOMO_TMPL" \
    || fail "mihomo controller does not use the zash private key"

mc_fn="$(sed -n '/^mihomo_controller_curl()/,/^}/p' "$INSTALL")"
printf '%s' "$mc_fn" | grep -Fq -- '--cacert' \
    || fail "mihomo controller curl does not verify the zash certificate"
printf '%s' "$mc_fn" | grep -Fq -- '--connect-to' \
    || fail "mihomo controller curl does not dial the configured loopback target"
printf '%s' "$mc_fn" | grep -Fq 'https://' \
    || fail "mihomo controller curl does not use HTTPS"
grep -Fq 'http://127.0.0.1:9090' "$INSTALL" \
    && fail "installer still calls the plaintext mihomo controller"
```

Remove the obsolete assertion requiring the old Task 6 marker.

- [ ] **Step 2: Run policy tests and confirm failure**

Run from the repository root:

```powershell
bash tests/test_install_policy.sh
bash tests/test_mihomo_policy.sh
```

Expected: failures for the missing HTTPS helper and old plaintext seed.

- [ ] **Step 3: Implement the shared curl helper**

Add near `apply_whitelist`:

```bash
mihomo_controller_curl() {
    local path="$1"; shift
    local controller server_name cert_file host port
    controller="${DNS_MIHOMO_CONTROLLER:-$(cfg_get DNS_MIHOMO_CONTROLLER)}"
    controller="${controller:-127.0.0.1:9090}"
    controller="${controller#http://}"; controller="${controller#https://}"
    host="${controller%:*}"
    port="${controller##*:}"
    [[ "$host" != "$controller" && "$port" =~ ^[0-9]+$ ]] \
        || { warn "invalid mihomo controller address: $controller"; return 1; }
    server_name="${ZASH_DOMAIN:-${DNS_ZASH_DOMAIN:-$(cfg_get DNS_ZASH_DOMAIN)}}"
    cert_file="${DNS_ZASH_CERT:-$(cfg_get DNS_ZASH_CERT)}"
    cert_file="${cert_file:-${ZASH_CERT_DIR}/fullchain.pem}"
    [[ -n "$server_name" ]] \
        || { warn "DNS_ZASH_DOMAIN is required for mihomo controller TLS"; return 1; }
    [[ -r "$cert_file" ]] \
        || { warn "mihomo controller trust certificate is unreadable: $cert_file"; return 1; }
    curl --cacert "$cert_file" \
        --connect-to "${server_name}:${port}:${host}:${port}" \
        "$@" "https://${server_name}:${port}${path}"
}
```

Do not add `--insecure`, `-k`, or an HTTP retry.

- [ ] **Step 4: Move whitelist refresh and readiness probing to the helper**

Use the persisted secret and HTTPS helper:

```bash
apply_whitelist() {
    local secret
    secret="${DNS_MIHOMO_SECRET:-$(cfg_get DNS_MIHOMO_SECRET)}"
    [[ -n "$secret" ]] || secret="$(mihomo_config_secret "$MIHOMO_DIR/config.yaml")"
    mihomo_controller_curl "/providers/rules/whitelist" \
        -fsS -X PUT -H "Authorization: ******" -o /dev/null \
        && ok "whitelist applied" || warn "whitelist refresh failed (is mihomo running?)"
}
```

In `probe_mihomo_ready`, replace the direct HTTP curl with:

```bash
local -a curl_args=(--fail --silent --show-error --max-time 2 -o /dev/null)
[[ -n "$secret" ]] && curl_args+=(-H "Authorization: ******")
mihomo_controller_curl "/version" "${curl_args[@]}" >/dev/null 2>&1 || return 1
```

- [ ] **Step 5: Run shell policy tests**

Run from the repository root:

```powershell
bash tests/test_install_policy.sh
bash tests/test_mihomo_policy.sh
```

Expected: both tests pass.

- [ ] **Step 6: Commit**

```powershell
git add install.sh tests/test_install_policy.sh tests/test_mihomo_policy.sh
git commit -m "feat: use HTTPS for installer mihomo calls"
```

Include the required Copilot commit trailers.

---

### Task 4: Renewal and Operator Documentation

**Files:**
- Modify: `scripts/renew-hook.sh:1-16,76-89`
- Modify: `etc/5gpn-dns/dns.env.example:23-35,117-128,153-161`
- Modify: `etc/systemd/mihomo.service:1-15`
- Modify: `README.md:61-67,101-105,120-127`
- Modify: `tests/integration-smoke.md:24-36,121-132,148-155,184-192`
- Modify: `tests/test_intranet_policy.sh:84-91`

**Interfaces:**
- Documents the already implemented TLS-only controller and certificate hot reload.
- Preserves the no-restart renewal behavior.

- [ ] **Step 1: Add a static renewal-policy assertion**

Extend `tests/test_intranet_policy.sh`:

```bash
grep -Fq 'mihomo reloads the controller certificate files automatically' "$RENEW" \
    || fail "renew-hook.sh: missing mihomo controller certificate hot-reload contract"
grep -Eq 'systemctl (restart|reload) mihomo' "$RENEW" \
    && fail "renew-hook.sh: must not restart/reload mihomo for controller certificate renewal"
```

- [ ] **Step 2: Update renewal comments**

Replace statements that mihomo terminates no TLS with the current split:

```bash
# Mihomo remains a raw L4 forwarder for client traffic, but its loopback
# external-controller is now a TLS endpoint using the zash role certificate.
# Mihomo v1.19.28 reloads certificate/private-key files automatically, so the
# renewed role copy becomes active without a process reload or restart.
```

Keep the existing `systemctl reload 5gpn-dns` for the daemon's own cert cache and
keep mihomo absent from executable renewal commands.

- [ ] **Step 3: Update configuration and service comments**

In `dns.env.example`, state that the zash cert serves both the zashboard panel
and mihomo controller, and that `DNS_MIHOMO_CONTROLLER` is the loopback TLS dial
target verified as `DNS_ZASH_DOMAIN`.

In `mihomo.service`, describe the loopback external controller as TLS. Do not
change permissions or sandboxing; root already reads the zash cert under
`ProtectSystem=strict`.

- [ ] **Step 4: Update current architecture and smoke checklist**

Add English operator notes to `README.md` stating:

```markdown
- **Mihomo controller TLS:** New installations expose the loopback controller
  only through verified HTTPS. Both zashboard's `/proxy/` hop and daemon
  control calls verify `zash.<base>` with the zash role wildcard certificate.
  Ordinary reinstall preserves an existing operator-owned config; use an
  explicit reset or edit it manually to migrate an older installation.
```

In `tests/integration-smoke.md`, add future deployment checks without running
them now:

```markdown
- [ ] `127.0.0.1:9090` completes a TLS handshake for `DNS_ZASH_DOMAIN` with the
  zash role certificate; a plaintext HTTP request fails.
- [ ] zashboard REST and WebSocket operations succeed through `/proxy/` while
  the 5gpn-to-mihomo hop is HTTPS.
- [ ] Raw config updates that enable `external-controller`, remove
  `external-controller-tls`, or change the zash certificate paths return 400.
- [ ] After certificate renewal, a new controller TLS handshake presents the
  renewed certificate without restarting mihomo.
```

- [ ] **Step 5: Run documentation policy tests**

Run from the repository root:

```powershell
bash tests/test_intranet_policy.sh
bash tests/test_5gpndns_policy.sh
```

Expected: both tests pass.

- [ ] **Step 6: Commit**

```powershell
git add scripts/renew-hook.sh etc/5gpn-dns/dns.env.example etc/systemd/mihomo.service README.md tests/integration-smoke.md tests/test_intranet_policy.sh
git commit -m "docs: describe mihomo controller TLS"
```

Include the required Copilot commit trailers.

---

### Task 5: Non-Deployment Verification

**Files:**
- Verify only; no deployment files are executed.

**Interfaces:**
- Consumes all prior task outputs.
- Produces final evidence that unit, race, vet, and static policy checks pass.

- [ ] **Step 1: Check formatting**

Run from `cmd/5gpn-dns`:

```powershell
gofmt -w .
if (gofmt -l .) { throw "gofmt reported unformatted files" }
```

Expected: no listed files.

- [ ] **Step 2: Run Go static analysis and race tests**

Run from `cmd/5gpn-dns`:

```powershell
go vet ./...
go test -race ./...
```

Expected: both commands exit 0.

- [ ] **Step 3: Run repository shell policy tests**

Run from the repository root:

```powershell
Get-ChildItem tests\test_*.sh | ForEach-Object {
    bash $_.FullName
    if ($LASTEXITCODE -ne 0) { throw "failed: $($_.Name)" }
}
```

Expected: every static policy script reports PASS. These scripts inspect source
text only; do not run `install.sh`.

- [ ] **Step 4: Inspect the final diff**

Run:

```powershell
git --no-pager diff --check
git --no-pager status --short
git --no-pager log -6 --oneline
```

Expected: no whitespace errors and only the intended branch commits/files.

- [ ] **Step 5: Commit any formatting-only correction**

Only if Step 1 changed files:

```powershell
git add cmd/5gpn-dns
git commit -m "style: format mihomo TLS changes"
```

Include the required Copilot commit trailers. Do not create an empty commit.
