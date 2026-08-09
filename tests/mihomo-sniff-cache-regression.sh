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

RUNTIME="$(mktemp -d /tmp/5gpn-sniff-cache.XXXXXX)"
RUNTIME_MARKER=.5gpn-sniff-cache-test-owned
printf '%s\n' '5gpn-sniff-cache-test-v1' > "$RUNTIME/$RUNTIME_MARKER"
CONSOLE_PID=""
ORIGIN_PID=""
MIHOMO_PID=""

cleanup() {
    local pid attempt canonical
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
    canonical="$(readlink -f -- "$RUNTIME" 2>/dev/null || true)"
    if [[ "$canonical" == "$RUNTIME" && "$canonical" == /tmp/5gpn-sniff-cache.* \
       && "$(cat "$canonical/$RUNTIME_MARKER" 2>/dev/null || true)" == 5gpn-sniff-cache-test-v1 ]]; then
        rm -rf -- "$canonical"
    fi
}
trap cleanup EXIT INT TERM

mkdir -p "$RUNTIME/console" "$RUNTIME/origin"
printf 'CONSOLE-BACKEND\n' > "$RUNTIME/console/marker.txt"
printf 'ORIGIN-BACKEND\n' > "$RUNTIME/origin/marker.txt"

openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -subj '/CN=console.example.test' \
    -addext 'subjectAltName=DNS:console.example.test,DNS:origin.example.test' \
    -keyout "$RUNTIME/key.pem" -out "$RUNTIME/cert.pem" >/dev/null 2>&1

# The monolith treats client DoT and the loopback origin resolver as critical.
# This isolated runtime therefore needs its own complete DNS document rather
# than relying on the old degraded-start behavior. Pick three adjacent high
# ports that are free for both protocols so parallel CI jobs cannot collide.
dns_base=""
for _ in $(seq 1 100); do
    candidate=$((20000 + RANDOM % 20000))
    available=1
    for port in "$candidate" "$((candidate + 1))" "$((candidate + 2))"; do
        if ss -H -ltn "sport = :$port" | grep -q . \
           || ss -H -lun "sport = :$port" | grep -q .; then
            available=0
            break
        fi
    done
    if [[ "$available" == 1 ]]; then
        dns_base="$candidate"
        break
    fi
done
[[ -n "$dns_base" ]] || { echo "could not allocate isolated DNS listener ports" >&2; exit 1; }

mkdir -p "$RUNTIME/5gpn"
cat > "$RUNTIME/5gpn/dns.json" <<EOF
{
  "listen": {
    "dot": "127.0.0.1:${dns_base}",
    "debug": "127.0.0.1:$((dns_base + 1))",
    "origin": "127.0.0.1:$((dns_base + 2))",
    "certificate": "$RUNTIME/cert.pem",
    "privateKey": "$RUNTIME/key.pem"
  },
  "gateway": "198.51.100.1",
  "localNames": [],
  "upstreams": {"china": ["127.0.0.1:9"], "trust": ["127.0.0.1:9"], "ecs": ""},
  "policy": {"rules": [], "fallback": "direct"},
  "tuning": {}
}
EOF
chmod 0600 "$RUNTIME/5gpn/dns.json"

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
  $0 == "hosts:" {
    # The origin backend needs a mapping of its own, and this anchors on the
    # hosts key rather than on whatever happens to follow it. It used to anchor
    # on "rule-providers:", which was the next line only because the allowlist
    # provider lived there -- removing the allowlist deleted the anchor, the
    # injection silently stopped happening, and origin.example.test resolved
    # nowhere. The symptom was a curl timeout three assertions later.
    print
    print "  origin.example.test: 127.0.0.4"
    next
  }
  $0 == "rules:" {
    print
    # Keep the fixture route above the seed guards while excluding mihomo inner
    # dials. The monolith has no processor inbound or overlay egress socket;
    # extension traffic re-enters the ordinary rule path as INNER.
    print "  - AND,((NOT,((IN-TYPE,INNER))),(DOMAIN,origin.example.test)),DIRECT"
    next
  }
  {
    gsub(/__GATEWAY_IP__/, "10.0.0.1")
    gsub(/__CONSOLE_DOMAIN__/, "console.example.test")
    gsub(/__CONTROLLER_SECRET__/, "ci-controller-secret")
    gsub(/\/etc\/5gpn\/cert\/console\/current\/fullchain.pem/, cert)
    gsub(/\/etc\/5gpn\/cert\/console\/current\/privkey.pem/, key)
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

# The unit's SAFE_PATHS, taken from install.sh rather than restated, because the
# seed names the certificates and the UI bundle outside its own home directory.
# Without them the core refuses a config it will run.
export SAFE_PATHS="$MIHOMO_SAFE_PATHS"
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
