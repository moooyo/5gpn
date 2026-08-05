#!/usr/bin/env bash
# End-to-end extension lifecycle against a running gateway.
#
# This is the chain nothing else covers: a manifest is reviewed, installed
# against the digest that review returned, enabled, and the certificate the
# interception engine needs is minted by a root oneshot that never sees the
# manifest -- it reads the host set the engine published. Every step below is a
# different program, and the point is that they agree.
#
# It installs and then removes what it installed. The last checks verify the
# gateway is back where it started.
set -u

pass=0; fail=0
ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }
head_() { echo; echo "== $1"; }

CONF=/etc/5gpn/mihomo/config.yaml
SECRET="$(grep -m1 -E "^secret:" "$CONF" | sed -E "s/^secret: *'?([^']*)'?.*/\1/")"
API="https://127.0.0.1:443"
REQUEST=/etc/5gpn/mihomo/gpn/certificate-request
HOST=smoke.5gpn-beta.example
EXT=beta.smoke

req() { curl -sk --max-time 60 -H "Authorization: Bearer ${SECRET}" -H 'Content-Type: application/json' "$@"; }
irev() { req "$API/gpn/interception" | jq -r .revision; }

MANIFEST="$(cat <<YAML
apiVersion: 5gpn.io/v1
kind: Extension
metadata:
  id: ${EXT}
  name: Beta Smoke Test
  version: 0.1.0
  description: Installed by the beta acceptance run and removed again.
permissions:
  persistentStorage: false
  network: false
traffic:
  captureHosts:
    - ${HOST}
actions:
  - id: noop
    phase: request
    match:
      hosts: [${HOST}]
      pathRegex: "^/"
    script:
      inline: "function transform(context) { return {}; }"
      bodyMode: none
YAML
)"

digest_before="$(head -n1 "$REQUEST")"

head_ "review"
body="$(jq -nc --arg c "$MANIFEST" '{content:$c}')"
review="$(req -X POST --data "$body" "$API/gpn/interception/review")"
cand="$(echo "$review" | jq -r '.candidate.digest // ""')"
if [ -n "$cand" ]; then
  ok "the manifest reviews to digest ${cand:0:16}"
else
  bad "review failed: $(echo "$review" | head -c 300)"
  echo "$pass passed, $fail failed"; exit 1
fi
if [ "$(echo "$review" | jq -r '.candidate.detail.capture_hosts[0]')" = "$HOST" ]; then
  ok "the review reports the capture host it will acquire"
else
  bad "the review did not report the capture host"
fi
if [ "$(echo "$review" | jq -r '.candidate.installed // "none"')" = "none" ]; then
  ok "the review reports nothing installed under this id yet"
else
  bad "the review claims something is already installed"
fi

head_ "install"
# A digest that does not match what a fresh fetch produces must be refused --
# that check is the whole reason the digest exists.
wrong="$(jq -nc --arg r "$(irev)" --arg c "$MANIFEST" '{revision:$r, digest:"0000000000000000", content:$c}')"
if req -X POST --data "$wrong" "$API/gpn/interception/extensions" | jq -e '.message' >/dev/null 2>&1; then
  ok "an install quoting the wrong digest is refused"
else
  bad "an install with a wrong digest was accepted"
fi

body="$(jq -nc --arg r "$(irev)" --arg d "$cand" --arg c "$MANIFEST" '{revision:$r, digest:$d, content:$c}')"
res="$(req -X POST --data "$body" "$API/gpn/interception/extensions")"
if echo "$res" | jq -e --arg id "$EXT" '.snapshot.modules[] | select(.id == $id)' >/dev/null 2>&1; then
  ok "the extension is installed"
else
  bad "install failed: $(echo "$res" | head -c 300)"
fi
if [ "$(echo "$res" | jq -r --arg id "$EXT" '.snapshot.modules[]|select(.id==$id)|.enabled')" = "false" ]; then
  ok "it landed disabled, as every install must"
else
  bad "the install landed enabled"
fi
# Nothing has been enabled, so the certificate must not have moved.
if [ "$(head -n1 "$REQUEST")" = "$digest_before" ]; then
  ok "installing alone did not change what the certificate must cover"
else
  bad "the certificate request moved on an install that enabled nothing"
fi

head_ "enable, and the certificate that follows"
res="$(req -X PUT --data "$(jq -nc --arg r "$(irev)" '{revision:$r, enabled:true}')" \
        "$API/gpn/interception/extensions/${EXT}/enabled")"
if [ "$(echo "$res" | jq -r --arg id "$EXT" '.snapshot.modules[]|select(.id==$id)|.enabled')" = "true" ]; then
  ok "the extension is enabled"
else
  bad "enable failed: $(echo "$res" | head -c 300)"
fi

if grep -Fxq "$HOST" "$REQUEST"; then
  ok "the engine published the host into the certificate request"
else
  bad "the certificate request does not name $HOST: $(cat "$REQUEST")"
fi
if [ "$(head -n1 "$REQUEST")" != "$digest_before" ]; then
  ok "the request digest moved, which is what triggers a reissue"
else
  bad "the request digest did not move"
fi

systemctl start 5gpn-intercept-cert.service >/dev/null 2>&1
sleep 2
if [ "$(systemctl show 5gpn-intercept-cert.service -p Result --value)" = "success" ]; then
  ok "the root oneshot minted a leaf from the published request"
else
  bad "the certificate oneshot failed: $(journalctl -u 5gpn-intercept-cert.service -n 3 --no-pager | tail -1)"
fi
if openssl x509 -in /etc/5gpn/intercept/tls/leaf.crt -noout -checkhost "$HOST" 2>/dev/null | grep -q 'does match'; then
  ok "the minted leaf covers $HOST"
else
  bad "the leaf does not cover $HOST"
fi

head_ "the resolver sees the capture"
# With the master off the declaration is carried but inert -- and the diagnostic
# has to say so, because the extensions page shows the extension as enabled.
exp="$(req "$API/gpn/dns/resolve?name=${HOST}")"
if [ "$(echo "$exp" | jq -r '.capture.extensionId')" = "$EXT" ]; then
  ok "the resolver attributes the name to the extension"
else
  bad "the resolver does not know about the capture: $(echo "$exp" | head -c 250)"
fi
if [ "$(echo "$exp" | jq -r '.capture.ready')" = "false" ]; then
  ok "the capture reports not-ready while the MITM master is off"
else
  bad "the capture claims ready with the master off"
fi

req -X PUT --data "$(jq -nc --arg r "$(irev)" '{revision:$r, enabled:true, http2:true, http3:false}')" \
    "$API/gpn/interception/settings" >/dev/null
exp="$(req "$API/gpn/dns/resolve?name=${HOST}")"
gw="$(jq -r .gateway /etc/5gpn/mihomo/gpn/dns.json)"
if [ "$(echo "$exp" | jq -r '.capture.ready')" = "true" ] \
   && [ "$(echo "$exp" | jq -r '.answers[0]')" = "$gw" ] \
   && [ "$(echo "$exp" | jq -r '.verdict.reason')" = "force-proxy" ]; then
  ok "with the master on the name steers to the gateway as force-proxy"
else
  bad "the capture did not steer: $(echo "$exp" | jq -c '{ready:.capture.ready, answers, reason:.verdict.reason}')"
fi

head_ "clean up"
req -X PUT --data "$(jq -nc --arg r "$(irev)" '{revision:$r, enabled:false, http2:true, http3:false}')" \
    "$API/gpn/interception/settings" >/dev/null
res="$(req -X DELETE --data "$(jq -nc --arg r "$(irev)" '{revision:$r}')" "$API/gpn/interception/extensions/${EXT}")"
if echo "$res" | jq -e --arg id "$EXT" '[.snapshot.modules[]|select(.id==$id)]|length == 0' >/dev/null 2>&1; then
  ok "the extension is uninstalled"
else
  bad "uninstall failed: $(echo "$res" | head -c 250)"
fi
if [ "$(head -n1 "$REQUEST")" = "$digest_before" ]; then
  ok "the certificate request is back where it started"
else
  bad "the request did not return to its original digest"
fi
if [ "$(req "$API/gpn/interception" | jq -r '.snapshot.enabled')" = "false" ]; then
  ok "the MITM master is off again"
else
  bad "the master was left on"
fi

echo
echo "======================================"
echo " $pass passed, $fail failed"
echo "======================================"
[ "$fail" -eq 0 ]
