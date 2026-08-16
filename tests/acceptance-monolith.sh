#!/usr/bin/env bash
# Post-deploy acceptance for the 5gpn monolith. Read-only: it asks the running
# gateway questions and checks the answers. Nothing here changes state.
#
# It must pass on a gateway that was *installed*, not only on one migrated from
# the three-process layout. Three checks used to assert migrated content — an
# enabled block rule, a non-empty policy, and a subscription with fetched
# entries — none of which a fresh gateway has by design, so they failed forever
# and 17/20 became a number nobody could read a regression out of.
#
# They are now conditional and report `--` when there is nothing to assert
# against. What that costs is real and worth naming: on a gateway with no
# policy and no subscriptions, this suite no longer proves that a block rule
# produces NXDOMAIN or that a subscription fetch ever completes. Asserting that
# needs a configured gateway, and there is no suite that requires one.
#
# Run on the gateway itself. Exits non-zero if any check fails.
set -u

pass=0; fail=0
ok()   { echo "  ok: $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL: $1"; fail=$((fail+1)); }
skip_(){ echo "  --: $1"; }
head_() { echo; echo "== $1"; }

CONF=/etc/5gpn/mihomo/config.yaml
INSTALLER=/opt/5gpn/install.sh
ZASH_VERSION_FILE=/opt/5gpn/ui/.zash_version
SECRET="$(grep -m1 -E "^secret:" "$CONF" | sed -E "s/^secret: *'?([^']*)'?.*/\1/")"
API="https://127.0.0.1:443"
CURL=(curl -sk --max-time 15 -H "Authorization: Bearer ${SECRET}")

GATEWAY="$(jq -r '.gateway' /etc/5gpn/mihomo/5gpn/dns.json)"

# --- DNS: the three listeners -------------------------------------------
head_ "DNS listeners"

# A name no rule matches and that has a domestic presence: auto arbitration
# should keep the real address rather than steer it.
out="$(dig +short +timeout=5 @127.0.0.1 -p 5353 www.baidu.com A 2>/dev/null | head -3)"
if [ -n "$out" ]; then ok "debug listener answers ($(echo "$out" | tr '\n' ' '))"; else bad "debug listener returned nothing"; fi

# DoT over the public listener, with the deployed leaf.
if command -v kdig >/dev/null 2>&1; then
  out="$(kdig +short +tls @127.0.0.1 -p 853 www.baidu.com A 2>/dev/null | head -2)"
  if [ -n "$out" ]; then ok "DoT :853 answers over TLS"; else bad "DoT :853 did not answer"; fi
else
  # No kdig: prove the TLS handshake and that the port speaks DNS-over-TLS by
  # checking the certificate presents. A bound socket alone proves nothing.
  if echo | openssl s_client -connect 127.0.0.1:853 -servername dot.5gpn.test 2>/dev/null | grep -q "BEGIN CERTIFICATE"; then
    ok "DoT :853 completes a TLS handshake and presents a leaf"
  else
    bad "DoT :853 did not present a certificate"
  fi
fi

# --- the two boundaries disagree, which is the whole design --------------
head_ "client vs origin boundary"

steered="$(dig +short +timeout=5 @127.0.0.1 -p 5353 www.google.com A 2>/dev/null | head -1)"
origin="$(dig +short +timeout=5 @127.0.0.1 -p 5354 www.google.com A 2>/dev/null | head -1)"
if [ "$steered" = "$GATEWAY" ]; then
  ok "a foreign name is steered to the gateway ($steered)"
else
  bad "a foreign name resolved to '$steered', expected the gateway $GATEWAY"
fi
if [ -n "$origin" ] && [ "$origin" != "$GATEWAY" ]; then
  ok "the origin boundary returns the real address ($origin)"
else
  bad "the origin boundary returned '$origin' — it must not answer with the gateway"
fi

# --- IPv4-only: both boundaries withhold AAAA ----------------------------
head_ "AAAA is withheld"
for port in 5353 5354; do
  n="$(dig +short +timeout=5 @127.0.0.1 -p $port www.google.com AAAA 2>/dev/null | grep -c ':' || true)"
  if [ "$n" = "0" ]; then ok "port $port returns no AAAA"; else bad "port $port returned $n AAAA record(s)"; fi
done
# HTTPS/SVCB carry ipv4hint and ECH, and are withheld for the same reason.
n="$(dig +timeout=5 @127.0.0.1 -p 5353 cloudflare.com HTTPS 2>/dev/null | grep -c '^cloudflare.com.*HTTPS' || true)"
if [ "$n" = "0" ]; then ok "HTTPS/SVCB is withheld"; else bad "an HTTPS record was served"; fi

# --- the ordered policy is live ------------------------------------------
head_ "policy"
# Only asserted when a policy exists. A gateway that was installed rather than
# migrated has no rules by design, and demanding one here asserted a *migrated*
# gateway from a suite that also has to pass on a fresh one.
blocked="$(jq -r '[.policy.rules[]?|select(.intent=="block" and .enabled and .kind=="domain-suffix")][0].value' /etc/5gpn/mihomo/5gpn/dns.json)"
if [ -n "$blocked" ] && [ "$blocked" != "null" ]; then
  rc="$(dig +timeout=5 @127.0.0.1 -p 5353 "$blocked" A 2>/dev/null | grep -m1 'status:' | sed -E 's/.*status: ([A-Z]+).*/\1/')"
  if [ "$rc" = "NXDOMAIN" ]; then ok "a blocked name ($blocked) returns NXDOMAIN"; else bad "blocked name $blocked returned $rc"; fi
else
  skip_ "no enabled block rule in the policy — nothing to resolve against"
fi

# --- control API ----------------------------------------------------------
head_ "control API"
caps="$("${CURL[@]}" "$API/capabilities")"
declare -A expected_feature_versions=(
  [5gpn-core]=1
  [5gpn-dns]=1
  [5gpn-interception]=7
  [5gpn-bot]=1
)
for feature in 5gpn-core 5gpn-dns 5gpn-interception 5gpn-bot; do
  expected="${expected_feature_versions[$feature]}"
  if echo "$caps" | jq -e --arg feature "$feature" --argjson expected "$expected" \
      '.features[$feature].version == $expected' >/dev/null 2>&1; then
    ok "$feature advertised at version $expected"
  else
    bad "$feature did not advertise version $expected: $(echo "$caps" | jq -c '.features' 2>/dev/null)"
  fi
done

dnsdoc="$("${CURL[@]}" "$API/5gpn/dns")"
rules="$(echo "$dnsdoc" | jq -r '.document.policy.rules | length' 2>/dev/null)"
rev="$(echo "$dnsdoc" | jq -r '.revision' 2>/dev/null)"
# The document must be served with a revision and a policy list. How many rules
# are in it is the operator's business, not this suite's: zero is what a fresh
# gateway has, and `[]` rather than null is what the seed guarantees.
if [ -n "$rev" ] && [ "$rev" != "null" ] && [ "${rules:-x}" != "x" ] && [ "$rules" != "null" ]; then
  ok "GET /5gpn/dns serves $rules rule(s), revision ${rev:0:12}"
else
  bad "GET /5gpn/dns did not serve a document with a policy list and a revision"
fi

subs="$(echo "$dnsdoc" | jq -r '[.subscriptions[]?|select(.entries>0)]|length' 2>/dev/null)"
if [ "${subs:-0}" -gt 0 ] 2>/dev/null; then
  ok "$subs subscription(s) fetched and live"
else
  skip_ "no subscription has fetched entries — none is configured on this gateway"
fi

cn="$(echo "$dnsdoc" | jq -r '.stats.cnRanges' 2>/dev/null)"
if [ "${cn:-0}" -gt 1000 ] 2>/dev/null; then ok "CN arbitration set loaded ($cn ranges)"; else bad "CN set has $cn ranges — the whole domestic internet would read as foreign"; fi

icept="$("${CURL[@]}" "$API/5gpn/interception")"
if echo "$icept" | jq -e '.snapshot | has("enabled")' >/dev/null 2>&1; then
  ok "GET /5gpn/interception serves a snapshot (master: $(echo "$icept" | jq -r '.snapshot.enabled'))"
else
  bad "GET /5gpn/interception: $(echo "$icept" | head -c 200)"
fi

# The diagnostic must agree with what the resolver actually did, and must report
# both boundaries -- the client answer alone reads as "DNS is broken".
exp="$("${CURL[@]}" "$API/5gpn/dns/resolve?name=www.google.com")"
if echo "$exp" | jq -e '.answers[0] == "'"$GATEWAY"'"' >/dev/null 2>&1 \
   && echo "$exp" | jq -e '(.origin|length) > 0' >/dev/null 2>&1; then
  ok "resolve diagnostic reports both boundaries (reason: $(echo "$exp" | jq -r '.verdict.reason'))"
else
  bad "resolve diagnostic: $(echo "$exp" | head -c 300)"
fi

qlog="$("${CURL[@]}" "$API/5gpn/dns/querylog?limit=5")"
n="$(echo "$qlog" | jq -r '.entries|length' 2>/dev/null)"
if [ "${n:-0}" -gt 0 ] 2>/dev/null; then ok "query log has $n recent entries"; else bad "query log is empty after the queries above"; fi

# --- the UI ---------------------------------------------------------------
head_ "zashboard"
zash_pin="$(sed -n 's/^ZASH_VERSION="\([^"]*\)".*/\1/p' "$INSTALLER" 2>/dev/null | head -n 1)"
deployed_zash="$(cat "$ZASH_VERSION_FILE" 2>/dev/null || true)"
if [ -n "$zash_pin" ] && [ "$deployed_zash" = "$zash_pin" ]; then
  ok "the deployed zashboard marker matches the installed $zash_pin pin"
else
  bad "zashboard pin/marker mismatch (pin=${zash_pin:-missing}, marker=${deployed_zash:-missing})"
fi
code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 "$API/ui/")"
if [ "$code" = "200" ]; then ok "/ui/ serves the bundle"; else bad "/ui/ returned HTTP $code"; fi
# /ui/ must be reachable WITHOUT the controller secret: an unenrolled client has
# no credential yet. Everything else must not be.
code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 "$API/5gpn/dns")"
if [ "$code" = "401" ]; then ok "/5gpn/dns refuses an unauthenticated request"; else bad "/5gpn/dns returned $code without a token"; fi

# --- forwarding still works ----------------------------------------------
head_ "data plane"
if "${CURL[@]}" "$API/version" | jq -e '.version' >/dev/null 2>&1; then
  ok "controller reports version $("${CURL[@]}" "$API/version" | jq -r '.version')"
else
  bad "controller /version did not answer"
fi

echo
echo "======================================"
echo " $pass passed, $fail failed"
echo "======================================"
[ "$fail" -eq 0 ]
