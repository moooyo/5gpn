#!/usr/bin/env bash
# Export a bounded tail for one fixed 5gpn runtime unit. This script is invoked
# only by the root-owned 5gpn-journal@.service template; callers cannot choose
# an arbitrary journal unit or output path.
set -euo pipefail

service="${1:-}"
case "$service" in
    5gpn-dns) unit="5gpn-dns.service" ;;
    mihomo) unit="mihomo.service" ;;
    *) echo "unsupported 5gpn journal service" >&2; exit 2 ;;
esac

output_dir="/run/5gpn-journal"
output="${output_dir}/${service}.log"
canonical="$(readlink -f -- "$output_dir" 2>/dev/null || true)"
expected_gid="$(getent group gpn-dns | cut -d: -f3)"
[[ "$canonical" == "$output_dir" && -d "$output_dir" && ! -L "$output_dir" ]] \
    || { echo "unsafe journal export directory" >&2; exit 1; }
[[ "$(stat -c %u "$output_dir")" == 0 \
   && "$(stat -c %g "$output_dir")" == "$expected_gid" \
   && "$(stat -c %a "$output_dir")" == 750 ]] \
    || { echo "unsafe journal export directory ownership or mode" >&2; exit 1; }

tmp="$(mktemp "${output_dir}/.${service}.XXXXXX")"
trap 'rm -f -- "$tmp"' EXIT
umask 0027
journalctl --quiet -u "$unit" -n 50 --no-pager -o short-iso \
    | tail -c 262144 > "$tmp"
chown root:gpn-dns "$tmp"
chmod 0640 "$tmp"
sync -f "$tmp" 2>/dev/null || true
mv -f -- "$tmp" "$output"
sync -f "$output_dir" 2>/dev/null || true
trap - EXIT
