#!/usr/bin/env bash
# Render 4-block matrix bar + fixed-width percentage from cache.
# Usage: render-bar.sh <cpu|mem|bat>
set -u

METRIC="${1:-}"
CACHE="/tmp/tmuxm-stats-${USER}"

pct=0
if [ -r "$CACHE" ]; then
  pct=$(awk -v k="$METRIC" '$1==k {print $2; exit}' "$CACHE")
fi
pct=${pct:-0}

bars=(▁ ▂ ▃ ▄ ▅ ▆ ▇ █)
out=""
for i in 0 1 2 3; do
  h=$(( (pct - i*25) * 8 / 25 ))
  (( h < 0 )) && h=0
  (( h > 7 )) && h=7
  out="${out}${bars[$h]}"
done

# Battery is inverted: low % is the danger zone.
if [ "$METRIC" = "bat" ]; then
  if   (( pct > 50 )); then c="#[fg=#00FF41]"
  elif (( pct > 20 )); then c="#[fg=#FFFF00]"
  else                      c="#[fg=#FF0000,bold]"
  fi
else
  if   (( pct < 50 )); then c="#[fg=#00FF41]"
  elif (( pct < 80 )); then c="#[fg=#FFFF00]"
  else                      c="#[fg=#FF0000,bold]"
  fi
fi

printf "%s%s %3d%%#[fg=default,nobold]" "$c" "$out" "$pct"
