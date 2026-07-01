# CLAUDE.md

Project guidance for working in this repo (5gpn — 5gpn-dns DoT/DoH/plain-53 gateway, exit-less / direct-egress).

## TUI / installer interaction: use Gum

All interactive UI and styled output in shell scripts (chiefly `install.sh`) is drawn with **[Gum](https://github.com/charmbracelet/gum)** (charmbracelet/gum). When adding or changing any prompt, menu, confirmation, spinner, or status output, use gum — do **not** add raw `read`/`echo`/`whiptail`/`dialog` as the primary path.

**Every operator-facing script follows the gum-or-echo pattern**, not just `install.sh`:

- `install.sh` carries the canonical inline helpers (`info/ok/warn/err/ask_*/gum_spin/card`) plus `install_gum()`.
- The sub-scripts it invokes (`scripts/update-lists.sh`, `setup-firewall.sh`, `gen-ios-profile.sh`, `renew-hook.sh`) each carry a **small self-contained gum-or-echo preamble** — they only *detect* gum (`command -v gum` + `[ -t 1 ]`), they never install it (that is `install.sh`'s job). Kept self-contained on purpose: no shared-lib sourcing failure mode, and the per-script duplication is locked against drift by `tests/test_tui_policy.sh`.
- `quick-install.sh` runs **before** gum is bootstrapped, so it is gum-aware-if-present with an ANSI fallback — do not make it install gum.
- **Intentionally exempt** (don't terminal-TUI these): `src/ios-http.py` (non-interactive; stderr is wrapped by the caller's gum helpers), and `tgbot.py` (the control plane is already a Telegram-native inline-keyboard TUI).

Follow the established pattern (see `install.sh`):

- **Bootstrap, don't assume.** `install_gum()` downloads a **prebuilt** gum binary (no Go toolchain, no apt repo) and verifies it (`GUM_SHA256` override else the release `checksums.txt`); it runs early. `GUM_VERSION` is env-overridable. It must be **non-fatal under `set -euo pipefail`** — any failure leaves `_HAVE_GUM=0` and returns 0.
- **Always provide an echo fallback.** The `info/warn/ok/err` helpers branch on `_HAVE_GUM`: gum when `1`, plain ANSI `echo` when `0`. Never let output depend on gum being present.
- **Gate every gum *interaction* on a TTY: `[[ -t 0 ]]`.** `gum input/choose/confirm` need a terminal. Non-TTY runs (`curl | sudo bash`, CI) must fall through to the env-var / non-interactive path and never block on input.
- **Guard prompt captures against cancel.** `gum input`/`gum confirm` exit non-zero on Esc/Ctrl-C, so `var="$(gum_helper …)"` under `set -e` would abort the whole run. Always write `var="$(ask_text '…' || true)"` (empty-on-cancel), matching the existing `ask_text`/`ask_secret`/`ask_yesno`/`gum_spin` helpers.
- **`gum_spin` only wraps opaque waits** (e.g. binary downloads), never output-bearing commands whose stdout the operator needs (e.g. `update-lists.sh`).

## Other standing conventions

- **No exit layer.** Direct egress only — no WireGuard / multi-exit / fwmark / `ip rule` / `table 100`. Don't add any of these. sing-box IS the transparent SNI/QUIC forwarder (data plane) via a `direct` inbound — it does NOT do tproxy/tun/fwmark, so it stays within this rule.

- **DNS brain = `5gpn-dns`** (self-built Go binary, `cmd/5gpn-dns/`). It handles DoT :853, DoH :8443, and plain DNS :53 (rate-limited), plus the **control-plane HTTPS API on :9443** (Phase 3, bearer-token, CLIENT_NET-only). smartdns and chinadns-ng are **removed**. Do not re-add them.

- **Ingress transports** (deliberate reversal, 2026-07-01): DoT :853 + DoH :8443 + plain DNS :53 (public, per-source rate-limited). The earlier "DoT-only inbound, no public 53" stance is **reversed**. The :53 open-resolver surface is accepted; mitigated by rate limiting.

- **Control plane** (deliberate reversal, 2026-07-01 — **Phase 3 DONE**): two coexisting control planes over one shared surface. `5gpn-dns` serves a **bearer-token HTTPS REST API on :9443** (`cmd/5gpn-dns/api.go` over the `Controller` facade: status/stats/lookup, subscriptions CRUD, manual rules CRUD, update, reload) plus an **embedded React SPA** (`cmd/5gpn-dns/web/`, `go:embed web/dist`, served at `/`). The API is gated on `DNS_API_TOKEN` (empty ⇒ control plane disabled, never served unauthenticated; constant-time bearer compare) and firewalled to **CLIENT_NET only** (`:9443`, never public). `tgbot.py` is **rewritten as an API client** of the same endpoints (loopback `https://127.0.0.1:9443`, no-verify TLS, same token) — it is no longer the *primary* plane but coexists as the Telegram-native one. install.sh auto-generates `DNS_API_TOKEN` (preserved across re-installs). The earlier "tgbot only / no HTTP API+web UI, don't reintroduce" stance is **reversed** — implemented per `docs/superpowers/specs/2026-07-01-5gpn-dns-p3-api-webui-design.md`. The frontend is **built in CI** (`npm run build` → `web/dist` → `go:embed`); a committed placeholder `web/dist/index.html` keeps `go build` working pre-build. Do NOT commit the built `web/dist`.

- **Rule lists** (deliberate reversal, 2026-07-01 — **Phase 2 DONE**): rule lists now support in-process subscriptions (`/etc/5gpn/subscriptions.json`, env `DNS_SUBSCRIPTIONS`): `5gpn-dns` fetches each subscription's remote URL on its own `interval`, parses it (`plain`/`gfwlist`/`dnsmasq`/`adblock`/`hosts` for domain categories; `cidr` for chnroute), and caches it to `/etc/5gpn/rules/<category>/<name>.txt`. Manual `<category>.txt` still works and **merges** with all of that category's subscription caches (glob-loaded together). Fetch/parse failure or too-few-entries keeps the old cache (offline-safe) rather than clearing it. chnroute is now fetched by a default subscription (17mon/china_ip_list), replacing the old `update-lists.sh` direct download; `update-lists.sh` is now just a `systemctl reload 5gpn-dns` trigger. The systemd unit has `ReadWritePaths=/etc/5gpn/rules` so the subscription manager can write caches. The earlier "manual-only, don't implement subscriptions until the Phase 2 spec is written" stance is **reversed** — implemented per `docs/superpowers/specs/2026-07-01-5gpn-dns-p2-subscriptions-design.md`.

- **Prebuilt / CI-built binaries**: third-party tools (sing-box, gum) use prebuilt binaries — no Go toolchain on the box. `5gpn-dns` is our own binary: **built in CI** (`cmd/5gpn-dns/` → `moooyo/5gpn` release, `DNS_VERSION` pin, `DNS_SHA256` opt-in), then downloaded at install time. The "no toolchain on the box" rule still holds — `5gpn-dns` is built in CI, never on the gateway. sha256 verify is mandatory for gum (`checksums.txt`); for sing-box and 5gpn-dns it is opt-in (`SINGBOX_SHA256` / `DNS_SHA256`).

- **Tests** taxonomy:
  - **Pure-grep policy scripts** under `tests/test_*.sh` — run under Git Bash on Windows (dev box).
  - **Go unit tests** `cmd/5gpn-dns/*_test.go` — run via `go test ./...` (CI + dev box; Go 1.26.3 is on the dev box).
  - **Linux/CI gates**: `sing-box check`, `nft -c`, `go test` integration, live DoT+DoH+plain-53 behavior, cert/renewal flows, full `install.sh` — run on **test-env** (see below).

## Linux test environment (test-env)

A real Debian box for the Linux/CI gates that can't run on the Windows dev box (`sing-box check` / `nft -c` / live DNS + cert/renewal flows, full `install.sh`).

- **Host:** `test-env` = Debian 13 (trixie) x86_64, `root@10.0.1.20:22`. Currently directly reachable on the network.
- **SSH login:** `ssh test-env` — host defined in the dotssh config (`D:\Code\dotssh\config.d/hosts` → `root@10.0.1.20:22`); auth goes through the **Bitwarden SSH Agent** (Windows named pipe).
- **⚠️ Must use Windows native `ssh.exe`**, invoked via PowerShell:
  `& "$env:WINDIR\System32\OpenSSH\ssh.exe" test-env '<cmd>'`.
  **Do not use Git Bash's `ssh`** — it fails two ways: (1) the UTF-8 BOM at the start of `~/.ssh/config` makes it error `Bad configuration option: \357\273\277include`, and (2) it can't reach the agent private key in the Windows named pipe.
- **Remote command quoting:** avoid `()` inside the PowerShell single-quoted command (it reaches remote bash as syntax). For multi-line / complex remote commands, the most robust path is to **base64-encode the script locally and decode remotely**: `$b64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($script)); & ssh.exe test-env "echo $b64 | base64 -d | bash"`. This dodges two Windows-PowerShell-5.1 traps that a here-string `@'…'@` piped to `bash -s` hits: a UTF-8 BOM prepended to the first line (mangles `set`/the first var), and the command-line length limit on large payloads. For whole files (configs, units, `tgbot.py`), use `scp.exe` to copy them over rather than inlining.
- ⚠️ **Real box, not a sandbox** — treat it like production: don't run destructive commands without reason, and remember `install.sh` changes firewall/systemd/certs there for real.
