#!/usr/bin/env bash
# Migrate a rendered mihomo config to the runtime-overlay arrangement.
#
# The legacy driver writes three managed regions into the operator's config: the
# extension policy rules, the processor egress selectors, and the capture rules.
# Under the overlay none of them live in the file — they are compiled into a
# typed generation and committed over a socket — so migrating means removing all
# three and leaving the two anchors that resolve them.
#
# What must NOT be touched is everything else in the rule list. Those are the
# operator's own rules, including the panel guards and the private-range denies,
# and the whole point of the overlay is that a routing change stops perturbing
# them.
#
# Writes a candidate; it does not install it. Validate with `mihomo -t` and put
# it in place yourself, because this rewrites the file the data plane runs on.
#
#   migrate-to-anchored.sh /etc/5gpn/mihomo/config.yaml /tmp/config-anchored.yaml
set -euo pipefail

SOURCE="${1:-/etc/5gpn/mihomo/config.yaml}"
OUT="${2:-/tmp/config-anchored.yaml}"
OWNER="${OVERLAY_OWNER:-5gpn}"
CONTROL_SOCKET="${OVERLAY_CONTROL_SOCKET:-/run/mihomo/overlay-control.sock}"
GENERATION_SOCKET="${OVERLAY_GENERATION_SOCKET:-/run/mihomo/overlay-generation.sock}"
DNS_USER="${DNS_SERVICE_USER:-gpn-dns}"
INTERCEPT_USER="${INTERCEPT_SERVICE_USER:-gpn-intercept}"
CONTROL_GROUP="${OVERLAY_CONTROL_GROUP:-5gpn-overlay-ctl}"
GENERATION_GROUP="${OVERLAY_GENERATION_GROUP:-5gpn-overlay-gen}"

[[ -r "$SOURCE" ]] || { echo "cannot read $SOURCE" >&2; exit 1; }

# A one-shot migration. Run twice, it would strip the client anchor as if it
# were a rendered policy rule and splice it back — the right answer by accident,
# which is not a property to rely on. Refusing says plainly that this config has
# already been migrated.
if grep -q '^[[:space:]]*-[[:space:]]*RUNTIME-OVERLAY,' "$SOURCE"; then
    echo "$SOURCE already carries overlay anchors; nothing to migrate" >&2
    exit 2
fi

id_of() { id -u "$1" 2>/dev/null || return 1; }
gid_of() { id -g "$1" 2>/dev/null || return 1; }
group_gid() { getent group "$1" | cut -d: -f3; }

dns_uid="$(id_of "$DNS_USER")" || { echo "unknown user $DNS_USER" >&2; exit 1; }
dns_gid="$(gid_of "$DNS_USER")"
intercept_uid="$(id_of "$INTERCEPT_USER")" || { echo "unknown user $INTERCEPT_USER" >&2; exit 1; }
intercept_gid="$(gid_of "$INTERCEPT_USER")"
control_gid="$(group_gid "$CONTROL_GROUP")"
generation_gid="$(group_gid "$GENERATION_GROUP")"
[[ -n "$control_gid" && -n "$generation_gid" ]] \
    || { echo "create the socket groups $CONTROL_GROUP and $GENERATION_GROUP first" >&2; exit 1; }

awk -v owner="$OWNER" '
# Two passes. The first locates the landmarks the second needs: the managed
# policy region is bounded by the UDP deny and the terminal MATCH, and the
# anchors are spliced relative to the egress terminator and that MATCH.
function is_rule(line) { return line ~ /^[[:space:]]*-[[:space:]]/ }
function body(line) { sub(/^[[:space:]]*-[[:space:]]*/, "", line); return line }

NR == FNR {
    if ($0 ~ /^rules:[[:space:]]*$/) { rules_at = FNR }
    if (rules_at && FNR > rules_at && is_rule($0)) {
        b = body($0)
        if (b == "AND,((NETWORK,UDP),(DST-PORT,443)),REJECT") udp_at = FNR
        if (b ~ /^MATCH,/) match_at = FNR
        if (b == "IN-NAME,intercept-egress,REJECT") term_at = FNR
    }
    next
}

FNR == 1 {
    if (!rules_at || !udp_at || !match_at || !term_at) {
        print "this config does not have the rendered layout this migrates from" > "/dev/stderr"
        exit 1
    }
}

{
    line = $0
    if (!is_rule(line) || FNR < rules_at) {
        # The processor outbound has to declare itself, or the core refuses to
        # stage a generation whose capture rules name it — which is what stops
        # an overlay handing traffic to an arbitrary proxy. A migrated config
        # without this parses fine and can never commit anything.
        if (line ~ /^[[:space:]]*-[[:space:]]*name:[[:space:]]*MODULE-INTERCEPT[[:space:]]*$/) in_processor = 1
        else if (line ~ /^[[:space:]]*-[[:space:]]*name:/) in_processor = 0
        if (line ~ /runtime-overlay-processor:/) declared = 1
        print line
        if (in_processor && !declared && line ~ /^[[:space:]]*udp:[[:space:]]*true[[:space:]]*$/) {
            indent = line; sub(/[^[:space:]].*$/, "", indent)
            print indent "runtime-overlay-processor: true"
            declared = 1
        }
        next
    }
    b = body(line)

    # Capture rules steer at the processor outbound.
    if (b ~ /,MODULE-INTERCEPT$/) { capture++; next }
    # Egress rules are qualified BY the processor inbound. The panel guards
    # mention the same inbound but negated; they are operator rules and stay.
    if (index(b, "(IN-NAME,intercept-egress)") > 0 && index(b, "NOT,((IN-NAME,intercept-egress))") == 0) {
        egress++; next
    }
    # The extension policy rules occupy the span between the UDP deny and the
    # terminal MATCH. Everything there is daemon-rendered.
    if (FNR > udp_at && FNR < match_at) { policy++; next }

    # A panel allow rule that does not exclude processor traffic is a path a
    # processor-originated connection can take to the management plane without
    # meeting an anchor, and the core refuses the config for it. The seed ships
    # these qualified; a box installed before that does not.
    if (b ~ /,DIRECT$/ && index(b, "NOT,((IN-NAME,intercept-egress))") == 0) {
        matcher = substr(b, 1, length(b) - length(",DIRECT"))
        inner = ""
        if (matcher ~ /^AND,\(\(.*\)\)$/) {
            inner = substr(matcher, 7, length(matcher) - 8)
        } else if (matcher ~ /^[A-Z][A-Z0-9-]*,/) {
            inner = matcher
        }
        if (inner != "") {
            indent = line; sub(/[^[:space:]].*$/, "", indent)
            line = indent "- AND,((NOT,((IN-NAME,intercept-egress))),(" inner ")),DIRECT"
            requalified++
        }
    }

    if (FNR == term_at) print "  - RUNTIME-OVERLAY," owner ",egress"
    if (FNR == match_at) print "  - RUNTIME-OVERLAY," owner ",client"
    print line
}

END {
    printf "removed: capture=%d egress=%d policy=%d; requalified %d panel allow rules\n",
        capture, egress, policy, requalified > "/dev/stderr"
}
' "$SOURCE" "$SOURCE" > "$OUT"

cat >> "$OUT" <<EOF

runtime-overlay:
  owner: ${OWNER}
  control-socket: ${CONTROL_SOCKET}
  generation-socket: ${GENERATION_SOCKET}
  # Only the coordinator may commit a generation.
  control-peer-uid: ${dns_uid}
  control-peer-gid: ${dns_gid}
  control-socket-gid: ${control_gid}
  # Only the processor may read the generation it is serving.
  generation-peer-uid: ${intercept_uid}
  generation-peer-gid: ${intercept_gid}
  generation-socket-gid: ${generation_gid}
EOF

echo "wrote $OUT" >&2
echo "validate it before installing: mihomo -t -f $OUT -d /etc/5gpn/mihomo" >&2
