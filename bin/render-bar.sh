#!/usr/bin/env bash
# Render a 4-block bar + fixed-width percentage from the sampler cache.
# Usage: render-bar.sh <cpu|mem|bat|gpu|vram> <colour>
#
# Load is encoded by the HEIGHT of the blocks (▁▂▃▄▅▆▇█), not by colour: the bar
# is the machine's colour at 1% and at 100%. One machine, one colour.
#
# The colour arrives without a leading '#'. tmux expands its legacy format
# shorthands inside #(...) BEFORE running the command, and '#F' is one of them
# (window flags), so "#FBBF24" would arrive here as "*BBF24". install.sh passes
# bare hex and we put the '#' back.
set -u

METRIC="${1:-}"
COLOR="${2:-}"
CACHE="/tmp/tmuxm-stats-${USER}"

if [ -z "$METRIC" ] || [ -z "$COLOR" ]; then
  echo "usage: render-bar.sh <cpu|mem|bat|gpu|vram> <colour>" >&2
  exit 1
fi
COLOR="#${COLOR#\#}"

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

printf "#[fg=%s]%s %3d%%#[fg=default,nobold]" "$COLOR" "$out" "$pct"
