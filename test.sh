#!/usr/bin/env bash
# Test suite for tmuxm. Runs install.sh against throwaway HOMEs and points
# TMUX_TMPDIR at a scratch dir so `tmux info` fails and the real server is never
# touched. Exits 0 when everything passes.
#
#   ./test.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CACHE="/tmp/tmuxm-stats-${USER}"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2' want '$3')"; fi; }

newhome() {
  local h; h="$(mktemp -d "${TMPDIR:-/tmp}/tmuxm-home.XXXXXX")"
  mkdir -p "$h/.tmux/plugins/tpm" "$h/tmuxtmp"   # pre-made TPM dir skips the clone
  printf '%s' "$h"
}
run() { local h="$1"; shift; HOME="$h" TMUX_TMPDIR="$h/tmuxtmp" "$REPO/install.sh" "$@" 2>&1; }

# The colour engine, extracted from install.sh so the tests exercise the real
# implementation rather than a copy of it.
ENGINE="$(sed -n '/^OKLCH_AWK=\$(cat <<.AWKEOF.$/,/^AWKEOF$/p' "$REPO/install.sh" | sed '1d;$d')"
derive() { awk -v MODE=derive -v ACCENT="$1" "$ENGINE" </dev/null; }

# WCAG relative luminance -> contrast against black.
contrast_on_black() {
  awk -v C="$1" 'function hv(s,  i,c,v,d){v=0;for(i=1;i<=length(s);i++){c=tolower(substr(s,i,1));d=index("0123456789abcdef",c)-1;v=v*16+d}return v}
    function lin(c){c=c/255.0; return (c<=0.04045)? c/12.92 : ((c+0.055)/1.055)^2.4}
    BEGIN{ h=C; sub(/^#/,"",h)
      r=lin(hv(substr(h,1,2))); g=lin(hv(substr(h,3,2))); b=lin(hv(substr(h,5,2)))
      printf "%.2f", (0.2126*r+0.7152*g+0.0722*b + 0.05)/0.05 }'
}

echo "=== 1. Same colour at every load level ==="
cp "$CACHE" "$CACHE.testbak" 2>/dev/null
prev=""
for pct in 1 25 49 50 65 79 80 99 100; do
  printf 'cpu %s\nmem %s\n' "$pct" "$pct" > "$CACHE"
  got="$(bash "$REPO/bin/render-bar.sh" cpu aabbcc | sed 's/^#\[fg=\([^]]*\)\].*/\1/')"
  [ -z "$prev" ] && prev="$got"
  if [ "$got" != "#aabbcc" ]; then bad "at ${pct}% expected #aabbcc, got $got"; miss=1; fi
done
[ "${miss:-0}" -eq 0 ] && ok "1% through 100% all render the identical colour"
chk "bar height still tracks load (1%)"   "$(printf 'cpu 1\n'   > "$CACHE"; bash "$REPO/bin/render-bar.sh" cpu aabbcc | sed 's/.*\]\(....\).*/\1/')" "▁▁▁▁"
chk "bar height still tracks load (100%)" "$(printf 'cpu 100\n' > "$CACHE"; bash "$REPO/bin/render-bar.sh" cpu aabbcc | sed 's/.*\]\(....\).*/\1/')" "████"
[ -f "$CACHE.testbak" ] && mv "$CACHE.testbak" "$CACHE"

echo
echo "=== 2. render-bar.sh requires a colour (no hidden default) ==="
if bash "$REPO/bin/render-bar.sh" cpu >/dev/null 2>&1; then bad "ran without a colour"; else ok "exits non-zero with no colour argument"; fi

echo
echo "=== 3. Random colours are legible on black (measured, not assumed) ==="
worst=99; worsthex=""; gen=""
for i in $(seq 1 120); do
  c="$(awk -v MODE=random -v RH="$(( RANDOM % 360 ))" -v RL="$(( RANDOM % 101 ))" -v RC="$(( 60 + RANDOM % 41 ))" "$ENGINE" </dev/null)"
  r="$(contrast_on_black "$c")"
  gen="$gen$c "
  if awk -v a="$r" -v b="$worst" 'BEGIN{exit !(a<b)}'; then worst="$r"; worsthex="$c"; fi
done
if awk -v w="$worst" 'BEGIN{exit !(w>=7.0)}'; then
  ok "120 random colours, worst contrast ${worst}:1 ($worsthex) — clears WCAG AAA"
else
  bad "worst contrast ${worst}:1 ($worsthex) is below AAA 7:1"
fi

echo
echo "=== 4. Random is really random, not a list ==="
n="$(printf '%s\n' $gen | sort -u | wc -l | tr -d ' ')"
if [ "$n" -ge 100 ]; then ok "$n distinct colours out of 120 draws"; else bad "only $n distinct out of 120 — looks like a fixed list"; fi
hues="$(for c in $gen; do awk -v C="$c" "$ENGINE"'
  BEGIN{ to_oklch(C); printf "%d\n", OK_H/30 }' </dev/null 2>/dev/null; done | sort -u | wc -l | tr -d ' ')"
if [ "${hues:-0}" -ge 8 ]; then ok "hues span $hues of the 12 wheel sectors"; else bad "hues only span ${hues:-0}/12 sectors"; fi

echo
echo "=== 5. Derived shades keep the accent's hue ==="
for c in '#ff69b4' '#1e3a8a' '#22d3ee'; do
  eval "$(derive "$c")"
  hs="$(for x in "$THEME_ACCENT" "$THEME_DIM"; do awk -v C="$x" "$ENGINE"' BEGIN{to_oklch(C); printf "%d ", OK_H}' </dev/null; done)"
  set -- $hs
  d1=$(( $1 - $2 )); [ $d1 -lt 0 ] && d1=$(( -d1 ))
  if [ $d1 -le 6 ]; then ok "$c: accent/dim share a hue (${hs% })"; else bad "$c: hues drift (${hs% })"; fi
done

echo
echo "=== 6. A dark colour is lifted to stay legible on black ==="
eval "$(derive '#1e3a8a')"
r="$(contrast_on_black "$THEME_ACCENT")"
if [ "$THEME_ACCENT" != "#1e3a8a" ] && awk -v a="$r" 'BEGIN{exit !(a>=7.0)}'; then
  ok "dark #1e3a8a lifted to $THEME_ACCENT (${r}:1)"
else
  bad "dark colour not lifted (got $THEME_ACCENT, ${r}:1)"
fi
eval "$(derive '#ff69b4')"
chk "an already-legible colour is left exactly alone" "$THEME_ACCENT" "#ff69b4"

echo
echo "=== 6b. Active shade and text colour are solved, not assumed ==="
for spec in '#ff69b4:black' '#1e3a8a:white' '#fde047:black'; do
  c="${spec%%:*}"; want_fg="${spec##*:}"
  eval "$(derive "$c")"
  chk "$c: bar text colour" "$THEME_BASE_FG" "$want_fg"
  # active must differ from the bar and keep the hue
  ha="$(awk -v C="$c" "$ENGINE"' BEGIN{to_oklch(C); printf "%d", OK_H}' </dev/null)"
  hb="$(awk -v C="$THEME_ACTIVE" "$ENGINE"' BEGIN{to_oklch(C); printf "%d", OK_H}' </dev/null)"
  d=$(( ha - hb )); [ $d -lt 0 ] && d=$(( -d )); [ $d -gt 180 ] && d=$(( 360 - d ))
  if [ "$THEME_ACTIVE" != "$c" ] && [ $d -le 6 ]; then
    ok "$c: active $THEME_ACTIVE differs from the bar, same hue"
  else
    bad "$c: active $THEME_ACTIVE (hue drift ${d}°)"
  fi
  # its text colour must actually clear AA against it
  r="$(contrast_on_black "$THEME_ACTIVE")"
  if [ "$THEME_ACTIVE_FG" = "white" ]; then
    awk -v a="$r" 'BEGIN{exit !(a<=12)}' && ok "$c: white text on $THEME_ACTIVE is the right call" \
      || bad "$c: white chosen on a light active shade (${r}:1 vs black)"
  else
    awk -v a="$r" 'BEGIN{exit !(a>4)}' && ok "$c: black text on $THEME_ACTIVE is the right call" \
      || bad "$c: black chosen on a dark active shade (${r}:1 vs black)"
  fi
done

echo
echo "=== 7. Random is sticky: only the first install generates ==="
H="$(newhome)"
run "$H" >/dev/null
c1="$(awk '/^# Machine colour:/{print $4}' "$H/.tmux.local.conf")"
run "$H" >/dev/null; c2="$(awk '/^# Machine colour:/{print $4}' "$H/.tmux.local.conf")"
run "$H" >/dev/null; c3="$(awk '/^# Machine colour:/{print $4}' "$H/.tmux.local.conf")"
if [ -n "$c1" ]; then ok "first bare install generated $c1"; else bad "no colour written"; fi
chk "second bare install keeps it" "$c2" "$c1"
chk "third bare install keeps it"  "$c3" "$c1"
run "$H" --color '#ff69b4' >/dev/null
chk "--color pins an explicit colour" "$(awk '/^# Machine colour:/{print $4}' "$H/.tmux.local.conf")" "#ff69b4"
before="$(awk '/^# Machine colour:/{print $4}' "$H/.tmux.local.conf")"
run "$H" --color random >/dev/null
after="$(awk '/^# Machine colour:/{print $4}' "$H/.tmux.local.conf")"
if [ "$before" != "$after" ]; then ok "--color random re-rolls ($before → $after)"; else bad "--color random did not change it"; fi

echo
echo "=== 8. Idempotence + unmanaged lines survive ==="
run "$H" --color '#ff69b4' >/dev/null
printf '\nbind-key -T copy-mode-vi y send-keys -X copy-pipe-and-cancel xclip\n' >> "$H/.tmux.local.conf"
cp "$H/.tmux.local.conf" "$H/snap1"
run "$H" --color '#ff69b4' >/dev/null
if cmp -s "$H/snap1" "$H/.tmux.local.conf"; then ok "same --color twice is byte-identical"; else bad "not idempotent"; fi
if grep -q 'copy-pipe-and-cancel' "$H/.tmux.local.conf"; then ok "unmanaged xclip binding survived"; else bad "xclip binding lost"; fi

echo
echo "=== 9. Conflict detection only fires outside the block ==="
out="$(run "$H" --color '#ff69b4')"
if printf '%s' "$out" | grep -q 'OUTSIDE the managed block'; then bad "false positive on a clean file"; else ok "clean file produces no warning"; fi
printf 'set -g status-left "stale"\n' >> "$H/.tmux.local.conf"
out="$(run "$H" --color '#ff69b4')"
if printf '%s' "$out" | grep -q 'OUTSIDE the managed block'; then ok "stale status-left outside the block is flagged"; else bad "missed the stale override"; fi
rm -rf "$H"

echo
echo "=== 10. Generated status-right survives tmux format expansion ==="
# tmux expands legacy shorthands (#F = window flags) inside #(...) before
# running the command; a '#' in the colour would silently corrupt the argument.
H="$(newhome)"
for c in '#ff69b4' '#FBBF24' '#FF0000' 'random'; do
  run "$H" --color "$c" >/dev/null
  sr="$(awk '/^set -g status-right /{sub(/^set -g status-right "/,""); sub(/"$/,""); print}' "$H/.tmux.local.conf")"
  # -o, not -c: both calls live on the same line, so -c would only ever say 1.
  args="$(printf '%s\n' "$sr" | grep -o "render-bar\.sh [a-z]* [0-9a-fA-F]\{6\})" | wc -l | tr -d ' ')"
  chk "$c: both render-bar calls carry a clean hex arg" "$args" "2"
  if command -v tmux >/dev/null && tmux display-message -p "$sr" 2>/dev/null | grep -q '\*'; then
    bad "$c: tmux mangled the status-right"
  else
    ok "$c: no shorthand corruption after tmux expansion"
  fi
done
rm -rf "$H"

echo
echo "=== 11. Sampler stops cleanly and promptly on SIGTERM ==="
# update.sh stops the sampler with SIGTERM before restarting it. Dying *by* the
# signal makes tmux log "terminated by signal 15"; dying slowly is worse — it
# outlasts update.sh's wait, so the replacement sees a live sampler and gives
# up, leaving none running.
# sampler.sh derives its pidfile and cache from $USER, so overriding USER gives
# these tests their own /tmp paths. Without it they would contend for the
# pidfile of the sampler actually running this session and kill it.
TU="tmuxmtest$$"
pf="/tmp/tmuxm-sampler-${TU}.pid"
rm -f "$pf" "/tmp/tmuxm-stats-${TU}"

# Invoke bash directly, not via a shell function: `f & pid=$!` records the
# PID of the subshell running f, not of the sampler inside it, so the TERM
# would go to a wrapper that has no handler.
USER="$TU" bash "$REPO/bin/sampler.sh" & sp=$!
sleep 1
if [ -f "$pf" ]; then ok "sampler claimed the pidfile ($(cat "$pf"))"; else bad "no pidfile created"; fi
start=$(date +%s%N); kill -TERM "$sp" 2>/dev/null; wait "$sp" 2>/dev/null; rc=$?
ms=$(( ($(date +%s%N) - start) / 1000000 ))
chk "exits 0 on SIGTERM (not 143 = killed by signal)" "$rc" "0"
if [ "$ms" -lt 500 ]; then ok "exited in ${ms}ms — inside update.sh's wait window"; else bad "took ${ms}ms; update.sh only waits 5000ms"; fi
if [ ! -f "$pf" ]; then ok "pidfile released on exit"; else bad "pidfile left behind"; fi

echo
echo "=== 12. Only one sampler survives a concurrent start ==="
pids=""
for i in 1 2 3 4 5; do USER="$TU" bash "$REPO/bin/sampler.sh" & pids="$pids $!"; done
sleep 1.5
survivors=0; surv_pid=""
for p in $pids; do
  if kill -0 "$p" 2>/dev/null; then survivors=$((survivors+1)); surv_pid="$p"; fi
done
chk "5 simultaneous starts leave exactly 1 running" "$survivors" "1"
owner="$(cat "$pf" 2>/dev/null || echo none)"
chk "the pidfile names that survivor" "$owner" "$surv_pid"
kill -TERM "$owner" 2>/dev/null
sleep 0.4
for p in $pids; do kill -9 "$p" 2>/dev/null; done
rm -f "$pf" "/tmp/tmuxm-stats-${TU}"

echo
echo "=== 12b. The session's own sampler was not disturbed ==="
mine="/tmp/tmuxm-sampler-${USER}.pid"
if [ ! -f "$mine" ]; then
  ok "no sampler running for this session; nothing to disturb"
elif kill -0 "$(cat "$mine")" 2>/dev/null; then
  ok "live sampler PID $(cat "$mine") still running after the tests"
else
  bad "the tests killed this session's sampler"
fi

echo
echo "=== 12c. Timezone offset renders in the requested format ==="
chk "America/Sao_Paulo" "$(TZ=America/Sao_Paulo bash "$REPO/bin/render-tz.sh")" "-3 GMT"
chk "UTC"               "$(TZ=UTC               bash "$REPO/bin/render-tz.sh")" "0 GMT"
chk "Asia/Kolkata (half-hour offset)" "$(TZ=Asia/Kolkata bash "$REPO/bin/render-tz.sh")" "+5:30 GMT"
chk "Pacific/Chatham (45-min offset)" "$(TZ=Pacific/Chatham bash "$REPO/bin/render-tz.sh")" "+12:45 GMT"
# A leading 0 in the hour field must not be read as octal.
chk "Asia/Tokyo (+0900, octal trap)" "$(TZ=Asia/Tokyo bash "$REPO/bin/render-tz.sh")" "+9 GMT"

echo
echo "=== 13. tmux.conf defines no colours (single source of truth) ==="
hits="$(grep -nE '^[[:space:]]*set.*(status-style|status-left |status-right |window-status|pane-.*border|fg=#|bg=#)' "$REPO/tmux.conf" || true)"
if [ -z "$hits" ]; then ok "tmux.conf sets no coloured options"; else bad "tmux.conf still defines colours:"; printf '%s\n' "$hits"; fi

echo
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
