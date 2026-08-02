#!/usr/bin/env bash
# Mutation acceptance. Unlike acceptance-monolith.sh this one writes, so every
# check restores what it changed and the last thing it does is verify the
# gateway is back where it started.
set -u

pass=0; fail=0
ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }
head_() { echo; echo "== $1"; }

CONF=/etc/5gpn/mihomo/config.yaml
SECRET="$(grep -m1 -E "^secret:" "$CONF" | sed -E "s/^secret: *'?([^']*)'?.*/\1/")"
API="https://127.0.0.1:9090"
req() { curl -sk --max-time 30 -H "Authorization: Bearer ${SECRET}" -H 'Content-Type: application/json' "$@"; }
status() { curl -sk --max-time 30 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${SECRET}" -H 'Content-Type: application/json' "$@"; }

head_ "DNS document write"
orig="$(req "$API/gpn/dns")"
rev="$(echo "$orig" | jq -r .revision)"
doc="$(echo "$orig" | jq -c .document)"
orig_ecs="$(echo "$doc" | jq -r '.upstreams.ecs')"

# Change one field and prove it reaches the running resolver, not just the file.
body="$(jq -nc --arg r "$rev" --argjson d "$(echo "$doc" | jq -c '.upstreams.ecs = "203.0.113.0/24"')" '{revision:$r, document:$d}')"
after="$(req -X PUT --data "$body" "$API/gpn/dns")"
if [ "$(echo "$after" | jq -r '.document.upstreams.ecs')" = "203.0.113.0/24" ]; then
  ok "PUT /gpn/dns applied and returned the new document"
else
  bad "PUT /gpn/dns: $(echo "$after" | head -c 200)"
fi
newrev="$(echo "$after" | jq -r .revision)"
if [ "$newrev" != "$rev" ] && [ -n "$newrev" ]; then ok "the revision advanced"; else bad "the revision did not move"; fi

# Two tabs. The stale revision must lose rather than silently overwrite.
code="$(status -X PUT --data "$body" "$API/gpn/dns")"
if [ "$code" = "409" ]; then ok "a stale revision is refused with 409"; else bad "a stale write returned $code, expected 409"; fi

# An invalid document must leave the running resolver untouched.
badbody="$(jq -nc --arg r "$newrev" --argjson d "$(echo "$doc" | jq -c '.upstreams.trust = ["not-an-upstream"]')" '{revision:$r, document:$d}')"
code="$(status -X PUT --data "$badbody" "$API/gpn/dns")"
if [ "$code" = "400" ]; then ok "an invalid upstream spec is refused with 400"; else bad "an invalid document returned $code"; fi
if [ "$(req "$API/gpn/dns" | jq -r .revision)" = "$newrev" ]; then
  ok "the rejected write did not move the revision"
else
  bad "a rejected write changed the document"
fi

# Restore.
cur="$(req "$API/gpn/dns")"
restore="$(jq -nc --arg r "$(echo "$cur" | jq -r .revision)" \
                  --argjson d "$(echo "$cur" | jq -c --arg e "$orig_ecs" '.document | .upstreams.ecs = $e')" \
                  '{revision:$r, document:$d}')"
req -X PUT --data "$restore" "$API/gpn/dns" >/dev/null
if [ "$(req "$API/gpn/dns" | jq -r '.document.upstreams.ecs')" = "$orig_ecs" ]; then
  ok "the original client subnet was restored"
else
  bad "restore failed — the gateway is not where it started"
fi

head_ "resolver still serving after the writes"
if dig +short +timeout=5 @127.0.0.1 -p 5353 www.baidu.com A >/dev/null 2>&1; then
  ok "the resolver answers after four document writes"
else
  bad "the resolver stopped answering"
fi

head_ "interception settings write"
snap="$(req "$API/gpn/interception")"
irev="$(echo "$snap" | jq -r .revision)"
was="$(echo "$snap" | jq -r '.snapshot.enabled')"

on="$(jq -nc --arg r "$irev" '{revision:$r, enabled:true, http2:true, quicFallbackProtection:false}')"
res="$(req -X PUT --data "$on" "$API/gpn/interception/settings")"
if [ "$(echo "$res" | jq -r '.snapshot.enabled')" = "true" ]; then
  ok "the MITM master can be turned on"
else
  bad "turning the master on: $(echo "$res" | head -c 200)"
fi

# With the master on and no extensions, nothing is captured. Reporting the
# declared set as the active one would tell an operator their traffic is being
# intercepted when nothing is intercepting it.
if [ "$(echo "$res" | jq -r '.snapshot.active_capture_hosts | length')" = "0" ]; then
  ok "no capture hosts are active with no extensions installed"
else
  bad "capture hosts appeared with nothing installed"
fi

back="$(jq -nc --arg r "$(echo "$res" | jq -r .revision)" --argjson w "$was" \
        '{revision:$r, enabled:$w, http2:true, quicFallbackProtection:false}')"
res="$(req -X PUT --data "$back" "$API/gpn/interception/settings")"
if [ "$(echo "$res" | jq -r '.snapshot.enabled')" = "$was" ]; then
  ok "the master was restored to $was"
else
  bad "could not restore the master"
fi

head_ "extension review refuses what it should"
# A pasted manifest that is not the native format must be refused outright:
# there is no compatibility mode, because a partially understood manifest drops
# permissions and capture hosts silently.
res="$(req -X POST --data '{"content":"apiVersion: v1\nkind: ConfigMap\n"}' "$API/gpn/interception/review")"
if echo "$res" | jq -e '.message' >/dev/null 2>&1; then
  ok "a foreign manifest is refused: $(echo "$res" | jq -r '.message' | head -c 80)"
else
  bad "a foreign manifest was accepted: $(echo "$res" | head -c 200)"
fi

# An install without a reviewed digest is not a decision the operator made.
res="$(status -X POST --data '{"revision":"'"$(req "$API/gpn/interception" | jq -r .revision)"'","url":"https://example.invalid/x.yaml"}' "$API/gpn/interception/extensions")"
if [ "$res" = "400" ]; then ok "an install without a digest is refused"; else bad "install without a digest returned $res"; fi

echo
echo "======================================"
echo " $pass passed, $fail failed"
echo "======================================"
[ "$fail" -eq 0 ]
