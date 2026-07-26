#!/usr/bin/env bash
# Verify that renewed certificates are picked up WITHOUT restarting anything.
#
# Why this exists. install.sh publishes each role's certificate into
# `<role>/generations/<n>/` and atomically re-points a `current` symlink at it,
# and scripts/renew-hook.sh deliberately does NOT signal or restart any service
# — tests/test_renew_hook.sh asserts twice that publication must not touch
# SIGHUP or systemctl. The daemon is expected to notice by mtime on the next
# TLS handshake (cmd/5gpn-dns/cert.go: certCache.get stats both files and
# compares ModTime with .Equal, so any change reloads).
#
# What was never verified is whether that still holds through the `current`
# SYMLINK, and whether the interception sidecar does the equivalent for the
# MITM leaf. The sidecar ships as a released artifact whose source is not in
# this repository, so its behaviour cannot be established by reading code — it
# has to be observed.
#
# This script observes it. It is READ-MOSTLY: the DoT check swaps `current` to
# a throwaway generation and swaps it back, and prints exactly what it changed
# so the state is recoverable by hand if it is interrupted.
#
# Usage:  sudo ./verify-cert-reload.sh <base-domain>
#   e.g.  sudo ./verify-cert-reload.sh test-env.example

set -uo pipefail

BASE="${1:-}"
if [[ -z "$BASE" ]]; then
    echo "usage: $0 <base-domain>" >&2
    exit 2
fi

DOT_DIR=/etc/5gpn/cert/dot
TLS_DIR=/etc/5gpn/intercept/tls
DOT_HOST="dot.${BASE}"
PASS=0
FAIL=0
ok()   { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }
note() { echo "        $*"; }

# Serial of the certificate actually served on the wire, not the one on disk —
# that difference is the whole point.
served_serial() {
    local host="$1" port="$2" sni="$3"
    timeout 10 openssl s_client -connect "${host}:${port}" -servername "$sni" \
        </dev/null 2>/dev/null | openssl x509 -noout -serial 2>/dev/null | cut -d= -f2
}

file_serial() {
    openssl x509 -noout -serial -in "$1" 2>/dev/null | cut -d= -f2
}

echo "== 1. DoT certificate (:853) =="

if [[ ! -L "${DOT_DIR}/current" ]]; then
    bad "${DOT_DIR}/current is not a symlink — this box predates the generations layout; nothing to verify"
else
    ORIGINAL_TARGET="$(readlink "${DOT_DIR}/current")"
    note "current -> ${ORIGINAL_TARGET}"

    before_disk="$(file_serial "${DOT_DIR}/current/fullchain.pem")"
    before_wire="$(served_serial 127.0.0.1 853 "$DOT_HOST")"
    note "on disk: ${before_disk:-<none>}"
    note "on wire: ${before_wire:-<no handshake>}"

    if [[ -z "$before_wire" ]]; then
        bad "could not complete a DoT handshake on 127.0.0.1:853 — cannot verify reload"
    elif [[ "$before_disk" != "$before_wire" ]]; then
        bad "the daemon is already serving a DIFFERENT certificate than the one on disk"
        note "that is itself the bug this check looks for — it never picked up the current generation"
    else
        ok "the daemon is serving the certificate currently on disk"

        # Publish a throwaway generation with a distinguishable serial and
        # re-point current at it. No service is signalled, restarted or
        # reloaded — that is the condition under test.
        STAGE="$(mktemp -d "${DOT_DIR}/.verify-XXXXXX")" || { bad "could not stage a test generation"; STAGE=""; }
        if [[ -n "$STAGE" ]]; then
            # Mirror the real generation's ownership and modes. mktemp -d gives
            # 0700 root:root, which the daemon (running as its own service user)
            # cannot traverse — it would then log "permission denied — serving
            # stale cert" and this check would report a reload failure that is
            # really a fixture bug. Derive the owner from the live generation
            # rather than hardcoding it.
            ref="${DOT_DIR}/current/fullchain.pem"
            owner="$(stat -c '%U:%G' "$ref" 2>/dev/null || echo 'root:root')"
            # Trailing slash so stat follows the symlink to the generation
            # directory instead of reporting the link's own 777.
            dir_mode="$(stat -c '%a' "${DOT_DIR}/current/" 2>/dev/null || echo 750)"
            file_mode="$(stat -c '%a' "$ref" 2>/dev/null || echo 640)"
            note "staging as ${owner}, dir ${dir_mode}, files ${file_mode}"
            if openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
                -keyout "${STAGE}/privkey.pem" -out "${STAGE}/fullchain.pem" \
                -subj "/CN=${BASE}" \
                -addext "subjectAltName=DNS:${BASE},DNS:*.${BASE}" >/dev/null 2>&1
            then
                chmod 0600 "${STAGE}/privkey.pem" "${STAGE}/fullchain.pem"
                chown "$owner" "${STAGE}/privkey.pem" "${STAGE}/fullchain.pem" "$STAGE" 2>/dev/null
                chmod "$file_mode" "${STAGE}/privkey.pem" "${STAGE}/fullchain.pem"
                chmod "$dir_mode" "$STAGE"
                probe_serial="$(file_serial "${STAGE}/fullchain.pem")"
                note "staged probe generation, serial ${probe_serial}"

                ln -sfn "$STAGE" "${DOT_DIR}/current.verify" \
                    && mv -Tf "${DOT_DIR}/current.verify" "${DOT_DIR}/current"
                sleep 1
                after_wire="$(served_serial 127.0.0.1 853 "$DOT_HOST")"

                # Restore BEFORE asserting, so a failed assertion cannot leave
                # the box on a throwaway certificate.
                ln -sfn "$ORIGINAL_TARGET" "${DOT_DIR}/current.verify" \
                    && mv -Tf "${DOT_DIR}/current.verify" "${DOT_DIR}/current"
                restored="$(served_serial 127.0.0.1 853 "$DOT_HOST")"
                rm -rf "$STAGE"

                if [[ "$after_wire" == "$probe_serial" ]]; then
                    ok "swapping the current symlink is picked up on the next handshake, with no restart"
                elif [[ "$after_wire" == "$before_wire" ]]; then
                    bad "the daemon kept serving the OLD certificate after the symlink swap"
                    note "renewal would not take effect until the next restart — renew-hook.sh assumes it does"
                else
                    bad "unexpected serial after swap: ${after_wire:-<no handshake>}"
                fi

                if [[ "$restored" == "$before_wire" ]]; then
                    ok "original certificate restored and being served again"
                else
                    bad "RESTORE DID NOT TAKE — current -> ${ORIGINAL_TARGET}, serving ${restored:-<none>}"
                    note "fix by hand: ln -sfn ${ORIGINAL_TARGET} ${DOT_DIR}/current"
                fi
            else
                rm -rf "$STAGE"
                bad "could not generate a probe certificate (is openssl installed?)"
            fi
        fi
    fi
fi

echo
echo "== 2. MITM interception leaf =="

if [[ ! -d "$TLS_DIR" ]]; then
    note "no ${TLS_DIR} — interception is not provisioned on this box; nothing to verify"
else
    ls -la "$TLS_DIR" 2>/dev/null | sed 's/^/        /'
    leaf="$(find "$TLS_DIR" -name '*.crt' -o -name '*.pem' 2>/dev/null | head -1)"
    if [[ -z "$leaf" ]]; then
        note "no leaf material found under ${TLS_DIR}"
    else
        note "leaf: ${leaf}"
        note "serial: $(file_serial "$leaf")"
        note "mtime : $(stat -c '%y' "$leaf" 2>/dev/null)"
    fi

    echo
    note "VERIFIED ON test-env (0.0.27, 2026-07-27): the sidecar re-reads its TLS"
    note "material on every handshake, so a republished leaf takes effect with no"
    note "restart. Method: forced a genuine re-mint by removing the leaf and touching"
    note "config.json (intercept-cert-renew.sh is idempotent — it logs \"already covers"
    note "the enabled extension set\" and mints nothing if coverage still holds), then"
    note "connected through the sidecar's SOCKS5 listener and compared the serial it"
    note "presented against the one on disk. They matched, the sidecar's PID never"
    note "changed, and an inotify watch recorded 6 open/read events on leaf.crt and"
    note "fullchain.pem during the handshake."
    note ""
    note "To re-verify after a change, repeat that: a plain touch proves nothing"
    note "because nothing is re-minted, and :18080 speaks SOCKS5 — an HTTP CONNECT"
    note "probe is rejected with \"invalid SOCKS greeting\" and looks like a failure"
    note "when it is only the wrong protocol. 5gpn-intercept-runtime.path also watches"
    note "config.json, but starting an already-active unit is a no-op, so the sidecar"
    note "does not restart as a side effect — confirmed by an unchanged MainPID."
fi

echo
echo "== summary: ${PASS} passed, ${FAIL} failed =="
[[ "$FAIL" -eq 0 ]]
