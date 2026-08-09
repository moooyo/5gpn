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
API="https://127.0.0.1:443"
req() { curl -sk --max-time 30 -H "Authorization: Bearer ${SECRET}" -H 'Content-Type: application/json' "$@"; }
status() { curl -sk --max-time 30 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${SECRET}" -H 'Content-Type: application/json' "$@"; }

dns_restore_needed=false
orig_ecs_state='{"present":false,"value":null}'
test_ecs="203.0.113.0/24"
interception_restore_needed=false
master_before=false
http2_before=true

cleanup() {
  local current revision candidate
  if [ "$dns_restore_needed" = true ]; then
    current="$(req "$API/5gpn/dns" 2>/dev/null || true)"
    revision="$(echo "$current" | jq -r '.revision // ""' 2>/dev/null || true)"
    if [ -n "$revision" ] && [ "$(echo "$current" | jq -r '.document.upstreams.ecs // ""' 2>/dev/null || true)" = "$test_ecs" ]; then
      candidate="$(echo "$current" | jq -c --argjson original "$orig_ecs_state" '
        .document |
        if $original.present then .upstreams.ecs = $original.value
        else del(.upstreams.ecs)
        end
      ' 2>/dev/null || true)"
      [ -z "$candidate" ] || req -X PUT --data "$(jq -nc --arg r "$revision" --argjson d "$candidate" '{revision:$r, document:$d}')" "$API/5gpn/dns" >/dev/null 2>&1 || true
    fi
  fi
  if [ "$interception_restore_needed" = true ]; then
    current="$(req "$API/5gpn/interception" 2>/dev/null || true)"
    revision="$(echo "$current" | jq -r '.revision // ""' 2>/dev/null || true)"
    if [ -n "$revision" ] \
       && [ "$(echo "$current" | jq -r '.snapshot.enabled' 2>/dev/null || true)" = true ] \
       && [ "$(echo "$current" | jq -r '.snapshot.http2' 2>/dev/null || true)" = "$http2_before" ]; then
      req -X PUT --data "$(jq -nc --arg r "$revision" --argjson enabled "$master_before" --argjson h2 "$http2_before" '{revision:$r, enabled:$enabled, http2:$h2, http3:false}')" "$API/5gpn/interception/settings" >/dev/null 2>&1 || true
    fi
  fi
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

head_ "DNS document write"
orig="$(req "$API/5gpn/dns")"
rev="$(echo "$orig" | jq -r .revision)"
doc="$(echo "$orig" | jq -c .document)"
orig_ecs_state="$(echo "$doc" | jq -c '{present:(.upstreams | has("ecs")), value:.upstreams.ecs}')"
if [ "$(echo "$doc" | jq -r '.upstreams.ecs // ""')" = "$test_ecs" ]; then
  test_ecs="198.51.100.0/24"
fi

# Change one field and prove it reaches the running resolver, not just the file.
body="$(jq -nc --arg r "$rev" --argjson d "$(echo "$doc" | jq -c --arg ecs "$test_ecs" '.upstreams.ecs = $ecs')" '{revision:$r, document:$d}')"
dns_restore_needed=true
after="$(req -X PUT --data "$body" "$API/5gpn/dns")"
if [ "$(echo "$after" | jq -r '.document.upstreams.ecs')" = "$test_ecs" ]; then
  ok "PUT /5gpn/dns applied and returned the new document"
else
  bad "PUT /5gpn/dns: $(echo "$after" | head -c 200)"
fi
newrev="$(echo "$after" | jq -r .revision)"
if [ "$newrev" != "$rev" ] && [ -n "$newrev" ]; then ok "the revision advanced"; else bad "the revision did not move"; fi

# Two tabs. The stale revision must lose rather than silently overwrite.
code="$(status -X PUT --data "$body" "$API/5gpn/dns")"
if [ "$code" = "409" ]; then ok "a stale revision is refused with 409"; else bad "a stale write returned $code, expected 409"; fi

# Listener settings are installation-owned and fail before persistence.
listener_body="$(jq -nc --arg r "$newrev" --argjson d "$(echo "$after" | jq -c '.document | .listen.debug = "127.0.0.1:5355"')" '{revision:$r, document:$d}')"
code="$(status -X PUT --data "$listener_body" "$API/5gpn/dns")"
if [ "$code" = "400" ]; then ok "listener changes are refused with 400"; else bad "a listener change returned $code"; fi
if [ "$(req "$API/5gpn/dns" | jq -r .revision)" = "$newrev" ]; then
  ok "the rejected listener change did not move the revision"
else
  bad "a rejected listener change changed the document"
fi

# An invalid document must leave the running resolver untouched.
badbody="$(jq -nc --arg r "$newrev" --argjson d "$(echo "$doc" | jq -c '.upstreams.trust = ["not-an-upstream"]')" '{revision:$r, document:$d}')"
code="$(status -X PUT --data "$badbody" "$API/5gpn/dns")"
if [ "$code" = "400" ]; then ok "an invalid upstream spec is refused with 400"; else bad "an invalid document returned $code"; fi
if [ "$(req "$API/5gpn/dns" | jq -r .revision)" = "$newrev" ]; then
  ok "the rejected write did not move the revision"
else
  bad "a rejected write changed the document"
fi

# Restore.
cur="$(req "$API/5gpn/dns")"
if [ "$(echo "$cur" | jq -r '.document.upstreams.ecs // ""')" = "$test_ecs" ]; then
  restore="$(jq -nc --arg r "$(echo "$cur" | jq -r .revision)" \
                    --argjson d "$(echo "$cur" | jq -c --argjson original "$orig_ecs_state" '
                      .document |
                      if $original.present then .upstreams.ecs = $original.value
                      else del(.upstreams.ecs)
                      end
                    ')" \
                    '{revision:$r, document:$d}')"
  req -X PUT --data "$restore" "$API/5gpn/dns" >/dev/null
else
  bad "the ECS field changed concurrently; refusing to overwrite it during restore"
fi
if [ "$(req "$API/5gpn/dns" | jq -c '{present:(.document.upstreams | has("ecs")), value:.document.upstreams.ecs}')" = "$orig_ecs_state" ]; then
  dns_restore_needed=false
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
snap="$(req "$API/5gpn/interception")"
irev="$(echo "$snap" | jq -r .revision)"
master_before="$(echo "$snap" | jq -r '.snapshot.enabled')"
http2_before="$(echo "$snap" | jq -r '.snapshot.http2')"
module_count="$(echo "$snap" | jq -r '.snapshot.modules | length')"

if [ "$module_count" = "0" ]; then
  on="$(jq -nc --arg r "$irev" --argjson h2 "$http2_before" '{revision:$r, enabled:true, http2:$h2, http3:false}')"
  interception_restore_needed=true
  res="$(req -X PUT --data "$on" "$API/5gpn/interception/settings")"
  if [ "$(echo "$res" | jq -r '.snapshot.enabled')" = "true" ]; then
    ok "the MITM master can be turned on"
  else
    bad "turning the master on: $(echo "$res" | head -c 200)"
  fi

  # With the master on and no extensions, nothing is captured. Reporting the
  # declared set as active would tell an operator that traffic is intercepted
  # when no extension owns it.
  if [ "$(echo "$res" | jq -r '.snapshot.active_capture_hosts | length')" = "0" ]; then
    ok "no capture hosts are active with no extensions installed"
  else
    bad "capture hosts appeared with nothing installed"
  fi

  back="$(jq -nc --arg r "$(echo "$res" | jq -r .revision)" --argjson enabled "$master_before" --argjson h2 "$http2_before" \
          '{revision:$r, enabled:$enabled, http2:$h2, http3:false}')"
  res="$(req -X PUT --data "$back" "$API/5gpn/interception/settings")"
  if [ "$(echo "$res" | jq -r '.snapshot.enabled')" = "$master_before" ] \
     && [ "$(echo "$res" | jq -r '.snapshot.http2')" = "$http2_before" ]; then
    interception_restore_needed=false
    ok "the interception settings were restored"
  else
    bad "could not restore the interception settings"
  fi
else
  echo "  SKIP: interception setting writes (the deployment already has extensions)"
fi

head_ "extension review refuses what it should"
# A pasted manifest that is not the native format must be refused outright:
# there is no compatibility mode, because a partially understood manifest drops
# permissions and capture hosts silently.
res="$(req -X POST --data '{"content":"apiVersion: v1\nkind: ConfigMap\n"}' "$API/5gpn/interception/review")"
if echo "$res" | jq -e '.message' >/dev/null 2>&1; then
  ok "a foreign manifest is refused: $(echo "$res" | jq -r '.message' | head -c 80)"
else
  bad "a foreign manifest was accepted: $(echo "$res" | head -c 200)"
fi

# An install without a reviewed digest is not a decision the operator made.
res="$(status -X POST --data '{"revision":"'"$(req "$API/5gpn/interception" | jq -r .revision)"'","url":"https://example.invalid/x.yaml"}' "$API/5gpn/interception/extensions")"
if [ "$res" = "400" ]; then ok "an install without a digest is refused"; else bad "install without a digest returned $res"; fi

echo
echo "======================================"
echo " $pass passed, $fail failed"
echo "======================================"
[ "$fail" -eq 0 ]
