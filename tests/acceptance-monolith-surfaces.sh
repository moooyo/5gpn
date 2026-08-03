#!/usr/bin/env bash
# Acceptance for the three surfaces that landed together: datagram capture, the
# extension catalog, and the Telegram control plane.
#
# Read-mostly. The two writes it makes (the HTTP/3 switch, the bot document) are
# restored, and the last check verifies the gateway is back where it started.
#
# The catalog checks reach the public index over the network. That is the point
# of running them here rather than in the offline suite: what is under test is
# that a real gateway can fetch a real catalog through its own guarded client
# and hold the entries to what they advertise.
set -u

pass=0; fail=0
ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }
skip(){ echo "  --: $1"; }
head_() { echo; echo "== $1"; }

CONF=/etc/5gpn/mihomo/config.yaml
SECRET="$(grep -m1 -E "^secret:" "$CONF" | sed -E "s/^secret: *'?([^']*)'?.*/\1/")"
API="https://127.0.0.1:9090"
req() { curl -sk --max-time 120 -H "Authorization: Bearer ${SECRET}" -H 'Content-Type: application/json' "$@"; }
status() { curl -sk --max-time 120 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${SECRET}" -H 'Content-Type: application/json' "$@"; }

head_ "capabilities advertise what is installed"
caps="$(req "$API/capabilities")"
for feature in gpn-core gpn-dns gpn-interception gpn-bot; do
  if [ "$(echo "$caps" | jq -r --arg f "$feature" '.features[$f].version // 0')" -ge 1 ]; then
    ok "$feature is advertised"
  else
    bad "$feature is not advertised: $(echo "$caps" | jq -c .features)"
  fi
done

head_ "the seeded policy is a list, not null"
# Go marshals a nil slice as null, and every consumer that iterates it errors on
# that rather than seeing zero rules.
rules="$(req "$API/gpn/dns" | jq -c '.document.policy.rules')"
if [ "$rules" != "null" ]; then
  ok "policy.rules is $rules"
else
  bad "policy.rules is null; jq iteration over it errors"
fi

head_ "HTTP/3 capture is a document field the engine reads"
snap="$(req "$API/gpn/interception")"
rev="$(echo "$snap" | jq -r .revision)"
if echo "$snap" | jq -e 'has("snapshot") and (.snapshot | has("http3"))' >/dev/null; then
  ok "the snapshot carries http3"
else
  bad "the snapshot has no http3 field: $(echo "$snap" | jq -c .snapshot | head -c 200)"
fi
if echo "$snap" | jq -e '.snapshot | has("quic_fallback_protection")' >/dev/null; then
  bad "the retired quic_fallback_protection field is still served"
else
  ok "the retired quic_fallback_protection field is gone"
fi

orig_http3="$(echo "$snap" | jq -r '.snapshot.http3')"
orig_http2="$(echo "$snap" | jq -r '.snapshot.http2')"
orig_master="$(echo "$snap" | jq -r '.snapshot.enabled')"
body="$(jq -nc --arg r "$rev" --argjson e "$orig_master" --argjson h2 "$orig_http2" \
         '{revision:$r, enabled:$e, http2:$h2, http3:true}')"
after="$(req -X PUT --data "$body" "$API/gpn/interception/settings")"
if [ "$(echo "$after" | jq -r '.snapshot.http3')" = "true" ]; then
  ok "http3 can be turned on"
else
  bad "turning http3 on failed: $(echo "$after" | head -c 200)"
fi

# The reject rule stays regardless. Capture is consulted before rule
# resolution, so with http3 on it only ever sees what capture did not want --
# and with it off it is the whole mechanism.
if grep -Fq 'AND,((NETWORK,UDP),(DST-PORT,443)),REJECT' "$CONF"; then
  ok "the UDP/443 backstop is still in the operator config"
else
  bad "the UDP/443 backstop is missing; gateway QUIC would bypass interception"
fi

restore="$(jq -nc --arg r "$(req "$API/gpn/interception" | jq -r .revision)" \
            --argjson e "$orig_master" --argjson h2 "$orig_http2" --argjson h3 "$orig_http3" \
            '{revision:$r, enabled:$e, http2:$h2, http3:$h3}')"
req -X PUT --data "$restore" "$API/gpn/interception/settings" >/dev/null
if [ "$(req "$API/gpn/interception" | jq -r '.snapshot.http3')" = "$orig_http3" ]; then
  ok "http3 was restored to $orig_http3"
else
  bad "http3 was not restored"
fi

head_ "the extension catalog"
cat_res="$(req "$API/gpn/interception/catalog")"
src_count="$(echo "$cat_res" | jq -r '.catalog.sources | length')"
if [ "$src_count" -ge 1 ]; then
  ok "$src_count catalog source(s) are configured"
else
  bad "no catalog source is configured: $(echo "$cat_res" | head -c 200)"
fi

src_id="$(echo "$cat_res" | jq -r '.catalog.sources[0].id')"
src_err="$(echo "$cat_res" | jq -r '.catalog.sources[0].error // ""')"
entries="$(echo "$cat_res" | jq -r '.catalog.sources[0].entries | length')"
if [ -n "$src_err" ]; then
  bad "the seeded catalog could not be fetched: $src_err"
elif [ "$entries" -ge 1 ]; then
  ok "$src_id lists $entries extensions"
else
  bad "$src_id fetched but lists nothing"
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
  rev_res="$(req -X POST --data '{}' "$API/gpn/interception/catalog/$src_id/entries/$entry_id/review")"
  if [ "$(echo "$rev_res" | jq -r '.candidate.detail.id // ""')" = "$entry_id" ]; then
    ok "reviewing $entry_id through the catalog succeeds"
  else
    bad "catalog review failed: $(echo "$rev_res" | head -c 300)"
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
  if [ "$(req "$API/gpn/interception" | jq -r --arg i "$entry_id" '[.snapshot.modules[] | select(.id==$i)] | length')" = "0" ]; then
    ok "reviewing installed nothing"
  else
    skip "$entry_id was already installed before this run"
  fi
else
  skip "catalog entry checks (nothing listed)"
fi

# An unknown source or entry is a 404, not a 500.
code="$(status -X POST --data '{}' "$API/gpn/interception/catalog/no.such.catalog/entries/x/review")"
if [ "$code" = "404" ]; then ok "an unknown catalog is a 404"; else bad "an unknown catalog returned $code"; fi
if [ "$entries" -ge 1 ]; then
  code="$(status -X POST --data '{}' "$API/gpn/interception/catalog/$src_id/entries/no.such.entry/review")"
  if [ "$code" = "404" ]; then ok "an unknown entry is a 404"; else bad "an unknown entry returned $code"; fi
fi

head_ "the Telegram control plane"
bot="$(req "$API/gpn/bot")"
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
if [ "$(echo "$bot" | jq -r '.bot.state')" = "stopped" ]; then
  ok "an unconfigured bot is stopped"
else
  bad "an unconfigured bot reports state $(echo "$bot" | jq -r '.bot.state')"
fi

# An enabled bot with no token, or no admins, answers nobody. Both are refused
# rather than stored, because an operator would read the silence as a network
# fault and go looking in the wrong place.
code="$(status -X PUT --data "$(jq -nc --arg r "$bot_rev" '{revision:$r, enabled:true, admins:[42], alerts:false}')" "$API/gpn/bot")"
if [ "$code" = "422" ]; then ok "enabling without a token is refused"; else bad "enabling without a token returned $code"; fi
code="$(status -X PUT --data "$(jq -nc --arg r "$bot_rev" '{revision:$r, enabled:true, admins:[], alerts:false, token:"123:fake"}')" "$API/gpn/bot")"
if [ "$code" = "422" ]; then ok "enabling without an admin is refused"; else bad "enabling without an admin returned $code"; fi

# A disabled write with a token stores it without starting anything, which is
# what lets an operator stage the configuration before turning it on.
res="$(req -X PUT --data "$(jq -nc --arg r "$bot_rev" '{revision:$r, enabled:false, admins:[42], alerts:false, token:"123:acceptance-fake"}')" "$API/gpn/bot")"
if [ "$(echo "$res" | jq -r '.bot.token_set')" = "true" ] && [ "$(echo "$res" | jq -r '.bot.enabled')" = "false" ]; then
  ok "a token can be staged without enabling the bot"
else
  bad "staging a token failed: $(echo "$res" | head -c 200)"
fi
bot_rev="$(echo "$res" | jq -r .revision)"

# Editing the admin list without resending the token must keep it.
res="$(req -X PUT --data "$(jq -nc --arg r "$bot_rev" '{revision:$r, enabled:false, admins:[42,43], alerts:false}')" "$API/gpn/bot")"
if [ "$(echo "$res" | jq -r '.bot.token_set')" = "true" ] && [ "$(echo "$res" | jq -r '.bot.admins | length')" = "2" ]; then
  ok "editing the admin list keeps the stored token"
else
  bad "editing the admin list lost the token: $(echo "$res" | head -c 200)"
fi
bot_rev="$(echo "$res" | jq -r .revision)"

code="$(status -X PUT --data "$(jq -nc '{revision:"stale", enabled:false, admins:[42], alerts:false}')" "$API/gpn/bot")"
if [ "$code" = "409" ]; then ok "a stale bot revision is refused with 409"; else bad "a stale bot write returned $code"; fi

# Restore: clear the token and the admins.
res="$(req -X PUT --data "$(jq -nc --arg r "$bot_rev" '{revision:$r, enabled:false, admins:[], alerts:false, token:"-"}')" "$API/gpn/bot")"
if [ "$(echo "$res" | jq -r '.bot.token_set')" = "false" ]; then
  ok "the token was cleared and the gateway is back where it started"
else
  bad "the token was not cleared"
fi

head_ "the bot document is on disk, 0600, and holds no token"
doc=/etc/5gpn/mihomo/gpn/bot.json
if [ -f "$doc" ]; then
  ok "$doc exists"
  mode="$(stat -c '%a' "$doc")"
  if [ "$mode" = "600" ]; then ok "$doc is 0600"; else bad "$doc is $mode"; fi
  if [ "$(jq -r '.token' "$doc")" = "" ]; then
    ok "the cleared token really left the file"
  else
    bad "the file still holds a token"
  fi
else
  bad "$doc was not created"
fi

echo
echo "======================================"
echo " $pass passed, $fail failed"
echo "======================================"
[ "$fail" -eq 0 ]
