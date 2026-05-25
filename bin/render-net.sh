#!/usr/bin/env bash
# Render fixed-width 6-char throughput from cache. Usage: render-net.sh <in|out>
set -u

DIR="${1:-}"
CACHE="/tmp/tmux-stats-${USER}"
KEY="net_${DIR}"

bps=0
if [ -r "$CACHE" ]; then
  bps=$(awk -v k="$KEY" '$1==k {print $2; exit}' "$CACHE")
fi
bps=${bps:-0}

# Always 6 chars: "    0B" " 99.3K" "999.9K" "  1.2M" "  3.4G"
awk -v b="$bps" 'BEGIN {
  if      (b < 1024)       printf "%5dB",   b
  else if (b < 1048576)    printf "%5.1fK", b/1024
  else if (b < 1073741824) printf "%5.1fM", b/1048576
  else                     printf "%5.1fG", b/1073741824
}'
