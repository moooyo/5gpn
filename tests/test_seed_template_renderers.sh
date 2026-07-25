#!/usr/bin/env bash
# The seed template's placeholders, and everything that must expand them.
#
# etc/mihomo/config.yaml.tmpl is expanded by several independent renderers: two
# inside install.sh, the CI job's own awk, two mihomo regression scripts, and the
# daemon's Go copy. They exist because they run in different contexts — install
# time, CI, and `mihomo-reset` inside the daemon — and each hand-lists the
# placeholders it knows.
#
# That is the defect this guards. A placeholder added to the template and taught
# to only some of them leaves the others emitting `__SOMETHING__` verbatim: the
# rendered YAML either fails to parse or, worse, carries a literal placeholder
# into a live config. It has happened: three renderers went unfixed and the
# failure first surfaced in a release run for a tag that had already shipped.
#
# So the contract is derived from the template rather than restated here. Add a
# placeholder and this fails until every renderer knows it; add a renderer and
# add it to RENDERERS below.
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
template="$root/etc/mihomo/config.yaml.tmpl"
FAIL=0

[[ -f "$template" ]] || { echo "FAIL: no template at $template"; exit 1; }

# name = one or more files; a renderer may span files (the Go one expands values
# in mihomo_config.go and the overlay anchors in intercept_mihomo_overlay.go).
RENDERERS=(
    "install.sh|install.sh"
    "CI mihomo-config job|.github/workflows/checks.yml"
    "compact-suffix regression|tests/mihomo-compact-suffix-regression.sh"
    "sniff-cache regression|tests/mihomo-sniff-cache-regression.sh"
    "daemon (mihomo-reset)|cmd/5gpn-dns/mihomo_config.go cmd/5gpn-dns/intercept_mihomo_overlay.go"
)

mapfile -t placeholders < <(grep -oE '__[A-Z0-9_]+__' "$template" | sort -u)
(( ${#placeholders[@]} > 0 )) || { echo "FAIL: template declares no placeholders"; exit 1; }

echo "template declares ${#placeholders[@]} placeholders"
for entry in "${RENDERERS[@]}"; do
    name="${entry%%|*}"
    files="${entry#*|}"
    missing=()
    for ph in "${placeholders[@]}"; do
        found=0
        for f in $files; do
            [[ -f "$root/$f" ]] || { echo "FAIL: $name names a file that does not exist: $f"; FAIL=1; continue; }
            grep -Fq -- "$ph" "$root/$f" && { found=1; break; }
        done
        (( found == 1 )) || missing+=("$ph")
    done
    if (( ${#missing[@]} == 0 )); then
        echo "ok: $name expands every placeholder"
    else
        echo "FAIL: $name does not expand: ${missing[*]}"
        FAIL=1
    fi
done

# The Go copy of the template is byte-identical to the repo file, locked by
# TestMihomoConfigSeedTemplate_MatchesRepoFile. Assert the lock exists, because
# without it the two could drift in content rather than in placeholder coverage.
if grep -Fq 'TestMihomoConfigSeedTemplate_MatchesRepoFile' "$root/cmd/5gpn-dns/mihomo_config_test.go"; then
    echo "ok: the Go copy is locked byte-identical to the template"
else
    echo "FAIL: nothing locks the Go copy of the template to the repo file"
    FAIL=1
fi

echo "----"
if (( FAIL == 0 )); then
    echo "test_seed_template_renderers: PASS"
else
    echo "test_seed_template_renderers: FAIL"
fi
exit "$FAIL"
