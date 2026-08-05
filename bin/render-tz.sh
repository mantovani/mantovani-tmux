#!/usr/bin/env bash
# Render this machine's UTC offset for the status bar: "-3 GMT", "+5:30 GMT",
# "0 GMT".
#
# tmux's strftime does offer %z, but it only produces "-0300". Rendering it here
# instead of baking the offset in at install time means DST transitions are
# picked up on the next refresh rather than staying wrong until someone re-runs
# install.sh.
set -u

z="$(date +%z)"                    # e.g. -0300, +0530, +0000
sign="${z:0:1}"
h=$(( 10#${z:1:2} ))               # 10# so 08/09 aren't read as bad octal
m=$(( 10#${z:3:2} ))

if [ "$h" -eq 0 ] && [ "$m" -eq 0 ]; then
  printf '0 GMT'
elif [ "$m" -eq 0 ]; then
  printf '%s%d GMT' "$sign" "$h"
else
  printf '%s%d:%02d GMT' "$sign" "$h" "$m"
fi
