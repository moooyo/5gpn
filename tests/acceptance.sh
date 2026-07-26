#!/usr/bin/env bash
# Post-upgrade acceptance for a released version on a real box.
#
# usage: acceptance.sh <expected-version>
#
# 0.0.29 changed three things that only a real upgrade can exercise, because
# each one depends on state a fresh install never has:
#
#   * DNS_CHINA / DNS_TRUST were retired from dns.env. Every existing box still
#     has them, and validate_dns_env_schema rejects unknown keys, so the
#     upgrade aborts unless retired keys are tolerated.
#   * upstreams.json becomes the sole source of truth. The installer must seed
#     it, and must carry the previous dns.env values across rather than
#     resetting to the shipped defaults.
#   * stats.json went from schema 1 to 2 (latency left the file). An old file
#     must be rejected cleanly and the daemon must start with zeroed counters,
#     not refuse to boot.
#
# Those checks stay: they are the ones that regress silently, and every future
# upgrade crosses the same code. 0.0.30 adds the trust probe's reserved-range
# detection.
#
# Read-only apart from one stats reset. Run after the upgrade completes.

set -uo pipefail

WANT_VERSION="${1:-}"
if [[ -z "$WANT_VERSION" ]]; then
    echo "usage: $0 <expected-version>" >&2
    exit 2
fi

PASS=0; FAIL=0; WARN=0
ok()   { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }
warn() { echo "  WARN  $*"; WARN=$((WARN+1)); }
note() { echo "        $*"; }

echo "== version and service health =="
ver="$(/opt/5gpn/bin/5gpn-dns --version 2>/dev/null)"
note "daemon version: ${ver:-<unknown>}"
[[ "$ver" == "$WANT_VERSION" ]] && ok "running $WANT_VERSION" || bad "expected $WANT_VERSION, got ${ver:-<unknown>}"
for u in 5gpn-dns mihomo 5gpn-intercept; do
    st="$(systemctl is-active "$u" 2>/dev/null)"
    [[ "$st" == active ]] && ok "$u active" || bad "$u is $st"
done

echo
echo "== the retired dns.env keys =="
if grep -qE '^DNS_CHINA=|^DNS_TRUST=' /etc/5gpn/dns.env 2>/dev/null; then
    bad "dns.env still carries DNS_CHINA/DNS_TRUST — the installer did not rewrite it"
else
    ok "dns.env no longer carries the retired upstream keys"
fi
grep -q '^DNS_UPSTREAMS=' /etc/5gpn/dns.env && ok "DNS_UPSTREAMS still points at the file" \
    || bad "DNS_UPSTREAMS missing from dns.env"

echo
echo "== upstreams.json is the source of truth =="
if [[ -f /etc/5gpn/upstreams.json ]]; then
    ok "upstreams.json exists"
    note "$(tr -d '\n ' < /etc/5gpn/upstreams.json)"
    python3 -c "
import json,sys
d=json.load(open('/etc/5gpn/upstreams.json'))
assert d['version']==1, d['version']
assert d['china'] and d['trust'], d
print('        china=%s trust=%s' % (d['china'], d['trust']))
" || bad "upstreams.json is malformed"
    # Capture first: `grep -q` closes the pipe as soon as it matches, journalctl
    # takes SIGPIPE, and `set -o pipefail` turns that into a failed pipeline — so
    # a successful match reads as a miss.
    boot_log="$(journalctl -u 5gpn-dns -b --no-pager 2>/dev/null)"
    if grep -q 'upstreams: loaded' <<<"$boot_log"; then
        ok "daemon loaded upstreams.json at boot"
        note "$(grep 'upstreams: loaded' <<<"$boot_log" | tail -1 | sed 's/.*upstreams:/upstreams:/')"
    else
        bad "no 'upstreams: loaded' line — the daemon fell back to built-in defaults"
        grep -i 'upstream' <<<"$boot_log" | tail -3 | sed 's/^/        /'
    fi
else
    bad "upstreams.json was not seeded by the installer"
fi

echo
echo "== stats schema migration =="
if [[ -f /etc/5gpn/stats.json ]]; then
    v="$(python3 -c "import json;print(json.load(open('/etc/5gpn/stats.json')).get('version'))" 2>/dev/null)"
    # Version 2 only appears after the daemon's first save (60s tick, shutdown,
    # or an explicit reset), so a v1 file here is not yet a failure.
    if [[ "$v" == 2 ]]; then
        ok "stats.json is at schema 2"
    else
        note "stats.json still at version ${v:-?} — the daemon has not saved since boot"
    fi
    python3 -c "
import json
d=json.load(open('/etc/5gpn/stats.json'))
stale=[k for k in d if 'lat_nanos' in k or 'lat_count' in k]
print('        stale latency fields:', stale or 'none')
raise SystemExit(1 if (stale and d.get('version')==2) else 0)
" || bad "a schema-2 stats.json still carries the retired cumulative latency fields"
else
    note "no stats.json yet (the persister writes on a 60s tick)"
fi
# The rejection log is the durable evidence of the migration; the on-disk
# version only reaches 2 after the daemon's first save.
if grep -qE 'stats:.*(unsupported schema version|unknown field)' <<<"$boot_log"; then
    ok "an old-schema stats.json was rejected cleanly at boot (counters start at zero)"
    note "$(grep -E 'stats:' <<<"$boot_log" | tail -1 | sed 's/.*stats:/stats:/')"
else
    note "no schema-rejection line — this box had no pre-0.0.29 stats.json"
fi

echo
echo "== trust upstream sanity probe =="
if grep -q 'trust upstream probe' <<<"$boot_log"; then
    line="$(grep 'trust upstream probe' <<<"$boot_log" | tail -1)"
    note "${line#*5gpn-dns\[*\]: }"
    # Don't accept either verdict blindly — decide independently whether the
    # address the probe got back is one a real recursive resolver could return,
    # then assert the probe agreed. 0.0.29 endorsed 198.18.1.12 (RFC 2544
    # benchmarking space) as genuine; ip.IsPrivate() is false for it, so the
    # private/loopback check alone never caught it.
    probe_ip="$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' <<<"$line" | tail -1)"
    flagged=no
    grep -qE "resolver's own /24|fabricated|never a real answer" <<<"$line" && flagged=yes
    should_flag="$(python3 -c "
import ipaddress,sys
ip=ipaddress.ip_address('$probe_ip')
print('yes' if not ip.is_global else 'no')
" 2>/dev/null)"
    note "resolved ${probe_ip:-?} | reserved=${should_flag:-?} | probe flagged=${flagged}"
    if [[ -z "$should_flag" ]]; then
        warn "could not classify ${probe_ip:-<none>} — probe verdict not checked"
    elif [[ "$should_flag" == "$flagged" ]]; then
        if [[ "$flagged" == yes ]]; then
            ok "probe flagged a reserved-range answer (the 0.0.30 widening)"
        else
            ok "probe ran and correctly accepted a globally-routable answer"
        fi
    elif [[ "$should_flag" == yes ]]; then
        bad "probe endorsed $probe_ip, which is not globally routable — the heuristic is too narrow"
    else
        bad "probe flagged $probe_ip, which is a legitimate public address — false positive"
    fi
else
    bad "the trust probe did not run (or did not log)"
fi

echo
echo "== API surface =="
TOKEN="$(grep -E '^DNS_API_TOKEN=' /etc/5gpn/dns.env | cut -d= -f2-)"
api() { curl -sk -H "Authorization: Bearer $TOKEN" "https://127.0.0.1$1" ${2:+-X "$2"}; }
st="$(api /api/status)"
if python3 -c "
import json,sys
d=json.loads(sys.stdin.read())['stats']
need=['china_p50_ms','china_p95_ms','china_lat_samples','trust_p50_ms','trust_p95_ms','trust_lat_samples']
missing=[k for k in need if k not in d]
gone=[k for k in ('china_avg_ms','trust_avg_ms') if k in d]
print('        p50/p95 fields present:', not missing, '| retired avg fields gone:', not gone)
raise SystemExit(1 if (missing or gone) else 0)
" <<<"$st"; then ok "/api/status reports latency percentiles"; else bad "/api/status latency fields are wrong"; fi

code="$(curl -sk -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $TOKEN" https://127.0.0.1/api/stats/reset)"
[[ "$code" == 200 ]] && ok "POST /api/stats/reset returns 200" || bad "POST /api/stats/reset returned $code"

mods="$(api /api/mihomo/ingress-modules)"
python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
for m in d['modules']:
    print('        %-18s enabled=%-5s manageable=%-5s %s' % (m['id'], m['enabled'], m['manageable'], m.get('reason','')))
" <<<"$mods"
if python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
q=[m for m in d['modules'] if m['id']=='block-quic-443'][0]
raise SystemExit(0 if q['manageable'] else 1)
" <<<"$mods"; then ok "block-quic-443 is manageable (capture rules no longer lock it)"
else bad "block-quic-443 is still locked"; fi

echo
echo "== summary: ${PASS} passed, ${FAIL} failed, ${WARN} warnings =="
[[ "$FAIL" -eq 0 ]]
