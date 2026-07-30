#!/usr/bin/env bash
# Full real-traffic verification of the runtime-overlay arrangement.
#
# Every check drives actual traffic through the gateway and reads what the data
# plane did, rather than asserting against a model of it. The ones that matter
# most are the negative ones: a capture that cannot be serviced has to be
# refused, and it has to be refused without taking anything else down with it.
set -uo pipefail

GW="${GW:-10.0.1.20}"
CAPTURED="${CAPTURED:-gs-loc.apple.com}"
UNCAPTURED="${UNCAPTURED:-example.com}"
SOCKET=/run/mihomo/overlay-control.sock
DNS_UID=999 DNS_GID=989 CTL_GID=984

pass=0 fail=0
ok()   { printf '  ok   - %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL - %s\n' "$1"; fail=$((fail+1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1 ($2)"; else bad "$1: got $2, want $3"; fi; }

secret() { grep -oE '^secret: .*' /etc/5gpn/mihomo/config.yaml | head -1 | sed 's/secret: //; s/^.//; s/.$//'; }
readback() { setpriv --reuid=$DNS_UID --regid=$DNS_GID --groups $CTL_GID \
  curl -s --unix-socket $SOCKET http://x/runtime-overlays/5gpn; }
field() { readback | python3 -c "import sys,json;print(json.load(sys.stdin).get('$1',''))"; }
hit()  { curl -sk --max-time 12 --resolve "$1:443:$GW" "https://$1/" -o /dev/null -w '%{http_code}' 2>/dev/null; }

echo "== 1. the overlay is the driver =="
# Scoped to the running process, not the whole journal. Without --since the
# match can come from an incarnation that has since been restarted and failed
# to bring the driver up, so the check would claim the overlay is driving a
# gateway that has stopped driving with it — the one thing it exists to detect.
#
# grep -q closes the pipe on its first match, so with pipefail the producer's
# SIGPIPE becomes the pipeline's status and a found match reads as a failure.
dns_started=$(systemctl show 5gpn-dns -p ActiveEnterTimestamp --value 2>/dev/null)
driver_log=$(journalctl -u 5gpn-dns --since "${dns_started:--10min}" --no-pager   | grep -c "publishing routing as typed generations" || true)
[[ "$driver_log" -gt 0 ]] \
  && ok "the coordinator selected the overlay driver" \
  || bad "the coordinator did not select the overlay driver"
[[ -S $SOCKET ]] && ok "the control socket exists" || bad "no control socket"
check "a generation is live" "$([[ -n $(field activeGeneration) ]] && echo yes || echo no)" yes

echo
echo "== 2. the operator's config is not the medium =="
# The proxy definition line also ends in MODULE-INTERCEPT; only a rule steering
# at it does so after a comma.
rendered=$(grep -c ',MODULE-INTERCEPT$' /etc/5gpn/mihomo/config.yaml || true)
check "rendered capture rules remaining" "$rendered" 0
rulecount=$(python3 - <<'PYEOF'
import io
lines = io.open('/etc/5gpn/mihomo/config.yaml', encoding='utf-8').read().split('\n')
start = next(i for i, l in enumerate(lines) if l.strip() == 'rules:')
print(sum(1 for l in lines[start+1:] if l.strip().startswith('- ')))
PYEOF
)
# The order of magnitude is the claim; the exact count is a property of this
# box's own operator rules.
[[ "$rulecount" -lt 40 ]] \
  && ok "the rule list is the operator's own ($rulecount rules; 1353 before migration)" \
  || bad "the rule list still carries daemon-rendered rules ($rulecount)"
before=$(sha256sum /etc/5gpn/mihomo/config.yaml | cut -d' ' -f1)

echo
echo "== 3. real traffic, both directions =="
# Read what the core logged rather than snapshotting /connections. A capture and
# its onward connection can complete inside the gap between driving the traffic
# and taking the snapshot, so the snapshot reports honestly that nothing is live
# — and a test that calls that a failure is testing its own timing. The log is
# the durable record of every match the data plane actually made.
mark=$(date -u '+%Y-%m-%d %H:%M:%S')
sleep 1
for i in 1 2 3; do
  curl -sk --max-time 8 --resolve "$CAPTURED:443:$GW" "https://$CAPTURED/clls/wloc" -o /dev/null 2>/dev/null
done
sleep 2
journalctl -u mihomo --since "$mark" --no-pager 2>/dev/null > /tmp/verify-match.txt

grep -q "match RuntimeOverlayClient" /tmp/verify-match.txt \
  && ok "captured traffic resolved through the client anchor" \
  || bad "captured traffic did not reach the client anchor"
grep -q "match RuntimeOverlayClient.*using MODULE-INTERCEPT" /tmp/verify-match.txt \
  && ok "and was steered at the processor" \
  || bad "it was not steered at the processor"
grep -q "match RuntimeOverlayEgress" /tmp/verify-match.txt \
  && ok "the processor's onward traffic resolved through the egress anchor" \
  || bad "the processor's onward traffic did not reach the egress anchor"

echo
echo "== 4. everything else is untouched =="
check "an uncaptured host still resolves and connects" "$(hit "$UNCAPTURED")" 200

echo
echo "== 5. fail closed when the processor is gone =="
systemctl stop 5gpn-intercept >/dev/null 2>&1
sleep 20
check "the lease is reported expired" "$(field leaseState)" expired
check "the processor is reported not-ready" "$(field processorState)" not-ready
check "a captured host is refused" "$(hit "$CAPTURED")" 000
check "an uncaptured host is unaffected" "$(hit "$UNCAPTURED")" 200
systemctl start 5gpn-intercept >/dev/null 2>&1
sleep 10
check "readiness returns on its own" "$(field processorState)" ready

echo
echo "== 6. the config was never rewritten by any of this =="
after=$(sha256sum /etc/5gpn/mihomo/config.yaml | cut -d' ' -f1)
check "config digest unchanged" "$after" "$before"

echo
echo "== 7. mutation is not reachable over HTTP =="
SECRET=$(secret)
for verb in PUT POST DELETE; do
  code=$(curl -sk --max-time 6 -X $verb -H "Authorization: Bearer $SECRET" \
    https://127.0.0.1:9090/runtime-overlays/5gpn -o /dev/null -w '%{http_code}')
  check "$verb /runtime-overlays/5gpn is refused" "$code" 405
done
code=$(curl -sk --max-time 6 -H "Authorization: Bearer $SECRET" \
  https://127.0.0.1:9090/runtime-overlays/5gpn -o /dev/null -w '%{http_code}')
check "GET is served, so the console can render state" "$code" 200

echo
echo "== 8. the sockets admit only the process they name =="
curl -s --max-time 6 --unix-socket $SOCKET http://x/capabilities >/dev/null 2>&1 \
  && bad "root reached the overlay control socket" \
  || ok "root is refused by the overlay control socket"
# The interesting case is not root, which the filesystem would stop anyway. It
# is a service account the filesystem lets through: gpn-intercept is in the
# sidecar socket's group and can open it, and is still refused because the
# credential check is a separate gate from the mode.
coord=$(setpriv --reuid=999 --regid=989 --groups 985 curl -s --max-time 6 \
  --unix-socket /run/5gpn-intercept/control.sock http://x/state -o /dev/null -w '%{http_code}')
check "the coordinator reaches the sidecar control API" "$coord" 200
other=$(setpriv --reuid=994 --regid=985 --groups 985 curl -s --max-time 6 \
  --unix-socket /run/5gpn-intercept/control.sock http://x/state -o /dev/null -w '%{http_code}')
check "a group member that is not the coordinator is refused" "$other" 000

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
