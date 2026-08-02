#!/usr/bin/env bash
# The seed template's placeholders, and everything that must expand them.
#
# etc/mihomo/config.yaml.tmpl is expanded by several independent renderers:
# install.sh, the CI job's own awk, and a mihomo regression script. They exist
# because they run in different contexts, and each hand-lists the placeholders
# it knows.
#
# There used to be a fourth: the daemon's Go copy, which re-rendered the seed
# for `mihomo-reset`. It is gone with the daemon, and it is not coming back --
# a second copy of the template is exactly what the byte-identical lock below
# had to exist to police. install.sh is the only renderer that writes a live
# config now.
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

# name = one or more files; a renderer may span files.
RENDERERS=(
    "install.sh|install.sh"
    "CI mihomo-config job|.github/workflows/checks.yml"
    "sniff-cache regression|tests/mihomo-sniff-cache-regression.sh"
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

# The lock that kept a second, in-binary copy byte-identical to this file is
# retired with that copy. What replaces it is the stronger condition: there is
# no second copy to lock. A cmd/ tree reappearing is the shape of the
# regression, since that is where the Go copy lived.
if [[ -e "$root/cmd" ]]; then
    echo "FAIL: a cmd/ tree came back; the seed template may have a second copy again"
    FAIL=1
else
    echo "ok: the template has exactly one copy"
fi

echo "----"
if (( FAIL == 0 )); then
    echo "test_seed_template_renderers: PASS"
else
    echo "test_seed_template_renderers: FAIL"
fi
exit "$FAIL"
