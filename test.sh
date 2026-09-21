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

# The same detection install.sh uses, so tests expect what this machine actually
# produces instead of assuming a GPU either way.
. "$REPO/bin/gpu.sh"

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
  # -o, not -c: the calls all live on the same line, so -c would only ever say 1.
  args="$(printf '%s\n' "$sr" | grep -o "render-bar\.sh [a-z]* [0-9a-fA-F]\{6\})" | wc -l | tr -d ' ')"
  # cpu + mem always; gpu + vram only where this machine has a readable GPU, so
  # the expectation has to follow the same detection the installer used.
  want=2; gpu_present && want=4
  chk "$c: every render-bar call carries a clean hex arg" "$args" "$want"
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
chk "America/Sao_Paulo" "$(TZ=America/Sao_Paulo bash "$REPO/bin/render-tz.sh")" "-3"
chk "UTC"               "$(TZ=UTC               bash "$REPO/bin/render-tz.sh")" "0"
chk "Asia/Kolkata (half-hour offset)" "$(TZ=Asia/Kolkata bash "$REPO/bin/render-tz.sh")" "+5:30"
chk "Pacific/Chatham (45-min offset)" "$(TZ=Pacific/Chatham bash "$REPO/bin/render-tz.sh")" "+12:45"
# A leading 0 in the hour field must not be read as octal.
chk "Asia/Tokyo (+0900, octal trap)" "$(TZ=Asia/Tokyo bash "$REPO/bin/render-tz.sh")" "+9"

echo
echo "=== 13. tmux.conf defines no colours (single source of truth) ==="
hits="$(grep -nE '^[[:space:]]*set.*(status-style|status-left |status-right |window-status|pane-.*border|fg=#|bg=#)' "$REPO/tmux.conf" || true)"
if [ -z "$hits" ]; then ok "tmux.conf sets no coloured options"; else bad "tmux.conf still defines colours:"; printf '%s\n' "$hits"; fi

echo
echo "=== 13b. Truecolor only where the terminal actually supports it ==="
# The machine colour is a 24-bit value, so the RGB feature is what makes it
# reproduce exactly — and granting it where it does not exist renders the colour
# wrong rather than better. Apple Terminal is the one terminal that reports
# xterm-256color while having no 24-bit support, so it is the one that must NOT
# get it. Everything else must, including ssh, which forwards TERM but not the
# COLORTERM that tmux would otherwise detect.
tf_rgb() {   # tf_rgb <TERM_PROGRAM> <tag>
  local h d sock feat over
  # Throwaway HOME so the real tmux.conf can be run rather than a copy of its
  # lines: ~/.tmuxm, ~/.tmux/plugins and ~/.tmux.local.conf are all absent
  # there, so the sampler, TPM and the local colour block never load.
  h="$(newhome)"
  # -S with a short path, not -L: the default socket lives at
  # TMUX_TMPDIR/tmux-UID/name, and under macOS's /var/folders TMPDIR that
  # overruns sun_path's ~104 bytes — the server then never starts and every
  # query below reports failure instead of an answer. Also keeps the real
  # server out of reach without depending on TMUX_TMPDIR at all.
  d="$(mktemp -d /tmp/tmuxm-sock.XXXXXX)"; sock="$d/s"
  HOME="$h" TERM_PROGRAM="$1" \
    tmux -S "$sock" -f "$REPO/tmux.conf" new-session -d -x 80 -y 24 sleep 30 2>/dev/null
  feat="$(tmux -S "$sock" show -gv terminal-features 2>/dev/null | tr '\n' ' ')"
  over="$(tmux -S "$sock" show -gv terminal-overrides 2>/dev/null | tr '\n' ' ')"
  tmux -S "$sock" kill-server 2>/dev/null
  rm -rf "$h" "$d"
  # The effect, not the mechanism: tmux grants 24-bit colour through either the
  # RGB feature or a Tc override, so matching only one would go green on a
  # config that still forced the other.
  case "$feat$over" in
    *xterm*RGB*|*xterm*:Tc*) echo yes ;;
    *)                       echo no  ;;
  esac
}
chk "iTerm2 gets RGB"                "$(tf_rgb iTerm.app      a)" "yes"
chk "Apple Terminal does not"        "$(tf_rgb Apple_Terminal b)" "no"
chk "ssh (no TERM_PROGRAM) gets RGB" "$(tf_rgb ''             c)" "yes"

echo
echo "=== 14. GPU segments appear only where a GPU is detected ==="
# install.sh decides ONCE, at install time, whether the bar carries GPU segments.
# Both answers are forced with a stub on PATH and an empty sysfs tree, so this
# says the same thing on a box with a GPU and on one without.
STUBS="$(mktemp -d "${TMPDIR:-/tmp}/tmuxm-stub.XXXXXX")"
mkdir -p "$STUBS/yes" "$STUBS/no" "$STUBS/sysfs"
printf '#!/bin/sh\necho "42, 2048, 8192"\n' > "$STUBS/yes/nvidia-smi"
printf '#!/bin/sh\nexit 6\n'                > "$STUBS/no/nvidia-smi"
chmod +x "$STUBS/yes/nvidia-smi" "$STUBS/no/nvidia-smi"

# An empty sysfs tree means no device can be reported as runtime-suspended, so
# the answer always comes from the stub rather than from the shortcut that
# deliberately avoids waking a parked dGPU.
srline() {  # srline <stubdir> <home>
  # TMUXM_OS pins the platform: gpu_sample returns early on anything but Linux,
  # so without it these four assertions could only ever run on Linux and would
  # silently report "no GPU" everywhere else.
  TMUXM_OS=Linux NVIDIA_SYSFS_DIR="$STUBS/sysfs" PATH="$1:$PATH" HOME="$2" TMUX_TMPDIR="$2/tmuxtmp" \
    "$REPO/install.sh" --color '#ff69b4' >/dev/null 2>&1
  awk '/^set -g status-right /{sub(/^set -g status-right "/,""); sub(/"$/,""); print}' "$2/.tmux.local.conf"
}

H="$(newhome)"; with_gpu="$(srline "$STUBS/yes" "$H")"; rm -rf "$H"
H="$(newhome)"; no_gpu="$(srline "$STUBS/no"  "$H")"; rm -rf "$H"

chk "GPU present: gpu bar installed"  "$(printf '%s\n' "$with_gpu" | grep -c 'render-bar\.sh gpu ff69b4')"  "1"
chk "GPU present: vram bar installed" "$(printf '%s\n' "$with_gpu" | grep -c 'render-bar\.sh vram ff69b4')" "1"
chk "GPU present: labelled GPU"       "$(printf '%s\n' "$with_gpu" | grep -c ' GPU ')"                     "1"
chk "GPU present: labelled VRAM"      "$(printf '%s\n' "$with_gpu" | grep -c ' VRAM ')"                    "1"
chk "no GPU: no gpu bar"              "$(printf '%s\n' "$no_gpu"   | grep -c 'render-bar\.sh gpu ')"       "0"
chk "no GPU: no vram bar"             "$(printf '%s\n' "$no_gpu"   | grep -c 'render-bar\.sh vram ')"      "0"
chk "no GPU: no GPU/VRAM label"       "$(printf '%s\n' "$no_gpu"   | grep -Ec ' (GPU|VRAM) ')"             "0"

echo
echo "=== 14b. A GPU-less machine still generates exactly today's bar ==="
# The whole point of deciding at install time. Not "similar", not "with a flat 0%
# segment" — the identical string, pinned here so it cannot drift by accident.
want='#[bg=#000000,fg=#ff69b4] CPU #(bash ~/.tmuxm/bin/render-bar.sh cpu ff69b4) #[fg=#7a004b]│#[fg=#ff69b4] MEM #(bash ~/.tmuxm/bin/render-bar.sh mem ff69b4) #[fg=#7a004b]│#[fg=#ff69b4] ↓ #(bash ~/.tmuxm/bin/render-net.sh in) ↑ #(bash ~/.tmuxm/bin/render-net.sh out) #[fg=#7a004b]│#[fg=#ff69b4,bold] @#h #[fg=#7a004b]│#[fg=#ff69b4,bold] %d/%m/%Y %H:%M #(bash ~/.tmuxm/bin/render-tz.sh) '
chk "byte-for-byte the pre-GPU status-right" "$no_gpu" "$want"
rm -rf "$STUBS"

echo
echo "=== 14c. render-bar reads gpu/vram, and tolerates their absence ==="
# gpu and vram are optional keys: present on a GPU machine, missing everywhere
# else. A renderer must not care which.
cp "$CACHE" "$CACHE.testbak" 2>/dev/null
printf 'cpu 7\nmem 55\ngpu 42\nvram 25\nnet_in 0\nnet_out 0\n' > "$CACHE"
chk "gpu renders its own key"  "$(bash "$REPO/bin/render-bar.sh" gpu  aabbcc | sed 's/^#\[fg=[^]]*\]//; s/#\[fg=default,nobold\]$//')" "█▆▁▁  42%"
chk "vram renders its own key" "$(bash "$REPO/bin/render-bar.sh" vram aabbcc | sed 's/^#\[fg=[^]]*\]//; s/#\[fg=default,nobold\]$//')" "█▁▁▁  25%"
# Same cache a machine with no GPU writes: the keys are absent, not zeroed.
printf 'cpu 7\nmem 55\nnet_in 0\nnet_out 0\n' > "$CACHE"
chk "missing gpu key degrades to 0%"  "$(bash "$REPO/bin/render-bar.sh" gpu  aabbcc | sed 's/^#\[fg=[^]]*\]//; s/#\[fg=default,nobold\]$//')" "▁▁▁▁   0%"
chk "missing vram key degrades to 0%" "$(bash "$REPO/bin/render-bar.sh" vram aabbcc | sed 's/^#\[fg=[^]]*\]//; s/#\[fg=default,nobold\]$//')" "▁▁▁▁   0%"
[ -f "$CACHE.testbak" ] && mv "$CACHE.testbak" "$CACHE"

echo
echo "=== 14d. A parked dGPU is reported idle, not woken ==="
# nvidia-smi wakes a suspended card. Polling it every 2 s would hold a Max-Q
# laptop dGPU awake for the whole session, so the suspend check has to come first
# — and the only way to prove it does is a stub that shouts when it runs.
FAKE="$(mktemp -d "${TMPDIR:-/tmp}/tmuxm-fakesys.XXXXXX")"
mkdir -p "$FAKE/dev/0000:01:00.0/power" "$FAKE/bin"
printf '0x10de\n'    > "$FAKE/dev/0000:01:00.0/vendor"
printf '0x030000\n'  > "$FAKE/dev/0000:01:00.0/class"
printf '#!/bin/sh\necho WOKE-THE-GPU >&2\necho "99, 8000, 8188"\n' > "$FAKE/bin/nvidia-smi"
chmod +x "$FAKE/bin/nvidia-smi"

printf 'suspended\n' > "$FAKE/dev/0000:01:00.0/power/runtime_status"
got="$(TMUXM_OS=Linux NVIDIA_SYSFS_DIR="$FAKE/dev" PATH="$FAKE/bin:$PATH" bash -c '. "'"$REPO"'/bin/gpu.sh"; gpu_sample' 2>"$FAKE/err")"
chk "suspended: reports idle"        "$got"              "0 0"
chk "suspended: nvidia-smi not run"  "$(cat "$FAKE/err")" ""

printf 'active\n' > "$FAKE/dev/0000:01:00.0/power/runtime_status"
got="$(TMUXM_OS=Linux NVIDIA_SYSFS_DIR="$FAKE/dev" PATH="$FAKE/bin:$PATH" bash -c '. "'"$REPO"'/bin/gpu.sh"; gpu_sample' 2>/dev/null)"
chk "active: polled, util + pooled vram" "$got" "99 97"
rm -rf "$FAKE"

echo
echo "=== 14e. sampler.sh can be sourced without becoming a sampler ==="
# Sections 15-18 drive the readers by sourcing the file. If sourcing ever starts
# the loop they do not fail — they HANG, inside a command substitution, which is
# the one outcome a suite must never produce. So the boundary is proven here,
# with a deadline, before anything depends on it.
TUB="tmuxmsrc$$"
USER="$TUB" bash -c '. "'"$REPO"'/bin/sampler.sh"' & sp=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$sp" 2>/dev/null || break; sleep 0.3; done
if kill -0 "$sp" 2>/dev/null; then
  bad "sourcing sampler.sh entered the loop"; kill -9 "$sp" 2>/dev/null
else
  ok "sourcing returns at the library boundary"
fi
wait "$sp" 2>/dev/null
if [ ! -f "/tmp/tmuxm-sampler-${TUB}.pid" ]; then ok "sourcing claimed no pidfile"
else bad "sourcing claimed a pidfile"; fi
rm -f "/tmp/tmuxm-sampler-${TUB}.pid" "/tmp/tmuxm-stats-${TUB}"

echo
echo "=== 14f. The sampler writes no key the bar cannot render ==="
# bat was sampled every interval and written here for a segment that was never
# generated. A key nothing reads cannot be seen to rot — which is exactly how
# the down-interface bug in section 15 shipped invisibly. This also proves the
# deadline loop still completes an iteration and writes within a bounded time.
TUK="tmuxmkey$$"; kc="/tmp/tmuxm-stats-${TUK}"; kp="/tmp/tmuxm-sampler-${TUK}.pid"
rm -f "$kc" "$kp"
USER="$TUK" bash "$REPO/bin/sampler.sh" & sp=$!
for _ in $(seq 1 40); do [ -s "$kc" ] && break; sleep 0.25; done
kill -TERM "$sp" 2>/dev/null; wait "$sp" 2>/dev/null
if [ -s "$kc" ]; then
  chk "every key has a renderer" \
    "$(awk '{print $1}' "$kc" | grep -vcE '^(cpu|mem|gpu|vram|net_in|net_out)$')" "0"
else
  bad "sampler wrote no cache within 10s"
fi
rm -f "$kc" "$kp"

echo
echo "=== 15. Interface selection survives an interface going down ==="
# netstat suffixes '*' to an interface that is not UP, and the skip-list is
# anchored on '$' — so the moment a skipped interface goes down it stops being
# skipped and its CUMULATIVE counter joins the sum. The next delta then reports
# an entire session's traffic as one interval's throughput.
#
# awdl0 is the case that actually bites: AirDrop cycles its radio up and down
# routinely, and it carries a link-layer address, so its $7 is a real byte
# counter (13 MB on the machine this was written on). A down tunnel is the
# milder variant — utun rows have no address, so every field after Network
# shifts left and $7/$10 land on Opkts/Coll; still wrong, just smaller.
#
# Both snapshots hold identical counters for everything except en0, which grows
# by 100 bytes. 100 is therefore the only correct answer in either state.
#
# Stubbing netstat on PATH is the technique section 14d uses for nvidia-smi;
# Sourcing stops at sampler.sh's library boundary, so the readers can be
# driven without claiming the pidfile or entering the loop.
NS="$(mktemp -d "${TMPDIR:-/tmp}/tmuxm-ns.XXXXXX")"
mkdir -p "$NS/bin"
printf '#!/bin/sh\ncat "$NETSTAT_FIXTURE"\n' > "$NS/bin/netstat"
chmod +x "$NS/bin/netstat"

cat > "$NS/up" <<'EOS'
Name  Mtu   Network       Address            Ipkts Ierrs     Ibytes     Opkts Oerrs     Obytes  Coll
en0   1500  <Link#1>      aa:bb:cc:dd:ee:00  1000  0         1000000000 500   0         2000000 0
en5   1500  <Link#9>      cc:dd:ee:ff:00:11  50    0         400000     25    0         100000  0
awdl0 1484  <Link#13>     bb:cc:dd:ee:ff:00  300   0         12996610   100   0         9650603 0
utun5 1380  <Link#12>                        400   0         500000000  200   0         7000    0
EOS
# Same counters; en0 +100, and three interfaces now marked down. en5 is the row
# that discriminates: it is a real NIC, so going down must NOT remove it from
# the sum. Without it this section passes just as happily under "skip every
# marked row", which has the same bug with the sign reversed — a NIC that came
# back up would rejoin carrying its whole cumulative counter.
sed -e 's/1000000000/1000000100/' \
    -e 's/^awdl0 /awdl0* /' \
    -e 's/^utun5 /utun5* /' \
    -e 's/^en5   /en5*  /'  "$NS/up" > "$NS/down"

netsum() { NETSTAT_FIXTURE="$1" PATH="$NS/bin:$PATH" TMUXM_OS=Darwin \
  bash -c '. "'"$REPO"'/bin/sampler.sh"; read_net_bytes'; }
up="$(netsum "$NS/up")"; down="$(netsum "$NS/down")"
chk "up: overlays excluded"        "$up"   "1000400000 2100000"
chk "down: NIC kept, overlays not" "$down" "1000400100 2100000"
chk "no phantom spike on the flip" "$(( ${down%% *} - ${up%% *} ))" "100"
rm -rf "$NS"

echo "=== 15b. Linux throughput reads bytes, on physical interfaces only ==="
# /proc/net/dev right-pads short names, so the columns are only positional once
# the name's colon is turned into a space. Long and short names are both present
# here because an earlier bug shifted every column for exactly one of the two.
LX="$(mktemp -d "${TMPDIR:-/tmp}/tmuxm-lx.XXXXXX")"
cat > "$LX/netdev" <<'EOS'
Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
    lo:  232248    1000    0    0    0     0          0         0   232248    1000    0    0    0     0       0          0
  wlo1: 5000000    4000    0    0    0     0          0         0  1000000    2000    0    0    0     0       0          0
enp1s0: 7000000    6000    0    0    0     0          0         0  3000000    3000    0    0    0     0       0          0
docker0: 900000     800    0    0    0     0          0         0   400000     500    0    0    0     0       0          0
EOS
# Only wlo1 and enp1s0 get a device symlink, which is what marks real hardware.
mkdir -p "$LX/sys/wlo1/device" "$LX/sys/enp1s0/device" "$LX/sys/docker0" "$LX/sys/lo"
lxsum() { TMUXM_OS=Linux TMUXM_PROC_NET_DEV="$LX/netdev" \
  TMUXM_SYS_CLASS_NET="$1" bash -c '. "'"$REPO"'/bin/sampler.sh"; read_net_bytes'; }
chk "physical only, bytes not packets" "$(lxsum "$LX/sys")"   "12000000 4000000"
# An empty tree means no hardware exists — a container, where eth0 is itself a
# veth. Nothing to double-count there, so everything but lo is summed.
mkdir -p "$LX/empty"
chk "container fallback sums non-lo"   "$(lxsum "$LX/empty")" "12900000 4400000"
rm -rf "$LX"

echo
echo "=== 16. Memory is a fraction of real RAM ==="
# The six vm_stat counters do not add up to physical RAM — roughly 0.6 GB of a
# 16 GB machine sits outside them — so using their sum as the denominator
# overstates every reading. hw.memsize is the honest total.
VM="$(mktemp -d "${TMPDIR:-/tmp}/tmuxm-vm.XXXXXX")"; mkdir -p "$VM/bin"
cat > "$VM/bin/vm_stat" <<'EOS'
#!/bin/sh
cat <<'EOF'
Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                                   10000.
Pages active:                                100000.
Pages inactive:                               40000.
Pages speculative:                                0.
Pages throttled:                                  0.
Pages wired down:                             50000.
Pages occupied by compressor:                 50000.
EOF
EOS
printf '#!/bin/sh\n[ "$2" = "hw.memsize" ] && echo 8589934592 || exit 1\n' > "$VM/bin/sysctl"
chmod +x "$VM/bin/vm_stat" "$VM/bin/sysctl"
# used = active+wired+compressed = 200000 pages * 16384 = 3276800000 bytes
# against hw.memsize 8589934592 -> 38%. The six-counter sum would say 80%.
got="$(PATH="$VM/bin:$PATH" TMUXM_OS=Darwin \
  bash -c '. "'"$REPO"'/bin/sampler.sh"; read_mem')"
chk "used measured against hw.memsize" "$got" "38"
rm -rf "$VM"

echo
echo "=== 17. render-bar normalises whatever the cache holds ==="
# Two defects met here. The blocks were clamped and the number was not, so a
# cache holding 150 drew four full blocks beside the caption "150%" — a bar
# disagreeing with itself. And validating in bash is not enough: under `set -u`
# a bare word in $(( )) is a fatal "abc: unbound variable" printed into the
# status bar, "08" aborts just as hard because `test -gt` reads it as a bad
# octal literal, and "010" would quietly mean 8.
#
# render-bar.sh derives its cache path from $USER, so overriding that gives this
# section its own file — otherwise it races the sampler running this session,
# which rewrites the real cache every interval.
T17="tmuxmbar$$"; c17="/tmp/tmuxm-stats-${T17}"
rb() { printf 'cpu %s\n' "$1" > "$c17"
       USER="$T17" bash "$REPO/bin/render-bar.sh" cpu ff7361 2>"$c17.err" \
         | sed 's/#\[[^]]*\]//g'; }
chk "in range is untouched"       "$(rb 50)"   "██▁▁  50%"
chk "above 100 clamps"            "$(rb 150)"  "████ 100%"
chk "negative degrades"           "$(rb -5)"   "▁▁▁▁   0%"
chk "non-numeric degrades"        "$(rb abc)"  "▁▁▁▁   0%"
chk "leading zero is not octal"   "$(rb 010)"  "▄▁▁▁  10%"
chk "08 does not abort"           "$(rb 08)"   "▃▁▁▁   8%"
chk "overflow clamps"             "$(rb 99999999999999999999)" "████ 100%"
chk "nothing written to stderr"   "$(cat "$c17.err")" ""
: > "$c17"
chk "missing key degrades"        "$(USER="$T17" bash "$REPO/bin/render-bar.sh" cpu ff7361 | sed 's/#\[[^]]*\]//g')" "▁▁▁▁   0%"
rm -f "$c17" "$c17.err"

echo "=== 18. Linux CPU counts stolen time as unavailable, not idle ==="
# Steal is time the hypervisor gave to another guest. Leaving it out of the
# total makes a contended VM look quiet: the same two snapshots read 10% with
# it excluded and 25% with it counted.
ST="$(mktemp -d "${TMPDIR:-/tmp}/tmuxm-st.XXXXXX")"
printf 'cpu  100 0 0 900 0 0 0 0 0 0\n'    > "$ST/a"
printf 'cpu  200 0 0 1800 0 0 0 200 0 0\n' > "$ST/b"
got="$(TMUXM_OS=Linux bash -c '
  . "'"$REPO"'/bin/sampler.sh"
  TMUXM_PROC_STAT="'"$ST"'/a" read_cpu
  TMUXM_PROC_STAT="'"$ST"'/b" read_cpu
  echo "$CPU"')"
chk "steal counted toward busy" "$got" "25"
rm -rf "$ST"

echo
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
