#!/usr/bin/env bash
# Acceptance for the three surfaces that landed together: the HTTP/3 boundary,
# the extension catalog, and the Telegram control plane.
#
# Read-mostly. Its HTTP/3 write is deliberately rejected without changing the
# revision. The bot document write is restored, and the last check verifies the
# gateway is back where it started.
#
# A fresh gateway has no catalog source and performs no marketplace request. If
# the operator has explicitly configured one, the additional checks exercise
# that real source through the guarded client.
set -u

pass=0; fail=0
ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }
skip(){ echo "  --: $1"; }
head_() { echo; echo "== $1"; }

CONF=/etc/5gpn/mihomo/config.yaml
SECRET="$(grep -m1 -E "^secret:" "$CONF" | sed -E "s/^secret: *'?([^']*)'?.*/\1/")"
API="https://127.0.0.1:443"
REVIEW_CONTRACT=7
req() { curl -sk --max-time 120 -H "Authorization: Bearer ${SECRET}" -H 'Content-Type: application/json' "$@"; }
status() { curl -sk --max-time 120 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${SECRET}" -H 'Content-Type: application/json' "$@"; }

BOT_DOC=/etc/5gpn/mihomo/5gpn/bot.json
bot_restore_needed=false
bot_marker_token=""

cleanup_bot() {
  local current revision restored
  [ "$bot_restore_needed" = true ] || return 0
  current="$(req "$API/5gpn/bot" 2>/dev/null || true)"
  revision="$(echo "$current" | jq -r '.revision // ""' 2>/dev/null || true)"
  if [ -n "$revision" ] \
     && echo "$current" | jq -e '.bot | (
          .enabled == false and .alerts == false and .token_set == true and
          (.admins == [42] or .admins == [42,43])
        )' >/dev/null 2>&1 \
     && jq -e --arg token "$bot_marker_token" '.token == $token' "$BOT_DOC" >/dev/null 2>&1; then
    restored="$(req -X PUT --data "$(jq -nc --arg r "$revision" '{revision:$r, enabled:false, admins:[], alerts:false, token:"-"}')" "$API/5gpn/bot" 2>/dev/null || true)"
    if echo "$restored" | jq -e '.bot | (
        .state == "stopped" and .enabled == false and .token_set == false and
        .alerts == false and (.admins == [])
      )' >/dev/null 2>&1; then
      bot_restore_needed=false
      return 0
    fi
  fi
  return 1
}
trap 'cleanup_bot || true' EXIT
trap 'exit 130' HUP INT TERM

head_ "capabilities advertise what is installed"
caps="$(req "$API/capabilities")"
declare -A expected_feature_versions=(
  [5gpn-core]=1
  [5gpn-dns]=1
  [5gpn-interception]=7
  [5gpn-bot]=1
)
for feature in 5gpn-core 5gpn-dns 5gpn-interception 5gpn-bot; do
  expected="${expected_feature_versions[$feature]}"
  actual="$(echo "$caps" | jq -r --arg f "$feature" '.features[$f].version // 0')"
  if [ "$actual" = "$expected" ]; then
    ok "$feature advertises exact version $expected"
  else
    bad "$feature version is $actual, expected $expected: $(echo "$caps" | jq -c .features)"
  fi
done

head_ "plugin logs expose a restart-safe cursor envelope"
logs="$(req "$API/5gpn/interception/logs?limit=1")"
if echo "$logs" | jq -e '
  (.logs | type) == "array" and
  (.stream_id | type) == "string" and (.stream_id | test("^[0-9a-f]{32}$")) and
  (.oldest_seq | type) == "string" and (.oldest_seq | test("^(0|[1-9][0-9]*)$")) and
  (.latest_seq | type) == "string" and (.latest_seq | test("^(0|[1-9][0-9]*)$")) and
  (.dropped | type) == "string" and (.dropped | test("^(0|[1-9][0-9]*)$")) and
  (.reset | type) == "boolean" and
  (all(.logs[]; (.seq | type) == "string" and (.seq | test("^[1-9][0-9]*$"))))
' >/dev/null; then
  ok "plugin log cursor fields are canonical strings"
else
  bad "plugin log cursor envelope is invalid: $(echo "$logs" | jq -c . | head -c 300)"
fi

head_ "the seeded policy is a list, not null"
# Go marshals a nil slice as null, and every consumer that iterates it errors on
# that rather than seeing zero rules.
rules="$(req "$API/5gpn/dns" | jq -c '.document.policy.rules')"
if [ "$rules" != "null" ]; then
  ok "policy.rules is $rules"
else
  bad "policy.rules is null; jq iteration over it errors"
fi

head_ "HTTP/3 is explicitly unsupported"
snap="$(req "$API/5gpn/interception")"
rev="$(echo "$snap" | jq -r .revision)"
if echo "$snap" | jq -e 'has("snapshot") and (.snapshot.http3 == false)' >/dev/null; then
  ok "the snapshot reports http3=false"
else
  bad "the snapshot does not report http3=false: $(echo "$snap" | jq -c .snapshot | head -c 200)"
fi
if echo "$snap" | jq -e '.snapshot | has("quic_fallback_protection")' >/dev/null; then
  bad "the retired quic_fallback_protection field is still served"
else
  ok "the retired quic_fallback_protection field is gone"
fi

orig_http2="$(echo "$snap" | jq -r '.snapshot.http2')"
orig_master="$(echo "$snap" | jq -r '.snapshot.enabled')"
body="$(jq -nc --arg r "$rev" --argjson e "$orig_master" --argjson h2 "$orig_http2" \
         '{revision:$r, enabled:$e, http2:$h2, http3:true}')"
code="$(status -X PUT --data "$body" "$API/5gpn/interception/settings")"
if [ "$code" = "422" ]; then
  ok "PUT http3=true is refused with 422"
else
  bad "PUT http3=true returned $code, expected 422"
fi
after="$(req "$API/5gpn/interception")"
if [ "$(echo "$after" | jq -r '.revision')" = "$rev" ] \
   && [ "$(echo "$after" | jq -r '.snapshot.http3')" = "false" ]; then
  ok "the rejected write left the revision and http3 state unchanged"
else
  bad "the rejected write changed interception state: $(echo "$after" | head -c 200)"
fi

# The fixed guard appears exactly once, after all private-address denies and
# before the terminal policy. The QUIC sniffer still covers non-443 protocols
# such as :5060; this rule deliberately blocks only UDP/443.
guard='  - AND,((NETWORK,UDP),(DST-PORT,443)),REJECT'
guard_count="$(grep -cF "$guard" "$CONF" || true)"
private_line="$(grep -nF '  - IP-CIDR,169.254.0.0/16,REJECT,no-resolve' "$CONF" | cut -d: -f1 || true)"
guard_line="$(grep -nF "$guard" "$CONF" | cut -d: -f1 || true)"
match_line="$(grep -nF '  - MATCH,Proxies' "$CONF" | cut -d: -f1 || true)"
if [ "$guard_count" = "1" ] && [ -n "$private_line" ] && [ -n "$guard_line" ] \
   && [ -n "$match_line" ] && [ "$private_line" -lt "$guard_line" ] \
   && [ "$guard_line" -lt "$match_line" ]; then
  ok "the fixed UDP/443 guard appears once in the safe position"
else
  bad "the fixed UDP/443 guard is missing, duplicated, or out of position"
fi

rules="$(req "$API/rules")"
guard_api_count="$(echo "$rules" | jq -r '[.rules[] | select(.type == "AND" and .payload == "((Network,udp) && (DstPort,443))" and .proxy == "REJECT")] | length')"
if [ "$guard_api_count" = "1" ]; then
  ok "the running rule set carries exactly one fixed UDP/443 guard"
  guard_index="$(echo "$rules" | jq -r '.rules[] | select(.type == "AND" and .payload == "((Network,udp) && (DstPort,443))" and .proxy == "REJECT") | .index')"
  disable_body="$(jq -nc --arg i "$guard_index" '{($i):true}')"
  code="$(status -X PATCH --data "$disable_body" "$API/rules/disable")"
  if [ "$code" = "400" ]; then
    ok "PATCH /rules/disable cannot disable the fixed guard"
  else
    bad "PATCH /rules/disable returned $code for the fixed guard, expected 400"
  fi
  rules="$(req "$API/rules")"
  if echo "$rules" | jq -e --argjson i "$guard_index" \
       '.rules[] | select(.index == $i and .type == "AND" and .payload == "((Network,udp) && (DstPort,443))" and .proxy == "REJECT" and .extra.disabled == false)' >/dev/null; then
    ok "the rejected patch left the fixed guard enabled"
  else
    bad "the fixed guard was disabled or disappeared after the rejected patch"
  fi
else
  bad "the running rule set has $guard_api_count fixed UDP/443 guards"
fi

head_ "the extension catalog"
cat_res="$(req "$API/5gpn/interception/catalog")"
src_count="$(echo "$cat_res" | jq -r '.catalog.sources | length')"
if echo "$cat_res" | jq -e '.catalog.sources | type == "array"' >/dev/null; then
  ok "catalog sources are an array"
else
  bad "catalog sources are not an array: $(echo "$cat_res" | head -c 200)"
fi

src_id=""
src_err=""
entries=0
if [ "$src_count" = "0" ]; then
  ok "no implicit marketplace source is configured"
elif [ "$src_count" -ge 1 ]; then
  ok "$src_count catalog source(s) are configured"
  src_id="$(echo "$cat_res" | jq -r '.catalog.sources[0].id')"
  src_err="$(echo "$cat_res" | jq -r '.catalog.sources[0].error // ""')"
  entries="$(echo "$cat_res" | jq -r '.catalog.sources[0].entries | length')"
  if [ -n "$src_err" ]; then
    bad "$src_id could not be fetched: $src_err"
  elif [ "$entries" -ge 1 ]; then
    ok "$src_id lists $entries extensions"
  else
    bad "$src_id fetched but lists nothing"
  fi
else
  bad "catalog source count is invalid: $src_count"
fi

if [ "$entries" -ge 1 ]; then
  entry_id="$(echo "$cat_res" | jq -r '.catalog.sources[0].entries[0].id')"
  entry_ver="$(echo "$cat_res" | jq -r '.catalog.sources[0].entries[0].version')"
  entry_sha="$(echo "$cat_res" | jq -r '.catalog.sources[0].entries[0].manifest.sha256')"
  if [ "${#entry_sha}" = 64 ]; then
    ok "$entry_id $entry_ver publishes a manifest digest"
  else
    bad "$entry_id has no usable manifest digest"
  fi

  # The review is the whole install path minus the confirmation: it fetches the
  # manifest, checks it against the digest the catalog published and the shape
  # it advertised, and returns the digest an install must quote.
  rev_res="$(req -X POST --data '{}' "$API/5gpn/interception/catalog/$src_id/entries/$entry_id/review")"
  if [ "$(echo "$rev_res" | jq -r '.candidate.detail.id // ""')" = "$entry_id" ]; then
    ok "reviewing $entry_id through the catalog succeeds"
  else
    bad "catalog review failed: $(echo "$rev_res" | head -c 300)"
  fi
  if echo "$rev_res" | jq -e --argjson contract "$REVIEW_CONTRACT" '
      .candidate.detail.review_contract == $contract and
      (.candidate.detail | has("manifest") | not) and
      (.candidate.detail | has("content") | not) and
      ((.candidate.detail.actions // []) | type == "array") and
      all(.candidate.detail.actions[]?;
        (.id | type == "string" and length > 0) and
        (.phase | type == "string" and length > 0) and
        (.kind as $kind | ["script", "jq", "reject", "mock", "headers", "rewrite", "replace_body"] | index($kind) != null) and
        (.body_mode | type == "string") and
        (.review_digest | type == "string" and test("^[0-9a-f]{64}$")) and
        (.timeout_ms | type == "number") and
        (.max_body_bytes | type == "number") and
        (has("script") | not) and (has("inline") | not) and
        (has("script_body") | not) and (has("jq") | not) and
        (has("jq_program") | not) and (has("program") | not) and
        (has("code") | not) and (has("source") | not) and
        (has("content") | not) and (has("body") | not) and
        (has("base64_body") | not) and
        (if .kind == "mock" then
          (.mock.body | type == "object") and
          (.mock.body.kind | type == "string") and
          (.mock.body.bytes | type == "number") and
          (.mock.body.sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
          (.mock.body | has("text") | not) and
          (.mock.body | has("value") | not) and
          (.mock.body | has("base64") | not)
        else true end)
      )
    ' >/dev/null; then
    ok "the catalog review uses contract $REVIEW_CONTRACT and bounded body-free action records"
  else
    bad "the catalog review detail is not a contract-$REVIEW_CONTRACT action review"
  fi
  if [ -n "$(echo "$rev_res" | jq -r '.candidate.digest // ""')" ]; then
    ok "the review returns a digest for the install to quote"
  else
    bad "the review returned no digest"
  fi
  if [ "$(echo "$rev_res" | jq -r '.url // ""')" != "" ]; then
    ok "the review names the manifest URL the install must use"
  else
    bad "the review did not return the source URL"
  fi

  # Nothing was installed by reviewing.
  if [ "$(req "$API/5gpn/interception" | jq -r --arg i "$entry_id" '[.snapshot.modules[] | select(.id==$i)] | length')" = "0" ]; then
    ok "reviewing installed nothing"
  else
    skip "$entry_id was already installed before this run"
  fi
else
  skip "catalog entry checks (nothing listed)"
fi

# An unknown source or entry is a 404, not a 500.
code="$(status -X POST --data '{}' "$API/5gpn/interception/catalog/no.such.catalog/entries/x/review")"
if [ "$code" = "404" ]; then ok "an unknown catalog is a 404"; else bad "an unknown catalog returned $code"; fi
if [ "$entries" -ge 1 ]; then
  code="$(status -X POST --data '{}' "$API/5gpn/interception/catalog/$src_id/entries/no.such.entry/review")"
  if [ "$code" = "404" ]; then ok "an unknown entry is a 404"; else bad "an unknown entry returned $code"; fi
fi

head_ "the Telegram control plane"
bot="$(req "$API/5gpn/bot")"
bot_rev="$(echo "$bot" | jq -r .revision)"
if echo "$bot" | jq -e '.bot | has("token_set")' >/dev/null; then
  ok "the bot view reports whether a token is set"
else
  bad "the bot view is missing: $(echo "$bot" | head -c 200)"
fi
if echo "$bot" | jq -e '.bot | has("token")' >/dev/null; then
  bad "the bot view carries the token"
else
  ok "the bot view never carries the token"
fi
bot_pristine="$(echo "$bot" | jq -r '.bot | (
  .state == "stopped" and .enabled == false and .token_set == false and
  .alerts == false and ((.admins | type) == "array" and (.admins | length) == 0)
)')"
if [ "$bot_pristine" = "true" ]; then
  ok "an unconfigured bot is stopped"
  bot_marker_token="999999999:acceptance_$(openssl rand -hex 12)"

  # An enabled bot with no token, or no admins, answers nobody. Both are
  # refused rather than stored. These mutations are safe only for the exact
  # fresh-default document: the API deliberately never returns an existing
  # token, so a configured deployment cannot be restored after replacing it.
  code="$(status -X PUT --data "$(jq -nc --arg r "$bot_rev" '{revision:$r, enabled:true, admins:[42], alerts:false}')" "$API/5gpn/bot")"
  if [ "$code" = "422" ]; then ok "enabling without a token is refused"; else bad "enabling without a token returned $code"; fi
  code="$(status -X PUT --data "$(jq -nc --arg r "$bot_rev" '{revision:$r, enabled:true, admins:[], alerts:false, token:"123:fake"}')" "$API/5gpn/bot")"
  if [ "$code" = "422" ]; then ok "enabling without an admin is refused"; else bad "enabling without an admin returned $code"; fi

  # A disabled write with a token stores it without starting anything, which
  # lets an operator stage the configuration before turning it on.
  bot_mutation_owned=false
  bot_restore_needed=true
  res="$(req -X PUT --data "$(jq -nc --arg r "$bot_rev" --arg token "$bot_marker_token" '{revision:$r, enabled:false, admins:[42], alerts:false, token:$token}')" "$API/5gpn/bot")"
  if echo "$res" | jq -e '.bot | (
      .enabled == false and .alerts == false and .token_set == true and .admins == [42]
    )' >/dev/null 2>&1 \
     && jq -e --arg token "$bot_marker_token" '.token == $token' "$BOT_DOC" >/dev/null 2>&1; then
    bot_mutation_owned=true
    ok "a token can be staged without enabling the bot"
  else
    bad "staging a token failed: $(echo "$res" | head -c 200)"
    cleanup_bot || true
  fi
  if [ "$bot_mutation_owned" = true ]; then
    bot_rev="$(echo "$res" | jq -r .revision)"

    # Editing the admin list without resending the token must keep it.
    res="$(req -X PUT --data "$(jq -nc --arg r "$bot_rev" '{revision:$r, enabled:false, admins:[42,43], alerts:false}')" "$API/5gpn/bot")"
    if echo "$res" | jq -e '.bot | (
        .enabled == false and .alerts == false and .token_set == true and .admins == [42,43]
      )' >/dev/null 2>&1 \
       && jq -e --arg token "$bot_marker_token" '.token == $token' "$BOT_DOC" >/dev/null 2>&1; then
      ok "editing the admin list keeps the stored token"
      bot_rev="$(echo "$res" | jq -r .revision)"
    else
      bad "editing the admin list lost ownership of the test document: $(echo "$res" | head -c 200)"
      bot_mutation_owned=false
      cleanup_bot || true
    fi
  fi

  if [ "$bot_mutation_owned" = true ]; then
    code="$(status -X PUT --data "$(jq -nc '{revision:"stale", enabled:false, admins:[42], alerts:false}')" "$API/5gpn/bot")"
    if [ "$code" = "409" ]; then ok "a stale bot revision is refused with 409"; else bad "a stale bot write returned $code"; fi

    # Restore only while the marker token and test-owned shape still match.
    if cleanup_bot; then
      res="$(req "$API/5gpn/bot")"
      if echo "$res" | jq -e '.bot | (
          .state == "stopped" and .enabled == false and .token_set == false and
          .alerts == false and (.admins == [])
        )' >/dev/null; then
        ok "the token was cleared and the gateway is back where it started"
      else
        bad "the fresh bot document was not restored exactly: $(echo "$res" | head -c 200)"
      fi
    else
      bad "the bot test lost ownership before restore; refusing to overwrite concurrent state"
    fi
  fi
else
  skip "bot write checks (the deployment already has bot state that the write-only token API cannot restore)"
fi

head_ "the bot document is on disk and private"
if [ -f "$BOT_DOC" ]; then
  ok "$BOT_DOC exists"
  mode="$(stat -c '%a' "$BOT_DOC")"
  if [ "$mode" = "600" ]; then ok "$BOT_DOC is 0600"; else bad "$BOT_DOC is $mode"; fi
  if [ "$bot_pristine" = "true" ]; then
    if jq -e '
      .version == 1 and .enabled == false and .token == "" and
      .alerts == false and ((.admins | type) == "array" and (.admins | length) == 0)
    ' "$BOT_DOC" >/dev/null; then
      ok "the private document returned to the exact fresh-default shape"
    else
      bad "the private document did not return to its fresh-default shape"
    fi
  elif jq -e 'has("token") and (.token | type == "string")' "$BOT_DOC" >/dev/null; then
    ok "the private document retains the current token field without exposing it through the API"
  else
    bad "the private document has an invalid token field"
  fi
else
  bad "$BOT_DOC was not created"
fi

echo
echo "======================================"
echo " $pass passed, $fail failed"
echo "======================================"
[ "$fail" -eq 0 ]
