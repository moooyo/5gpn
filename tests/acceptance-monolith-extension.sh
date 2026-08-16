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
REVIEW_CONTRACT=7
REVIEW_CONTRACT_ERROR="review_contract must be ${REVIEW_CONTRACT}; reload the current state and review the action again"
REQUEST=/etc/5gpn/mihomo/5gpn/certificate-request
RESULT=/etc/5gpn/intercept/cert-state
CERT_LOCK=/run/5gpn/cert-renew.lock
RUN_ID="$(openssl rand -hex 6)"
HOST="smoke-${RUN_ID}.5gpn-beta.example"
EXT="beta.smoke.${RUN_ID}"

req() { curl -sk --max-time 60 -H "Authorization: Bearer ${SECRET}" -H 'Content-Type: application/json' "$@"; }
response() { curl -sk --max-time 60 -w $'\n%{http_code}' -H "Authorization: Bearer ${SECRET}" -H 'Content-Type: application/json' "$@"; }
irev() { req "$API/5gpn/interception" | jq -r .revision; }

installed_by_acceptance=false
install_attempted=false
candidate_digest=""
master_restore_needed=false
lock_open=false
master_before=false
http2_before=true

cleanup() {
  local current revision detail
  if [ "$lock_open" = true ]; then
    flock -u 9 >/dev/null 2>&1 || true
    exec 9>&-
    lock_open=false
  fi
  if [ "$install_attempted" = true ]; then
    current="$(req "$API/5gpn/interception" 2>/dev/null || true)"
    revision="$(echo "$current" | jq -r '.revision // ""' 2>/dev/null || true)"
    detail="$(req "$API/5gpn/interception/extensions/${EXT}" 2>/dev/null || true)"
    if [ -n "$revision" ] \
       && [ "$(echo "$detail" | jq -r '.extension.snapshot_digest // ""' 2>/dev/null || true)" = "$candidate_digest" ]; then
      req -X DELETE --data "$(jq -nc --arg r "$revision" '{revision:$r}')" "$API/5gpn/interception/extensions/${EXT}" >/dev/null 2>&1 || true
    elif echo "$current" | jq -e --arg id "$EXT" '.snapshot.modules[]? | select(.id == $id)' >/dev/null 2>&1; then
      echo "WARNING: refusing to delete $EXT because its installed snapshot no longer matches this acceptance run" >&2
    fi
  fi
  if [ "$master_restore_needed" = true ]; then
    current="$(req "$API/5gpn/interception" 2>/dev/null || true)"
    revision="$(echo "$current" | jq -r '.revision // ""' 2>/dev/null || true)"
    if [ -n "$revision" ] \
       && [ "$(echo "$current" | jq -r '.snapshot.enabled' 2>/dev/null || true)" = true ] \
       && [ "$(echo "$current" | jq -r '.snapshot.http2' 2>/dev/null || true)" = "$http2_before" ] \
       && [ "$(echo "$current" | jq -r '.snapshot.modules | length' 2>/dev/null || true)" = 0 ]; then
      req -X PUT --data "$(jq -nc --arg r "$revision" --argjson enabled "$master_before" --argjson h2 "$http2_before" '{revision:$r, enabled:$enabled, http2:$h2, http3:false}')" "$API/5gpn/interception/settings" >/dev/null 2>&1 || true
    fi
  fi
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

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
  - id: memory-bomb
    phase: request
    match:
      hosts: [${HOST}]
      pathRegex: "^/oom$"
    script:
      inline: |
        function transform() {
          const blocks = [];
          while (true) blocks.push(new Uint8Array(16 * 1024 * 1024));
        }
      bodyMode: none
      timeoutMs: 30000
      maxBodyBytes: 1024
  - id: healthy
    phase: request
    match:
      hosts: [${HOST}]
      pathRegex: "^/healthy$"
    script:
      inline: "function transform() { return {response: {status: 204, headers: {}}}; }"
      bodyMode: none
      timeoutMs: 1000
      maxBodyBytes: 1024
YAML
)"

initial="$(req "$API/5gpn/interception")"
master_before="$(echo "$initial" | jq -r '.snapshot.enabled')"
http2_before="$(echo "$initial" | jq -r '.snapshot.http2')"
module_count="$(echo "$initial" | jq -r '.snapshot.modules | length')"
if [ "$module_count" != "0" ]; then
  echo "SKIP: extension lifecycle mutation requires an empty installed-extension set; found $module_count"
  exit 0
fi
digest_before="$(jq -r '.target_digest' "$REQUEST")"
[[ "$digest_before" =~ ^[0-9a-f]{64}$ ]] \
  || { bad "the initial certificate request is not JSON v1"; echo "$pass passed, $fail failed"; exit 1; }

head_ "review"
body="$(jq -nc --arg c "$MANIFEST" '{content:$c}')"
review="$(req -X POST --data "$body" "$API/5gpn/interception/review")"
cand="$(echo "$review" | jq -r '.candidate.digest // ""')"
candidate_digest="$cand"
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
if [ "$(echo "$review" | jq -r '.candidate.detail.review_contract // 0')" = "$REVIEW_CONTRACT" ]; then
  ok "the review detail uses contract $REVIEW_CONTRACT"
else
  bad "the review detail does not use contract $REVIEW_CONTRACT"
fi
if echo "$review" | jq -e --arg host "$HOST" '
    (.candidate.detail.actions | sort_by(.id)) as $actions |
    (.candidate.detail | has("manifest") | not) and
    (.candidate.detail | has("content") | not) and
    ($actions | length) == 2 and
    all($actions[];
      .phase == "request" and .hosts == [$host] and .kind == "script" and
      .body_mode == "none" and .entry == "native" and .source_kind == "inline" and
      (.code_digest | test("^[0-9a-f]{64}$")) and (.code_bytes > 0) and
      (.review_digest | test("^[0-9a-f]{64}$")) and
      .max_body_bytes == 1024 and
      (has("script") | not) and (has("inline") | not) and
      (has("script_body") | not) and (has("jq") | not) and
      (has("jq_program") | not) and (has("program") | not) and
      (has("code") | not) and (has("source") | not) and
      (has("content") | not) and (has("body") | not) and
      (has("base64_body") | not)
    ) and
    ($actions[0].id == "healthy" and $actions[0].path == "^/healthy$" and $actions[0].timeout_ms == 1000) and
    ($actions[1].id == "memory-bomb" and $actions[1].path == "^/oom$" and $actions[1].timeout_ms == 30000)
  ' >/dev/null 2>&1; then
  ok "the review exposes structured action metadata and per-action review digests"
else
  bad "the review action records are incomplete or unstructured"
fi
if echo "$review" | grep -Eq 'function transform|apiVersion: 5gpn\.io/v1'; then
  bad "the review leaked executable action bodies or manifest text"
else
  ok "the review action records contain no executable bodies or manifest text"
fi
if [ "$(echo "$review" | jq -r '.candidate.installed // "none"')" = "none" ]; then
  ok "the review reports nothing installed under this id yet"
else
  bad "the review claims something is already installed"
fi

head_ "install"
# A digest that does not match what a fresh fetch produces must be refused --
# that check is the whole reason the digest exists.
wrong_before="$(irev)"
wrong="$(jq -nc --arg r "$wrong_before" --arg c "$MANIFEST" --argjson review_contract "$REVIEW_CONTRACT" \
  '{revision:$r, review_contract:$review_contract, digest:"0000000000000000", content:$c}')"
wrong_response="$(response -X POST --data "$wrong" "$API/5gpn/interception/extensions")"
wrong_code="${wrong_response##*$'\n'}"
wrong_body="${wrong_response%$'\n'*}"
wrong_after="$(irev)"
if [ "$wrong_code" = 409 ] \
   && [ "$(echo "$wrong_body" | jq -r '.code // ""' 2>/dev/null || true)" = review_conflict ] \
   && [ "$wrong_after" = "$wrong_before" ] \
   && ! req "$API/5gpn/interception" | jq -e --arg id "$EXT" '.snapshot.modules[]? | select(.id == $id)' >/dev/null 2>&1; then
  ok "an install quoting the wrong digest is refused as a review conflict without changing state"
else
  bad "wrong digest returned $wrong_code, changed revision, installed the extension, or lacked review_conflict"
fi

body="$(jq -nc --arg r "$(irev)" --arg d "$cand" --arg c "$MANIFEST" \
  --argjson review_contract "$REVIEW_CONTRACT" \
  '{revision:$r, review_contract:$review_contract, digest:$d, content:$c}')"
install_attempted=true
res="$(req -X POST --data "$body" "$API/5gpn/interception/extensions")"
installed_detail="$(req "$API/5gpn/interception/extensions/${EXT}" 2>/dev/null || true)"
if [ "$(echo "$installed_detail" | jq -r '.extension.snapshot_digest // ""' 2>/dev/null || true)" = "$candidate_digest" ]; then
  installed_by_acceptance=true
  ok "the extension is installed"
else
  bad "install did not publish the reviewed snapshot: $(echo "$res" | head -c 300)"
  exit 1
fi
if [ "$(echo "$installed_detail" | jq -r '.extension.enabled')" = "false" ]; then
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
  # Set the cleanup intent before the request: a committed write with a lost
  # response must still be restored by the EXIT trap.
  master_restore_needed=true
  master_res="$(req -X PUT --data "$(jq -nc --arg r "$(irev)" --argjson h2 "$http2_before" \
      '{revision:$r, enabled:true, http2:$h2, http3:false}')" \
      "$API/5gpn/interception/settings")"
  master_live="$(req "$API/5gpn/interception")"
  if [ "$(echo "$master_res" | jq -r '.snapshot.enabled // false')" != true ] \
     || [ "$(echo "$master_live" | jq -r '.snapshot.enabled // false')" != true ] \
     || [ "$(echo "$master_live" | jq -r '.snapshot.http2')" != "$http2_before" ]; then
    bad "the MITM master could not be enabled safely"
    exit 1
  fi
fi
exec 9>"$CERT_LOCK"
lock_open=true
chmod 0600 "$CERT_LOCK"
if flock -w 5 9; then
  ok "the certificate publisher is delayed for a deterministic pending check"
else
  bad "could not acquire the certificate publisher lock"
  exit 1
fi
res="$(req -X PUT --data "$(jq -nc --arg r "$(irev)" --argjson review_contract "$REVIEW_CONTRACT" \
          '{revision:$r, review_contract:$review_contract, enabled:true}')" \
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
lock_open=false
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

head_ "a worker OOM stays inside the owned action"
# Re-prove ownership immediately before intentionally exhausting a worker. The
# random ID, immutable digest, and empty-start contract ensure this request can
# execute only code installed by this acceptance run.
owned_detail="$(req "$API/5gpn/interception/extensions/${EXT}" 2>/dev/null || true)"
if [ "$installed_by_acceptance" != true ] \
   || [ "$(echo "$owned_detail" | jq -r '.extension.snapshot_digest // ""' 2>/dev/null || true)" != "$candidate_digest" ] \
   || [ "$(echo "$owned_detail" | jq -r '.extension.enabled // false' 2>/dev/null || true)" != true ]; then
  bad "refusing the OOM fixture because the owned extension fence changed"
  exit 1
fi
main_pid="$(systemctl show 5gpn-mihomo.service -p MainPID --value 2>/dev/null || true)"
if ! [[ "$main_pid" =~ ^[1-9][0-9]*$ ]]; then
  bad "the monolith has no live MainPID before the OOM fixture"
  exit 1
fi
cgroup_root="/proc/${main_pid}/root/sys/fs/cgroup"
root_procs="$(tr -d '[:space:]' < "$cgroup_root/cgroup.procs" 2>/dev/null || true)"
main_procs="$(awk 'NF { print }' "$cgroup_root/main/cgroup.procs" 2>/dev/null || true)"
if [ -z "$root_procs" ] && [ "$main_procs" = "$main_pid" ] \
   && grep -qw memory "$cgroup_root/cgroup.subtree_control" 2>/dev/null \
   && grep -qw pids "$cgroup_root/cgroup.subtree_control" 2>/dev/null; then
  ok "the trusted parent normalized the private delegated root before listeners"
else
  bad "the private delegated root/main layout is not normalized"
  exit 1
fi
mapfile -t aggregate_paths < <(find "$cgroup_root" -mindepth 1 -maxdepth 1 -type d \
  -name "workers.${main_pid}.*" -print 2>/dev/null | LC_ALL=C sort)
if [ "${#aggregate_paths[@]}" -ne 1 ] \
   || ! [[ "$(basename -- "${aggregate_paths[0]:-}")" =~ ^workers\.${main_pid}\.[0-9a-f]{32}$ ]]; then
  bad "the private worker aggregate cgroup is missing or ambiguous"
  exit 1
fi
aggregate_path="${aggregate_paths[0]}"
if [ "$(tr -d '[:space:]' < "$aggregate_path/memory.max" 2>/dev/null || true)" = 1073741824 ] \
   && [ "$(tr -d '[:space:]' < "$aggregate_path/memory.swap.max" 2>/dev/null || true)" = 0 ] \
   && [ "$(tr -d '[:space:]' < "$aggregate_path/pids.max" 2>/dev/null || true)" = 64 ]; then
  ok "the production worker aggregate enforces the fixed 1GiB/64-task budget"
else
  bad "the worker aggregate resource limits differ from the fixed contract"
  exit 1
fi
oom_kill_count() {
  awk '$1 == "oom_kill" && $2 ~ /^[0-9]+$/ { value=$2; found=1 } END { if (!found) exit 1; print value }' "$1"
}
oom_before="$(oom_kill_count "$aggregate_path/memory.events" 2>/dev/null || true)"
if ! [[ "$oom_before" =~ ^[0-9]+$ ]]; then
  bad "the worker aggregate exposes no valid hierarchical oom_kill counter"
  exit 1
fi
if [ -n "$(find "$aggregate_path" -mindepth 1 -maxdepth 1 -type d -name 'action.*' -print -quit 2>/dev/null)" ]; then
  bad "an action leaf existed before the isolated OOM request"
  exit 1
fi
oom_http="$(curl -sk --noproxy '*' --connect-timeout 3 --max-time 40 \
  --resolve "${HOST}:443:${gw}" -o /dev/null -w '%{http_code}' \
  "https://${HOST}/oom" 2>/dev/null || true)"
oom_after="$oom_before"
for _ in $(seq 1 100); do
  oom_after="$(oom_kill_count "$aggregate_path/memory.events" 2>/dev/null || true)"
  if [[ "$oom_after" =~ ^[0-9]+$ ]] && [ "$oom_after" -gt "$oom_before" ]; then
    break
  fi
  sleep 0.1
done
if [[ "$oom_after" =~ ^[0-9]+$ ]] && [ "$oom_after" -gt "$oom_before" ]; then
  ok "the owned /oom action incremented aggregate oom_kill (${oom_before} -> ${oom_after}; HTTP ${oom_http:-none})"
else
  bad "the /oom action did not produce a cgroup OOM kill (HTTP ${oom_http:-none})"
fi
after_pid="$(systemctl show 5gpn-mihomo.service -p MainPID --value 2>/dev/null || true)"
if [ "$after_pid" = "$main_pid" ] && systemctl is-active --quiet 5gpn-mihomo.service; then
  ok "the monolith remained active with the same MainPID after worker OOM"
else
  bad "the worker OOM restarted or stopped the monolith (before=$main_pid after=${after_pid:-none})"
fi
leaf_left=""
for _ in $(seq 1 100); do
  leaf_left="$(find "$aggregate_path" -mindepth 1 -maxdepth 1 -type d -name 'action.*' -print -quit 2>/dev/null)"
  [ -n "$leaf_left" ] || break
  sleep 0.1
done
if [ -z "$leaf_left" ]; then
  ok "the OOM action leaf was removed"
else
  bad "the OOM action leaf remains: $leaf_left"
fi
healthy_http="$(curl -sk --noproxy '*' --connect-timeout 3 --max-time 10 \
  --resolve "${HOST}:443:${gw}" -o /dev/null -w '%{http_code}' \
  "https://${HOST}/healthy" 2>/dev/null || true)"
if [ "$healthy_http" = 204 ] \
   && [ "$(systemctl show 5gpn-mihomo.service -p MainPID --value 2>/dev/null || true)" = "$main_pid" ] \
   && systemctl is-active --quiet 5gpn-mihomo.service; then
  ok "the next isolated /healthy action returned 204 without restarting mihomo"
else
  bad "the healthy action after OOM returned ${healthy_http:-no response}"
fi
if [ -z "$(find "$aggregate_path" -mindepth 1 -maxdepth 1 -type d -name 'action.*' -print -quit 2>/dev/null)" ]; then
  ok "the healthy action leaf was also removed"
else
  bad "an action cgroup remained after the healthy response"
fi

head_ "clean up"
owned_detail="$(req "$API/5gpn/interception/extensions/${EXT}" 2>/dev/null || true)"
if [ "$(echo "$owned_detail" | jq -r '.extension.snapshot_digest // ""' 2>/dev/null || true)" != "$candidate_digest" ]; then
  bad "the test extension changed before cleanup; refusing to delete it"
  exit 1
fi
disabled="$(req -X PUT --data "$(jq -nc --arg r "$(echo "$owned_detail" | jq -r .revision)" \
  '{revision:$r, enabled:false}')" "$API/5gpn/interception/extensions/${EXT}/enabled")"
if [ "$(echo "$disabled" | jq -r --arg id "$EXT" '.snapshot.modules[] | select(.id == $id) | .enabled')" = false ]; then
  ok "disable accepts an omitted review_contract"
else
  bad "disable without review_contract failed: $(echo "$disabled" | head -c 250)"
fi
for contract in 0 null; do
  before_disable_escape="$(irev)"
  if [ "$contract" = null ]; then
    disable_escape="$(jq -nc --arg r "$before_disable_escape" '{revision:$r, review_contract:null, enabled:false}')"
  else
    disable_escape="$(jq -nc --arg r "$before_disable_escape" '{revision:$r, review_contract:0, enabled:false}')"
  fi
  escape_response="$(response -X PUT --data "$disable_escape" \
    "$API/5gpn/interception/extensions/${EXT}/enabled")"
  escape_code="${escape_response##*$'\n'}"
  escape_body="${escape_response%$'\n'*}"
  escape_response_revision="$(echo "$escape_body" | jq -r '.revision // ""' 2>/dev/null || true)"
  escape_after="$(irev)"
  escape_enabled="$(echo "$escape_body" | jq -r --arg id "$EXT" '.snapshot.modules[] | select(.id == $id) | .enabled' 2>/dev/null || true)"
  escape_live_enabled="$(req "$API/5gpn/interception/extensions/${EXT}" | jq -r '.extension.enabled' 2>/dev/null || true)"
  if [ "$escape_code" = 200 ] && [ "$escape_enabled" = false ] \
     && [ "$escape_live_enabled" = false ] && [ "$escape_after" = "$escape_response_revision" ]; then
    ok "disable treats review_contract $contract as omitted and keeps the extension disabled"
  else
    bad "disable with review_contract $contract returned $escape_code or response/live state diverged"
  fi
done
for contract in 6 8; do
  before_disable_reject="$(irev)"
  reject_response="$(response -X PUT --data "$(jq -nc --arg r "$before_disable_reject" --argjson review_contract "$contract" \
    '{revision:$r, review_contract:$review_contract, enabled:false}')" \
    "$API/5gpn/interception/extensions/${EXT}/enabled")"
  code="${reject_response##*$'\n'}"
  reject_body="${reject_response%$'\n'*}"
  message="$(echo "$reject_body" | jq -r '.message // ""' 2>/dev/null || true)"
  after_disable_reject="$(irev)"
  still_disabled="$(req "$API/5gpn/interception/extensions/${EXT}" | jq -r '.extension.enabled' 2>/dev/null || true)"
  if [ "$code" = 400 ] && [ "$message" = "$REVIEW_CONTRACT_ERROR" ] \
     && [ "$after_disable_reject" = "$before_disable_reject" ] && [ "$still_disabled" = false ]; then
    ok "disable rejects explicit review_contract $contract for the contract reason without changing state"
  else
    bad "disable with review_contract $contract returned $code/message '$message' or changed state"
  fi
done
owned_detail="$(req "$API/5gpn/interception/extensions/${EXT}" 2>/dev/null || true)"
res="$(req -X DELETE --data "$(jq -nc --arg r "$(echo "$owned_detail" | jq -r .revision)" '{revision:$r}')" "$API/5gpn/interception/extensions/${EXT}")"
if echo "$res" | jq -e --arg id "$EXT" '[.snapshot.modules[]|select(.id==$id)]|length == 0' >/dev/null 2>&1; then
  installed_by_acceptance=false
  install_attempted=false
  ok "the extension is uninstalled"
else
  bad "uninstall failed: $(echo "$res" | head -c 250)"
fi
if [ "$(jq -r '.target_digest' "$REQUEST")" = "$digest_before" ]; then
  ok "the certificate request is back where it started"
else
  bad "the request did not return to its original digest"
fi
certificate_restored=false
for _ in $(seq 1 120); do
  request_target="$(jq -r '.target_digest // ""' "$REQUEST" 2>/dev/null || true)"
  request_attempt="$(jq -r '.attempt // ""' "$REQUEST" 2>/dev/null || true)"
  if [ "$request_target" = "$digest_before" ] \
     && jq -e --arg target "$request_target" --arg attempt "$request_attempt" '
       .status == "ready" and .target_digest == $target and .attempt == $attempt
     ' "$RESULT" >/dev/null 2>&1; then
    certificate_restored=true
    break
  fi
  sleep 0.25
done
if [ "$certificate_restored" = true ]; then
  ok "the certificate publisher finished the restored target"
else
  bad "the restored certificate target did not reach ready"
fi
if [ "$master_before" != true ]; then
  before_restore="$(req "$API/5gpn/interception")"
  if [ "$(echo "$before_restore" | jq -r '.snapshot.enabled')" = true ] \
     && [ "$(echo "$before_restore" | jq -r '.snapshot.http2')" = "$http2_before" ] \
     && [ "$(echo "$before_restore" | jq -r '.snapshot.modules | length')" = 0 ]; then
    req -X PUT --data "$(jq -nc --arg r "$(echo "$before_restore" | jq -r .revision)" --argjson enabled "$master_before" --argjson h2 "$http2_before" \
        '{revision:$r, enabled:$enabled, http2:$h2, http3:false}')" \
        "$API/5gpn/interception/settings" >/dev/null
  else
    bad "interception state changed concurrently; refusing to overwrite it during restore"
  fi
fi
restored="$(req "$API/5gpn/interception")"
if [ "$(echo "$restored" | jq -r '.snapshot.enabled')" = "$master_before" ] \
   && [ "$(echo "$restored" | jq -r '.snapshot.http2')" = "$http2_before" ]; then
  master_restore_needed=false
  ok "the interception settings are restored to their initial state"
else
  bad "the interception settings were not restored"
fi

echo
echo "======================================"
echo " $pass passed, $fail failed"
echo "======================================"
[ "$fail" -eq 0 ]
