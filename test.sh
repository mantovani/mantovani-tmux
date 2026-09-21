#!/usr/bin/env bash
# Test suite for tmuxm. Runs install.sh against throwaway HOMEs and points
# TMUX_TMPDIR at a scratch dir so `tmux info` fails and the real server is never
# touched. Exits 0 when everything passes.
#
# This covers the shell that remains: the OKLCH colour engine, the generated
# block, and the binary's behaviour from the outside. The metric readers, the
# output formats and the state file are Rust unit tests, run by section 1.
#
#   ./test.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2' want '$3')"; fi; }

newhome() {
  local h; h="$(mktemp -d "${TMPDIR:-/tmp}/tmuxm-home.XXXXXX")"
  mkdir -p "$h/.tmux/plugins/tpm" "$h/tmuxtmp"   # pre-made TPM dir skips the clone
  printf '%s' "$h"
}
# install.sh builds the renderer, so cargo has to keep working while HOME is
# redirected. With rustup, `cargo` is a shim that finds its toolchain through
# HOME — override it and the build dies with "could not choose a version of
# cargo to run", which is invisible here because most callers discard output.
# A system cargo (/usr/bin/cargo) does not care, which is exactly why this
# passed locally and failed in CI.
REAL_HOME="$HOME"
run() {
  local h="$1"; shift
  HOME="$h" TMUX_TMPDIR="$h/tmuxtmp" \
    CARGO_HOME="${CARGO_HOME:-$REAL_HOME/.cargo}" \
    RUSTUP_HOME="${RUSTUP_HOME:-$REAL_HOME/.rustup}" \
    "$REPO/install.sh" "$@" 2>&1
}

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

echo "=== 1. The renderer builds, and its own suite passes ==="
# The metric readers, the output formats and the state file are Rust unit tests
# now: a parser that takes a &str needs no TMUXM_PROC_STAT to be testable, and
# there is no daemon left to drive. This section is the seam between the suites.
if ! command -v cargo >/dev/null 2>&1; then
  bad "cargo not found — the status bar cannot be built"
else
  if cargo test --quiet --manifest-path "$REPO/rust/Cargo.toml" >"/tmp/tmuxm-cargo.$$" 2>&1; then
    n="$(grep -oE '[0-9]+ passed' "/tmp/tmuxm-cargo.$$" | head -1 | cut -d' ' -f1)"
    ok "cargo test: ${n:-?} unit tests pass"
  else
    bad "cargo test failed:"; sed 's/^/      /' "/tmp/tmuxm-cargo.$$"
  fi
  rm -f "/tmp/tmuxm-cargo.$$"
  # Not shipped with a system rustc; CI has it. Absence must not fail the run.
  if cargo clippy --version >/dev/null 2>&1; then
    if cargo clippy --quiet --all-targets --manifest-path "$REPO/rust/Cargo.toml" -- -D warnings >/dev/null 2>&1
    then ok "clippy clean"; else bad "clippy found warnings"; fi
  else
    ok "clippy not installed here (CI runs it)"
  fi
fi

echo
echo "=== 2. The binary refuses to guess its colours ==="
BIN="$REPO/bin/tmuxm"
if [ ! -x "$BIN" ]; then
  bad "bin/tmuxm missing — run install.sh"
else
  if "$BIN" render        >/dev/null 2>&1; then bad "ran with no colours";     else ok "exits non-zero with no colour arguments"; fi
  if "$BIN" render ff69b4 >/dev/null 2>&1; then bad "ran with one colour";     else ok "exits non-zero with only one colour";    fi
  # Whatever reaches stdout is drawn in the bar, so usage must not go there.
  chk "usage goes to stderr, never into the bar" "$("$BIN" render 2>/dev/null)" ""
fi

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

echo "=== 11. The bar renders, and leaves nothing behind ==="
# The whole point of deleting the daemon: after a render, nothing is running.
if [ -x "$BIN" ]; then
  out="$("$BIN" render ff69b4 7a004b)"
  if printf '%s' "$out" | grep -q 'CPU'; then ok "render produced a bar"; else bad "render produced nothing: [$out]"; fi
  plain="$(printf '%s' "$out" | sed 's/#\[[^]]*\]//g')"
  gauges="$(printf '%s' "$plain" | grep -oE '[▁▂▃▄▅▆▇█]{4} +[0-9]+%' | wc -l | tr -d ' ')"
  if [ "$gauges" -ge 2 ]; then ok "$gauges fixed-width gauges drawn"; else bad "expected CPU and MEM at least, saw $gauges"; fi
  rates="$(printf '%s' "$plain" | grep -oE '[0-9 .]{5}[BKMGT]' | wc -l | tr -d ' ')"
  chk "two fixed-width throughput fields" "$rates" "2"
  # Deterministic: the property is that it terminates. Polling the process
  # table right after running it races the kernel reaping the child.
  if timeout 5 "$BIN" render ff69b4 7a004b >/dev/null 2>&1; then
    ok "render exits rather than looping"
  else
    bad "render did not exit within 5s — it is behaving like a daemon"
  fi
  if [ -e "/tmp/tmuxm-sampler-${USER}.pid" ]; then bad "a sampler pidfile still exists"; else ok "no sampler pidfile"; fi
fi

echo
echo "=== 12. The state file is what makes it stateless ==="
if [ -x "$BIN" ]; then
  T12="tmuxmtest$$"
  sf="/tmp/tmuxm-state-${T12}"
  rm -f "$sf"
  first="$(USER="$T12" "$BIN" render ff69b4 7a004b | sed 's/#\[[^]]*\]//g')"
  if [ -r "$sf" ]; then ok "first render created $sf"; else bad "no state file written"; fi
  chk "it records a monotonic timestamp" "$(awk '$1=="ts"{print ($2>0)?"yes":"no"}' "$sf")" "yes"
  # Nothing to diff against yet, so it must report 0 rather than invent a rate.
  chk "first render reports no traffic yet" "$(printf '%s' "$first" | grep -c '↓     0B ↑     0B')" "1"
  rm -f "$sf"
fi

echo
echo "=== 12c. Timezone offset renders in the requested format ==="
if [ -x "$BIN" ]; then
  chk "America/Sao_Paulo"              "$(TZ=America/Sao_Paulo "$BIN" tz)" "-3"
  chk "UTC"                            "$(TZ=UTC               "$BIN" tz)" "0"
  chk "Asia/Kolkata (half-hour offset)" "$(TZ=Asia/Kolkata      "$BIN" tz)" "+5:30"
  chk "Pacific/Chatham (45-min offset)" "$(TZ=Pacific/Chatham   "$BIN" tz)" "+12:45"
  chk "Asia/Tokyo (+0900, octal trap)"  "$(TZ=Asia/Tokyo        "$BIN" tz)" "+9"
fi

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

echo "=== 14. The generated bar calls the binary, not the old scripts ==="
H="$(newhome)"
if ! out14="$(run "$H" --color '#ff69b4')"; then
  bad "install.sh failed in a sandboxed HOME:"; printf '%s\n' "$out14" | sed 's/^/      /'
fi
sr="$(awk '/^set -g status-right /{sub(/^set -g status-right "/,""); sub(/"$/,""); print}' "$H/.tmux.local.conf")"
chk "one render call"            "$(printf '%s' "$sr" | grep -c 'tmuxm render ff69b4 7a004b)')" "1"
chk "one tz call"                "$(printf '%s' "$sr" | grep -c 'tmuxm tz)')" "1"
chk "no shell renderers survive" "$(printf '%s' "$sr" | grep -cE 'render-(bar|net|tz)\.sh')" "0"
# tmux still expands the hostname and the date itself; only metrics come from us.
chk "tmux keeps the hostname" "$(printf '%s' "$sr" | grep -c '@#h')" "1"
chk "tmux keeps the date"     "$(printf '%s' "$sr" | grep -c '%d/%m/%Y %H:%M')" "1"

echo
echo "=== 14b. The generated status-right is pinned, byte for byte ==="
want='#[bg=#000000,fg=#ff69b4]#(~/.tmuxm/bin/tmuxm render ff69b4 7a004b) #[fg=#7a004b]│#[fg=#ff69b4,bold] @#h #[fg=#7a004b]│#[fg=#ff69b4,bold] %d/%m/%Y %H:%M #(~/.tmuxm/bin/tmuxm tz) '
chk "status-right matches the pin" "$sr" "$want"

echo
echo "=== 14c. Colours survive tmux format expansion ==="
# tmux expands legacy shorthands inside #(...) before running the command, and
# '#F' is window flags — '#FBBF24' would reach the binary as '*BBF24'. Both
# arguments are bare hex for exactly this reason.
for c in '#ff69b4' '#FBBF24' '#FF0000' 'random'; do
  run "$H" --color "$c" >/dev/null
  s2="$(awk '/^set -g status-right /{sub(/^set -g status-right "/,""); sub(/"$/,""); print}' "$H/.tmux.local.conf")"
  args="$(printf '%s\n' "$s2" | grep -oE 'tmuxm render [0-9a-fA-F]{6} [0-9a-fA-F]{6}\)' | wc -l | tr -d ' ')"
  chk "$c: render call carries two clean hex args" "$args" "1"
  if command -v tmux >/dev/null && tmux display-message -p "$s2" 2>/dev/null | grep -q '\*'; then
    bad "$c: tmux mangled the status-right"
  else
    ok "$c: no shorthand corruption after tmux expansion"
  fi
done
rm -rf "$H"

echo
echo "=== 15. Nothing is spawned in the background, and no shell is left ==="
hits="$(grep -vE '^[[:space:]]*#' "$REPO/tmux.conf" | grep -nE 'run-shell|sampler' || true)"
if [ -z "$hits" ]; then ok "tmux.conf starts no background process"; else bad "tmux.conf still spawns something:"; printf '%s\n' "$hits"; fi
chk "no shell renderers left in the repo" "$(ls "$REPO"/bin/*.sh 2>/dev/null | wc -l | tr -d ' ')" "0"

echo
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
