#!/usr/bin/env bash
# Domain-validation consistency: the Go bot's domainRE (cmd/5gpn-dns/bot.go) and
# install.sh's is_valid_domain must enforce the same FQDN rule. Pure bash+grep —
# runs on the dev box and in CI.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$HERE/.."
rc=0; fail(){ echo "FAIL: $1"; rc=1; }

BOT="$ROOT/cmd/5gpn-dns/bot.go"; INSTALL="$ROOT/install.sh"

# (1) bot.go carries the canonical FQDN pattern (RE2 form, no lookahead — the
# ≤253 length bound is enforced separately in isValidDomain, mirroring install.sh).
PAT='^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$'
grep -Fq "$PAT" "$BOT"  || fail "bot.go domainRE is not the canonical FQDN pattern"

# (2) install.sh is_valid_domain must enforce the same rule. Extract + run in isolation.
fn="$(sed -n '/^is_valid_domain()/,/^}/p' "$INSTALL")"
[ -n "$fn" ] || fail "could not extract is_valid_domain from install.sh"
check(){ bash -c "${fn}
is_valid_domain \"\$1\"" _ "$1"; }   # exit 0 = valid, non-0 = invalid

# domain | want (0=valid, 1=invalid)
while IFS='|' read -r d want; do
  [ -z "${d}${want}" ] && continue
  check "$d" >/dev/null 2>&1; got=$?; [ "$got" -ne 0 ] && got=1
  [ "$got" = "$want" ] || fail "is_valid_domain('$d') got=$got want=$want"
done <<'TABLE'
example.com|0
sub.domain.example.com|0
a-b.example.com|0
EXAMPLE.COM|0
1foo.example.co|0
xn--fsq.com|0
|1
example|1
foo.c|1
foo.123|1
_dmarc.example.com|1
foo_bar.com|1
-foo.example.com|1
foo-.example.com|1
foo..com|1
ex ample.com|1
http://example.com|1
example.com/x|1
TABLE

[ $rc -eq 0 ] && echo "domain validation: PASS"
exit $rc
