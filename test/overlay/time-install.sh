#!/usr/bin/env bash
# Times an installer run.
#
# Timestamps the trace as it is read rather than relying on PS4, which the child
# shell did not pick up. Resolution is when the line reaches this loop, which is
# plenty for finding multi-second gaps — and multi-second gaps are the question:
# where does an install spend wall clock with nothing to show for it.
cd /tmp/b3 || exit 1
bash -x install.sh </dev/null 2>&1 >/tmp/t.out \
  | while IFS= read -r line; do printf '%s %s\n' "$EPOCHREALTIME" "$line"; done > /tmp/t.trace
echo "trace lines: $(wc -l < /tmp/t.trace)"
head -2 /tmp/t.trace
