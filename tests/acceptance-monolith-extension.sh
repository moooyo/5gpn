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
REQUEST=/etc/5gpn/mihomo/5gpn/certificate-request
RESULT=/etc/5gpn/intercept/cert-state
CERT_LOCK=/run/5gpn/cert-renew.lock
HOST=smoke.5gpn-beta.example
EXT=beta.smoke

req() { curl -sk --max-time 60 -H "Authorization: Bearer ${SECRET}" -H 'Content-Type: application/json' "$@"; }
irev() { req "$API/5gpn/interception" | jq -r .revision; }

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

initial="$(req "$API/5gpn/interception")"
master_before="$(echo "$initial" | jq -r '.snapshot.enabled')"
http2_before="$(echo "$initial" | jq -r '.snapshot.http2')"
digest_before="$(jq -r '.target_digest' "$REQUEST")"
[[ "$digest_before" =~ ^[0-9a-f]{64}$ ]] \
  || { bad "the initial certificate request is not JSON v1"; echo "$pass passed, $fail failed"; exit 1; }

head_ "review"
body="$(jq -nc --arg c "$MANIFEST" '{content:$c}')"
review="$(req -X POST --data "$body" "$API/5gpn/interception/review")"
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
if req -X POST --data "$wrong" "$API/5gpn/interception/extensions" | jq -e '.message' >/dev/null 2>&1; then
  ok "an install quoting the wrong digest is refused"
else
  bad "an install with a wrong digest was accepted"
fi

body="$(jq -nc --arg r "$(irev)" --arg d "$cand" --arg c "$MANIFEST" '{revision:$r, digest:$d, content:$c}')"
res="$(req -X POST --data "$body" "$API/5gpn/interception/extensions")"
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
if [ "$(jq -r '.target_digest' "$REQUEST")" = "$digest_before" ]; then
  ok "installing alone did not change what the certificate must cover"
else
  bad "the certificate request moved on an install that enabled nothing"
fi

head_ "enable, and the certificate that follows"
# Make the traffic boundary live before enable. Holding the publisher lock
# creates a deterministic pending window, so the acceptance proves that an
# authorized extension is not active until the fenced root transaction commits.
if [ "$master_before" != true ]; then
  req -X PUT --data "$(jq -nc --arg r "$(irev)" --argjson h2 "$http2_before" \
      '{revision:$r, enabled:true, http2:$h2, http3:false}')" \
      "$API/5gpn/interception/settings" >/dev/null
fi
exec 9>"$CERT_LOCK"
chmod 0600 "$CERT_LOCK"
if flock -w 5 9; then
  ok "the certificate publisher is delayed for a deterministic pending check"
else
  bad "could not acquire the certificate publisher lock"
fi
res="$(req -X PUT --data "$(jq -nc --arg r "$(irev)" '{revision:$r, enabled:true}')" \
        "$API/5gpn/interception/extensions/${EXT}/enabled")"
enabled_revision="$(echo "$res" | jq -r '.revision')"
if [ "$(echo "$res" | jq -r --arg id "$EXT" '.snapshot.modules[]|select(.id==$id)|.enabled')" = "true" ]; then
  ok "the extension is authorized"
else
  bad "enable failed: $(echo "$res" | head -c 300)"
fi
if [ "$(echo "$res" | jq -r '.snapshot.certificate.status')" = pending ] \
   && [ "$(echo "$res" | jq -r --arg id "$EXT" '.snapshot.modules[]|select(.id==$id)|.runtime.phase')" = certificate_pending ]; then
  ok "authorization reports certificate-pending rather than active"
else
  bad "enable did not expose the pending certificate phase: $(echo "$res" | jq -c '.snapshot|{certificate,modules}')"
fi

if jq -e --arg host "$HOST" '.version == 1 and (.target_digest|test("^[0-9a-f]{64}$")) and (.attempt|test("^[0-9a-f]{32}$")) and (.hosts|index($host) != null)' "$REQUEST" >/dev/null; then
  ok "the engine published the host into the certificate request"
else
  bad "the certificate request does not contain a valid fenced target for $HOST"
fi
if [ "$(jq -r '.target_digest' "$REQUEST")" != "$digest_before" ]; then
  ok "the request digest moved, which is what triggers a reissue"
else
  bad "the request digest did not move"
fi
exp="$(req "$API/5gpn/dns/resolve?name=${HOST}")"
if [ "$(echo "$exp" | jq -r '.capture.extensionId')" = "$EXT" ]; then
  ok "the resolver attributes the name to the extension"
else
  bad "the resolver does not know about the capture: $(echo "$exp" | head -c 250)"
fi
gw="$(jq -r .gateway /etc/5gpn/mihomo/5gpn/dns.json)"
if echo "$exp" | jq -e --arg gw "$gw" \
    '.capture.ready == false and ([.answers[]?] | index($gw) != null) and .verdict.reason == "force-proxy"' >/dev/null; then
  ok "pending capture remains claimed at the gateway"
else
  bad "pending capture bypassed the fail-closed gateway claim"
fi
if curl -sk --noproxy '*' --connect-timeout 2 --max-time 3 \
    --resolve "${HOST}:443:${gw}" "https://${HOST}/" >/dev/null 2>&1; then
  bad "pending capture forwarded a TLS request before certificate commit"
else
  ok "pending capture rejects TCP/TLS before ordinary forwarding"
fi

# Release only the host lock. The path unit must finish the already-observed
# request; this test deliberately does not start it or issue a second API write.
flock -u 9
exec 9>&-
ready=""
for _ in $(seq 1 120); do
  current="$(req "$API/5gpn/interception")"
  if [ "$(echo "$current" | jq -r '.snapshot.certificate.status')" = ready ]; then
    ready="$current"
    break
  fi
  sleep 0.25
done
if [ -n "$ready" ]; then
  ok "the observed request automatically advanced from pending to ready"
else
  bad "the certificate did not become ready: $(journalctl -u 5gpn-intercept-cert.service -n 3 --no-pager | tail -1)"
fi
if [ -n "$ready" ] \
   && [ "$(echo "$ready" | jq -r '.revision')" = "$enabled_revision" ] \
   && [ "$(echo "$ready" | jq -r --arg id "$EXT" '.snapshot.modules[]|select(.id==$id)|.runtime.phase')" = active ]; then
  ok "readiness changed without a second document write or master toggle"
else
  bad "runtime readiness changed the document revision or missed the active phase"
fi

request_target="$(jq -r '.target_digest' "$REQUEST")"
request_attempt="$(jq -r '.attempt' "$REQUEST")"
certificate_hash="$(sha256sum /etc/5gpn/intercept/tls/fullchain.pem | cut -d' ' -f1)"
private_key_hash="$(sha256sum /etc/5gpn/intercept/tls/privkey.pem | cut -d' ' -f1)"
if jq -e --arg target "$request_target" --arg attempt "$request_attempt" \
    --arg cert "$certificate_hash" --arg key "$private_key_hash" \
    '.version == 1 and .status == "ready" and .target_digest == $target and .attempt == $attempt and .certificate_sha256 == $cert and .private_key_sha256 == $key' \
    "$RESULT" >/dev/null; then
  ok "the final commit record fences and hashes the exact TLS material"
else
  bad "the certificate result does not match the current request and material"
fi
if openssl x509 -in /etc/5gpn/intercept/tls/leaf.crt -noout -checkhost "$HOST" 2>/dev/null | grep -q 'does match'; then
  ok "the minted leaf covers $HOST"
else
  bad "the leaf does not cover $HOST"
fi

head_ "the resolver sees only ready capture"
exp="$(req "$API/5gpn/dns/resolve?name=${HOST}")"
if [ "$(echo "$exp" | jq -r '.capture.ready')" = "true" ] \
   && [ "$(echo "$exp" | jq -r '.answers[0]')" = "$gw" ] \
   && [ "$(echo "$exp" | jq -r '.verdict.reason')" = "force-proxy" ]; then
  ok "with the master on the name steers to the gateway as force-proxy"
else
  bad "the capture did not steer: $(echo "$exp" | jq -c '{ready:.capture.ready, answers, reason:.verdict.reason}')"
fi

head_ "clean up"
res="$(req -X DELETE --data "$(jq -nc --arg r "$(irev)" '{revision:$r}')" "$API/5gpn/interception/extensions/${EXT}")"
if echo "$res" | jq -e --arg id "$EXT" '[.snapshot.modules[]|select(.id==$id)]|length == 0' >/dev/null 2>&1; then
  ok "the extension is uninstalled"
else
  bad "uninstall failed: $(echo "$res" | head -c 250)"
fi
if [ "$(jq -r '.target_digest' "$REQUEST")" = "$digest_before" ]; then
  ok "the certificate request is back where it started"
else
  bad "the request did not return to its original digest"
fi
if [ "$master_before" != true ]; then
  req -X PUT --data "$(jq -nc --arg r "$(irev)" --argjson h2 "$http2_before" \
      '{revision:$r, enabled:false, http2:$h2, http3:false}')" \
      "$API/5gpn/interception/settings" >/dev/null
fi
if [ "$(req "$API/5gpn/interception" | jq -r '.snapshot.enabled')" = "$master_before" ]; then
  ok "the MITM master is restored to its initial state"
else
  bad "the master was not restored"
fi

echo
echo "======================================"
echo " $pass passed, $fail failed"
echo "======================================"
[ "$fail" -eq 0 ]
