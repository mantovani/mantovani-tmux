#!/usr/bin/env bash
# Render 4-block matrix bar for one metric. Usage: matrix-bar.sh <cpu|mem|bat>
set -u

case "${1:-}" in
  cpu) pct=$(top -l1 -n0 | awk '/CPU usage/ {gsub("%",""); print int($3+$5); exit}') ;;
  mem) pct=$(memory_pressure 2>/dev/null | awk '/percentage/ {print 100-$NF; exit}') ;;
  bat) pct=$(pmset -g batt 2>/dev/null | grep -Eo '[0-9]+%' | head -1 | tr -d '%') ;;
  *)   echo "usage: $0 <cpu|mem|bat>" >&2; exit 1 ;;
esac
pct=${pct:-0}

bars=(▁ ▂ ▃ ▄ ▅ ▆ ▇ █)
out=""
for i in 0 1 2 3; do
  h=$(( (pct - i*25) * 8 / 25 ))
  (( h < 0 )) && h=0
  (( h > 7 )) && h=7
  out="${out}${bars[$h]}"
done

# Color escalation — bars show actual level; color shows criticality.
# For battery, low % is the danger zone, so the thresholds invert.
if [ "$1" = "bat" ]; then
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
printf "%s%s %d%%#[fg=default,nobold]" "$c" "$out" "$pct"
