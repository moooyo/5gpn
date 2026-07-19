#!/usr/bin/env bash
# Runtime regression for mihomo's target-keyed sniff-failure cache. This test
# intentionally uses high loopback ports so it can run as an unprivileged CI
# user. The production seed shape is validated separately with mihomo -t.
set -euo pipefail

PINNED_MIHOMO_BIN="${1:-}"
[[ -x "$PINNED_MIHOMO_BIN" ]] || { echo "usage: $0 /path/to/mihomo" >&2; exit 2; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Exercise the production listener renderer instead of duplicating its target
# in this fixture. install.sh's library mode defines functions without running
# the installer entry point.
INSTALL_SH_LIB_ONLY=1 source "$ROOT/install.sh"
RENDERED_LISTENERS="$(render_mihomo_listeners '127.0.0.3' 'console.example.test')"
GATEWAY_LISTENER="$(grep -F 'name: gateway,' <<<"$RENDERED_LISTENERS")"
GATEWAY_LISTENER="${GATEWAY_LISTENER/port: 443/port: 10443}"
GATEWAY_LISTENER="${GATEWAY_LISTENER/target: console.example.test:443/target: console.example.test:18443}"

RUNTIME="$(mktemp -d)"
CONSOLE_PID=""
ORIGIN_PID=""
MIHOMO_PID=""

cleanup() {
    local pid attempt
    for pid in "$MIHOMO_PID" "$ORIGIN_PID" "$CONSOLE_PID"; do
        [[ -n "$pid" ]] || continue
        kill "$pid" 2>/dev/null || true
        for attempt in $(seq 1 20); do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.05
        done
        kill -KILL "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
    rm -rf -- "$RUNTIME"
}
trap cleanup EXIT INT TERM

mkdir -p "$RUNTIME/console" "$RUNTIME/origin"
printf 'CONSOLE-BACKEND\n' > "$RUNTIME/console/marker.txt"
printf 'ORIGIN-BACKEND\n' > "$RUNTIME/origin/marker.txt"
printf '127.0.0.1/32\n' > "$RUNTIME/whitelist.txt"

openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -subj '/CN=console.example.test' \
    -addext 'subjectAltName=DNS:console.example.test,DNS:origin.example.test,DNS:zash.example.test' \
    -keyout "$RUNTIME/key.pem" -out "$RUNTIME/cert.pem" >/dev/null 2>&1

(
    cd "$RUNTIME/console"
    exec openssl s_server -quiet -WWW -accept 127.0.0.1:18443 \
        -cert "$RUNTIME/cert.pem" -key "$RUNTIME/key.pem"
) >"$RUNTIME/console.log" 2>&1 &
CONSOLE_PID=$!

(
    cd "$RUNTIME/origin"
    exec openssl s_server -quiet -WWW -accept 127.0.0.4:18443 \
        -cert "$RUNTIME/cert.pem" -key "$RUNTIME/key.pem"
) >"$RUNTIME/origin.log" 2>&1 &
ORIGIN_PID=$!

awk -v cert="$RUNTIME/cert.pem" -v key="$RUNTIME/key.pem" -v listener="$GATEWAY_LISTENER" '
  $0 == "__MIHOMO_LISTENERS__" {
    print listener
    next
  }
  $0 == "rule-providers:" {
    print "  origin.example.test: 127.0.0.4"
  }
  $0 == "rules:" {
    print
    print "  - DOMAIN,origin.example.test,DIRECT"
    next
  }
  {
    gsub(/__GATEWAY_IP__/, "10.0.0.1")
    gsub(/__CONSOLE_DOMAIN__/, "console.example.test")
    gsub(/__ZASH_DOMAIN__/, "zash.example.test")
    gsub(/__CONTROLLER_SECRET__/, "ci-controller-secret")
    gsub(/__INTERCEPT_INBOUND_USERNAME__/, "ci-module-inbound-user")
    gsub(/__INTERCEPT_INBOUND_PASSWORD__/, "ci-module-inbound-password-123456")
    gsub(/__INTERCEPT_UPSTREAM_USERNAME__/, "ci-module-upstream-user")
    gsub(/__INTERCEPT_UPSTREAM_PASSWORD__/, "ci-module-upstream-password-123456")
    gsub(/127.0.0.1:9090/, "127.0.0.1:19090")
    gsub(/\/etc\/5gpn\/cert\/zash\/current\/fullchain.pem/, cert)
    gsub(/\/etc\/5gpn\/cert\/zash\/current\/privkey.pem/, key)
	if ($0 ~ /TLS:.*ports: \[443, 8080, 8443, 5060\]/) {
	  gsub(/ports: \[443, 8080, 8443, 5060\]/, "ports: [18443, 8080, 8443, 5060]")
	}
    print
  }
' "$ROOT/etc/mihomo/config.yaml.tmpl" > "$RUNTIME/config.yaml"

if grep -Eq '__[A-Z0-9_]+__' "$RUNTIME/config.yaml"; then
    echo "unresolved mihomo template placeholder" >&2
    exit 1
fi

"$PINNED_MIHOMO_BIN" -t -f "$RUNTIME/config.yaml" -d "$RUNTIME"
"$PINNED_MIHOMO_BIN" -f "$RUNTIME/config.yaml" -d "$RUNTIME" \
    >"$RUNTIME/mihomo.log" 2>&1 &
MIHOMO_PID=$!

curl_gateway() {
    local host="$1"
    curl --noproxy '*' --cacert "$RUNTIME/cert.pem" \
        --connect-timeout 1 --max-time 3 --silent --show-error --fail \
        --resolve "${host}:10443:127.0.0.3" \
        "https://${host}:10443/marker.txt"
}

ready=0
for _ in $(seq 1 30); do
    if body="$(curl_gateway console.example.test 2>/dev/null)" \
        && grep -Fq 'CONSOLE-BACKEND' <<<"$body"; then
        ready=1
        break
    fi
    kill -0 "$MIHOMO_PID" 2>/dev/null || break
    sleep 0.2
done
if [[ "$ready" != 1 ]]; then
    echo "mihomo regression fixture did not become ready" >&2
    cat "$RUNTIME/mihomo.log" >&2 || true
    exit 1
fi

# More than six malformed TLS-port connections would poison the legacy shared
# IP target and make subsequent valid connections skip sniffing for 600 seconds.
for _ in $(seq 1 8); do
    curl --noproxy '*' --connect-timeout 1 --max-time 2 --silent --show-error \
        "http://127.0.0.3:10443/" >/dev/null 2>&1 || true
done

console_body="$(curl_gateway console.example.test)"
grep -Fq 'CONSOLE-BACKEND' <<<"$console_body" \
    || { echo "console fallback failed after malformed traffic" >&2; exit 1; }

origin_body="$(curl_gateway origin.example.test)"
grep -Fq 'ORIGIN-BACKEND' <<<"$origin_body" \
    || { echo "origin SNI was not sniffed after malformed traffic" >&2; exit 1; }

echo "mihomo sniff-cache regression: PASS"
