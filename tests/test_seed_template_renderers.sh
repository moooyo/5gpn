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

# The drift check has to accept the seed the installer itself writes.
#
# This is the one coupling the placeholder scan above cannot see: the template
# writes the console allow rule, and mihomo_config_matches_install_config
# decides whether an existing config still matches the install. They are two
# spellings of the same rule in two files, so they drift — and the failure only
# appears on the SECOND install, because the first has no config to check.
#
# It has happened. The seed moved from NOT,((IN-NAME,intercept-egress)) to
# NOT,((IN-TYPE,INNER)) with the monolith and the check kept naming the retired
# form, so every monolith-installed gateway failed its own drift check and was
# told to run upgrade-reset-mihomo -- which replaces the operator's entire
# config. Fresh-install acceptance could not catch it by construction.
render_seed() {
    sed -e "s/__CONSOLE_DOMAIN__/console.seedcheck.test/g" \
        -e "s/__ZASH_DOMAIN__/zash.seedcheck.test/g" \
        -e "s/__GATEWAY_IP__/10.0.0.1/g" \
        -e "s/__CONTROLLER_SECRET__/seed-check-secret/g" \
        -e "s/^__MIHOMO_LISTENERS__$/  - {name: gateway, type: tunnel, listen: 10.0.0.1, port: 443, network: [tcp, udp], target: console.seedcheck.test:443}/" \
        "$template"
}

seed_dir="$(mktemp -d)"
trap 'rm -rf "$seed_dir"' EXIT
mkdir -p "$seed_dir/mihomo"
render_seed > "$seed_dir/mihomo/config.yaml"

(
    export INSTALL_SH_LIB_ONLY=1
    # shellcheck source=../install.sh
    source "$root/install.sh"
    MIHOMO_DIR="$seed_dir/mihomo"
    CONSOLE_DOMAIN=console.seedcheck.test
    ZASH_DOMAIN=zash.seedcheck.test
    BASE_DOMAIN=seedcheck.test
    GATEWAY_IP=10.0.0.1
    MIHOMO_LISTEN_IPS=10.0.0.1
    mihomo_config_matches_install_config
) >/dev/null 2>&1
if [[ $? == 0 ]]; then
    echo "ok: the drift check accepts the config the seed template renders"
else
    echo "FAIL: mihomo_config_matches_install_config rejects the installer's own seed"
    FAIL=1
fi

# Every retired shape must be rejected, recognised, AND fixed -- all three.
#
# Rejecting without recognising is what happened on the allowlist removal: a
# host carrying RULE-SET,whitelist failed the drift check correctly and was then
# told to "edit and validate the operator-owned file explicitly", naming neither
# the problem nor the script that fixes it. Recognising without fixing would be
# worse: the installer would send the operator to a migration that leaves the
# config exactly as rejected, and they would run it in a circle.
#
# So each shape is round-tripped: reject -> recognise -> migrate -> accept.
migrate="$root/scripts/migrate-panel-to-console.sh"
check_config() {  # <config> -> "<drift-rc> <predates-rc>"
    (
        export INSTALL_SH_LIB_ONLY=1
        # shellcheck source=../install.sh
        source "$root/install.sh"
        MIHOMO_DIR="$(dirname "$1")"
        CONSOLE_DOMAIN=console.seedcheck.test
        BASE_DOMAIN=seedcheck.test
        GATEWAY_IP=10.0.0.1
        MIHOMO_LISTEN_IPS=10.0.0.1
        # `cmd; rc=$?` would abort here: install.sh sets -e when sourced, and
        # both of these are expected to fail for a retired-shape config.
        local drift=0 predates=0
        mihomo_config_matches_install_config >/dev/null 2>&1 || drift=$?
        mihomo_config_predates_console "$1" >/dev/null 2>&1 || predates=$?
        printf '%s %s' "$drift" "$predates"
    )
}

for shape in allowlist controller9090; do
    shape_dir="$seed_dir/$shape/mihomo"
    mkdir -p "$shape_dir"
    case "$shape" in
        allowlist)
            # A config from before the allowlist was removed.
            render_seed \
                | sed -e 's|^hosts:$|rule-providers:\n  whitelist: {type: file, behavior: ipcidr, format: text, path: ./whitelist.txt}\nhosts:|' \
                      -e 's|^  - AND,((NOT,((IN-TYPE,INNER))),(DOMAIN,console.seedcheck.test)),DIRECT$|  - AND,((NOT,((IN-TYPE,INNER))),(DOMAIN,console.seedcheck.test),(RULE-SET,whitelist,DIRECT,src)),DIRECT|' \
                > "$shape_dir/config.yaml"
            grep -Fq 'RULE-SET,whitelist' "$shape_dir/config.yaml" \
                || { echo "FAIL: could not build the $shape fixture"; FAIL=1; continue; } ;;
        controller9090)
            # A config from before the controller moved to :443.
            render_seed \
                | sed -e 's|^external-controller-tls: 127.0.0.1:443$|external-controller-tls: 127.0.0.1:9090|' \
                > "$shape_dir/config.yaml"
            grep -Fq '127.0.0.1:9090' "$shape_dir/config.yaml" \
                || { echo "FAIL: could not build the $shape fixture"; FAIL=1; continue; } ;;
    esac

    read -r drift predates <<<"$(check_config "$shape_dir/config.yaml")"
    if [[ "$drift" == 0 ]]; then
        echo "FAIL: the drift check accepts a $shape config it cannot run"; FAIL=1
    elif [[ "$predates" != 0 ]]; then
        echo "FAIL: a rejected $shape config is not recognised as migratable"; FAIL=1
    elif ! bash "$migrate" "$shape_dir/config.yaml" --in-place >/dev/null 2>&1; then
        echo "FAIL: the migration refused the $shape config it is meant to fix"; FAIL=1
    else
        read -r drift predates <<<"$(check_config "$shape_dir/config.yaml")"
        if [[ "$drift" != 0 ]]; then
            echo "FAIL: the migration left a $shape config the drift check still rejects"; FAIL=1
        else
            echo "ok: a $shape config is rejected, recognised, migrated, then accepted"
        fi
    fi
done

# A command the installer tells an operator to run must be runnable as printed.
#
# It was not: the hint printed the bare script path, and nothing in scripts/
# carries the executable bit -- every one is 100644 in git, because the repo is
# developed on Windows, and the release tarball is a plain `cp -r scripts`. So
# the installer stopped the upgrade, named the fix, and the fix answered
# "command not found".
#
# The rule is the general one rather than "must say bash": either the target is
# executable in the tree, or the printed command invokes an interpreter.
hint="$(grep -o 'err "  [^"]*migrate-panel-to-console\.sh[^"]*"' "$root/install.sh" \
        | head -1 | sed 's/^err "  //; s/"$//')"
if [[ -z "$hint" ]]; then
    echo "FAIL: install.sh no longer prints a migration command"
    FAIL=1
else
    hint_script="$(printf '%s\n' "$hint" | tr ' ' '\n' | grep 'migrate-panel-to-console\.sh$' | head -1)"
    hint_mode="$(git -C "$root" ls-files -s -- scripts/migrate-panel-to-console.sh 2>/dev/null | awk '{print $1}')"
    if [[ "$hint_mode" == 100755 ]]; then
        echo "ok: the printed migration command targets an executable script"
    elif [[ "$hint" == bash\ * || "$hint" == sh\ * ]]; then
        echo "ok: the printed migration command runs a non-executable script through bash"
    else
        echo "FAIL: install.sh prints '${hint_script}' but it is mode ${hint_mode:-unknown} and no interpreter is named"
        FAIL=1
    fi
fi

echo "----"
if (( FAIL == 0 )); then
    echo "test_seed_template_renderers: PASS"
else
    echo "test_seed_template_renderers: FAIL"
fi
exit "$FAIL"
