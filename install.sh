#!/usr/bin/env bash
# Idempotent installer for the tmuxm config.
# Links ~/.tmuxm → this clone, symlinks ~/.tmux.conf, clones TPM if missing,
# sources the config, and writes this machine's colour.
#
# One colour defines the whole bar. Every other shade is derived from it; the
# only fixed colour in the theme is the black the badge and metrics sit on.
#
# Usage:
#   install.sh                     install / re-install; generates a random
#                                  colour the FIRST time only
#   install.sh --color '#3366cc'   any 24-bit colour
#   install.sh --color random      generate a new random one
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

LINK="$HOME/.tmuxm"
TARGET="$HOME/.tmux.conf"
SOURCE="$LINK/tmux.conf"
LOCAL_CONF="$HOME/.tmux.local.conf"
TPM_DIR="$HOME/.tmux/plugins/tpm"

BEGIN_MARK='# >>> tmuxm colour (managed by install.sh --color) >>>'
END_MARK='# <<< tmuxm colour <<<'

COLOR_ARG=""
COLOR_CURRENT_ARG=""
COLOR_BASE=""
AUTO_RANDOM=0

# ── Colour engine ─────────────────────────────────────────────
# Works in OKLCH because it is perceptually uniform: two colours with the same
# L look equally bright at every hue. That is the property that makes a random
# hue safe — legibility against the black end-caps holds for all 360 of them,
# which is not true in HSL/HSV where a yellow and a blue at the same "L" differ
# wildly in apparent brightness.
#
# Portable awk only — macOS ships BWK awk, which has no strtonum() or gensub(),
# so hex parsing is hand-rolled.
OKLCH_AWK=$(cat <<'AWKEOF'
BEGIN {
  PI = atan2(0, -1)

  # Legibility floor, measured rather than guessed: sweeping every hue at max
  # chroma, L=0.72 is the lowest lightness where the worst hue (violet, ~327°)
  # still clears WCAG AAA 7:1 against black. AA 4.5:1 would allow 0.61.
  MIN_L = 0.72
  MAX_L = 0.90   # above this, hues wash toward white and stop being telling apart

  DIM_L = 0.38   # pane borders + separators — the only shade that is not the
                 # accent itself, because chrome must not compete with content

  if (MODE == "random") { print random_color(); exit }
  if (MODE == "derive") { derive(ACCENT); emit();  exit }
}

function hexval(s,   i, c, v, d) {
  v = 0
  for (i = 1; i <= length(s); i++) {
    c = tolower(substr(s, i, 1))
    d = index("0123456789abcdef", c) - 1
    if (d < 0) d = 0
    v = v * 16 + d
  }
  return v
}
function clamp01(v) { if (v < 0) v = 0; if (v > 1) v = 1; return v }
function lin(c)   { c = c / 255.0; return (c <= 0.04045) ? c / 12.92 : ((c + 0.055) / 1.055) ^ 2.4 }
function unlin(c) { c = clamp01(c); return (c <= 0.0031308) ? c * 12.92 : 1.055 * (c ^ (1.0 / 2.4)) - 0.055 }
function cbrt(x)  { return (x < 0) ? -((-x) ^ (1.0 / 3.0)) : x ^ (1.0 / 3.0) }
function to255(v) { v = int(v * 255 + 0.5); if (v < 0) v = 0; if (v > 255) v = 255; return v }

# "#rrggbb" -> globals OK_L, OK_C, OK_H
function to_oklch(hex,   h, r, g, b, l, m, s, A, B) {
  h = hex; sub(/^#/, "", h)
  r = lin(hexval(substr(h, 1, 2)))
  g = lin(hexval(substr(h, 3, 2)))
  b = lin(hexval(substr(h, 5, 2)))
  l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
  m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
  s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
  OK_L =  0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
  A    =  1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
  B    =  0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
  OK_C = sqrt(A * A + B * B)
  OK_H = atan2(B, A) * 180.0 / PI
  if (OK_H < 0) OK_H += 360
}

# L,C,H -> globals RGB_R/G/B (linear). Returns 1 when inside sRGB.
function to_linear(L, C, H,   a, b, l_, m_, s_, l, m, s) {
  a = C * cos(H * PI / 180.0)
  b = C * sin(H * PI / 180.0)
  l_ = L + 0.3963377774 * a + 0.2158037573 * b
  m_ = L - 0.1055613458 * a - 0.0638541728 * b
  s_ = L - 0.0894841775 * a - 1.2914855480 * b
  l = l_ * l_ * l_; m = m_ * m_ * m_; s = s_ * s_ * s_
  RGB_R =  4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
  RGB_G = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
  RGB_B = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
  return (RGB_R >= -0.0001 && RGB_R <= 1.0001 && \
          RGB_G >= -0.0001 && RGB_G <= 1.0001 && \
          RGB_B >= -0.0001 && RGB_B <= 1.0001)
}

# Largest in-gamut chroma at this L,H. Reducing chroma keeps hue and lightness
# exact; clipping each channel instead would visibly shift the hue.
function max_chroma(L, H,   lo, hi, mid, i) {
  lo = 0; hi = 0.45
  for (i = 0; i < 24; i++) {
    mid = (lo + hi) / 2.0
    if (to_linear(L, mid, H)) lo = mid; else hi = mid
  }
  return lo
}

function to_hex(L, C, H,   c) {
  c = C
  if (!to_linear(L, c, H)) c = max_chroma(L, H)
  to_linear(L, c, H)
  return sprintf("#%02x%02x%02x", to255(unlin(RGB_R)), to255(unlin(RGB_G)), to255(unlin(RGB_B)))
}

# Randomness comes from bash ($RANDOM, portable to bash 3.2) as three integers,
# so awk stays deterministic and testable. Hue is uniform over the full circle;
# lightness stays inside the measured legible band; chroma is a fraction of the
# most this hue can hold. ~1.5M reachable colours.
function random_color(   L, C) {
  L = MIN_L + (MAX_L - MIN_L) * (RL / 100.0)
  C = max_chroma(L, RH) * (RC / 100.0)
  return to_hex(L, C, RH)
}

# WCAG relative luminance, and the text colour that contrasts best on top of a
# given background. Same definition the legibility floor above was measured
# with, so there is one notion of "readable" in this file and not two.
function rel_lum(hex,   h, r, g, b) {
  h = hex; sub(/^#/, "", h)
  r = lin(hexval(substr(h,1,2))); g = lin(hexval(substr(h,3,2))); b = lin(hexval(substr(h,5,2)))
  return 0.2126*r + 0.7152*g + 0.0722*b
}
function best_fg(hex,   y) {
  y = rel_lum(hex)
  return (((y + 0.05) / 0.05) >= (1.05 / (y + 0.05))) ? "black" : "white"
}

function derive(base,   L, C, H, al) {
  to_oklch(base); L = OK_L; C = OK_C; H = OK_H

  BASE_FG = best_fg(base)

  # Active window: same hue, stepped away in lightness so it separates from the
  # bar — darker when the bar is light, lighter when the bar is dark. Chroma is
  # re-solved at the new lightness so the shade stays as vivid as sRGB allows,
  # which a straight RGB scale-down cannot do (it desaturates).
  al = (L > 0.55) ? L - 0.15 : L + 0.18
  ACTIVE = to_hex(al, max_chroma(al, H), H)
  ACTIVE_FG = best_fg(ACTIVE)

  # A colour dark enough to hold white text on the bar would be invisible on the
  # black end-caps, so the accent is lifted to the legibility floor. Anything
  # already above it is used exactly as given.
  if (L < MIN_L) { L = MIN_L; C = max_chroma(L, H) }
  ACCENT = to_hex(L, C, H)

  DIM = to_hex(DIM_L, C, H)
}

function emit() {
  printf "THEME_ACCENT=%s\n",    ACCENT
  printf "THEME_DIM=%s\n",       DIM
  printf "THEME_ACTIVE=%s\n",    ACTIVE
  printf "THEME_BASE_FG=%s\n",   BASE_FG
  printf "THEME_ACTIVE_FG=%s\n", ACTIVE_FG
}
AWKEOF
)

usage() {
  cat <<'EOF'
Usage: install.sh [--color <#rrggbb|random>] [--color-current <#rrggbb>] [-h]

With no arguments this installs/re-installs and, only if this machine has no
colour yet, generates a random one. Re-running never changes an existing
colour — use --color random for that.
EOF
}

# Uniform hue over the whole circle, lightness inside the legible band, chroma a
# fraction of this hue's maximum.
random_color() {
  awk -v MODE=random \
      -v RH="$(( RANDOM % 360 ))" \
      -v RL="$(( RANDOM % 101 ))" \
      -v RC="$(( 60 + RANDOM % 41 ))" \
      "$OKLCH_AWK" </dev/null
}

# Sets THEME_ACCENT / THEME_DIM / THEME_ACTIVE / THEME_BASE_FG / THEME_ACTIVE_FG.
derive_theme() {
  local out
  out="$(awk -v MODE=derive -v ACCENT="$1" "$OKLCH_AWK" </dev/null)"
  [ -n "$out" ] || { echo "[!!] Could not derive a theme from '$1'" >&2; exit 1; }
  eval "$out"
}

# "#rrggbb" or "rrggbb" -> "#rrggbb"; exits on anything else.
normalize_hex() {
  local h="${1#\#}"
  case "$h" in
    [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]) ;;
    *) echo "[!!] Not a 6-digit hex colour: '$1'" >&2; exit 1 ;;
  esac
  echo "#$h"
}

resolve_color() {
  local want="$1"
  if [ "$want" = "random" ]; then
    want="$(random_color)"
    AUTO_RANDOM=1
  fi
  COLOR_BASE="$(normalize_hex "$want")"
}

block_exists() {
  [ -r "$LOCAL_CONF" ] && grep -qF "$BEGIN_MARK" "$LOCAL_CONF"
}

# The whole theme. tmux.conf deliberately sets none of these — this block is the
# single place the bar's colours are defined.
write_color_block() {
  local blockfile tmp ts rb rn accent_a gpu_seg
  derive_theme "$COLOR_BASE"

  # --color-current overrides only the active shade; its text colour is still
  # solved rather than assumed.
  if [ -n "$COLOR_CURRENT_ARG" ]; then
    THEME_ACTIVE="$(normalize_hex "$COLOR_CURRENT_ARG")"
    THEME_ACTIVE_FG="$(awk -v MODE=derive -v ACCENT="$THEME_ACTIVE" "$OKLCH_AWK" </dev/null \
                       | awk -F= '$1=="THEME_BASE_FG"{print $2}')"
  fi

  # One process draws every metric; a second prints the UTC offset. This used
  # to be seven #() calls, each a bash that forked an awk.
  rm='#(~/.tmuxm/bin/tmuxm render'
  rz='#(~/.tmuxm/bin/tmuxm tz)'

  # Bare hex, no '#'. tmux expands its legacy format shorthands inside #(...)
  # before handing the command to the shell, and '#F' is one of them (window
  # flags) — '#FBBF24' would arrive at render-bar.sh as '*BBF24'. Lowercase '#f'
  # happens to be safe, which makes this fail for only some colours.
  accent_a="${THEME_ACCENT#\#}"
  dim_a="${THEME_DIM#\#}"

  # GPU presence is no longer decided here. The binary draws the whole metric
  # block, so it can tell per refresh whether this machine has a readable GPU —
  # and a machine that gains one no longer needs install.sh re-run to see it.

  blockfile="$(mktemp "${TMPDIR:-/tmp}/tmuxm-block.XXXXXX")"
  trap 'rm -f "$blockfile"' RETURN
  cat > "$blockfile" <<EOF
$BEGIN_MARK
# Machine colour: $COLOR_BASE — regenerate with: ~/.tmuxm/install.sh --color '$COLOR_BASE'
# Derived: accent $THEME_ACCENT, dim $THEME_DIM, active $THEME_ACTIVE
set -g status-style "bg=$COLOR_BASE,fg=$THEME_BASE_FG"
set -g window-status-style "bg=$COLOR_BASE,fg=$THEME_BASE_FG"
set -g window-status-current-style "bg=$THEME_ACTIVE,fg=$THEME_ACTIVE_FG,bold"
set -g pane-border-style "fg=$THEME_DIM"
set -g pane-active-border-style "fg=$THEME_ACCENT"
set -g status-left "#[bg=#000000,fg=$THEME_ACCENT,bold] 🧙 AI Wizard 🔮 #[bg=#000000,fg=white] "
set -g status-right "#[bg=#000000,fg=$THEME_ACCENT]$rm $accent_a $dim_a) #[fg=$THEME_DIM]│#[fg=$THEME_ACCENT,bold] @#h #[fg=$THEME_DIM]│#[fg=$THEME_ACCENT,bold] %d/%m/%Y %H:%M $rz "
$END_MARK
EOF

  if [ ! -e "$LOCAL_CONF" ] && [ ! -L "$LOCAL_CONF" ]; then
    cat "$blockfile" > "$LOCAL_CONF"
    echo "[OK] Created $LOCAL_CONF"
  elif grep -qF "$BEGIN_MARK" "$LOCAL_CONF"; then
    # Rewrite only the managed block; every other line is preserved verbatim.
    tmp="$LOCAL_CONF.tmuxm.$$"
    awk -v b="$BEGIN_MARK" -v e="$END_MARK" -v bf="$blockfile" '
      index($0, b) == 1 {
        while ((getline line < bf) > 0) print line
        close(bf); skip = 1; next
      }
      skip && index($0, e) == 1 { skip = 0; next }
      !skip { print }
    ' "$LOCAL_CONF" > "$tmp"
    mv "$tmp" "$LOCAL_CONF"
    echo "[OK] Updated managed block in $LOCAL_CONF"
  else
    ts="$(date +%Y%m%d-%H%M%S)"
    cp "$LOCAL_CONF" "$LOCAL_CONF.bak.$ts"
    printf '\n' >> "$LOCAL_CONF"
    cat "$blockfile" >> "$LOCAL_CONF"
    echo "[OK] Backed up $LOCAL_CONF → $LOCAL_CONF.bak.$ts"
    echo "[OK] Appended managed block to $LOCAL_CONF"
  fi
  echo "[OK] Colour $COLOR_BASE — accent $THEME_ACCENT, dim $THEME_DIM, active $THEME_ACTIVE"
}

# A copy outside the markers sits later in the file and therefore wins, silently
# making the managed block dead.
warn_conflicts() {
  local hits
  [ -r "$LOCAL_CONF" ] || return 0
  hits="$(awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
    index($0, b) == 1 { inblk = 1; next }
    index($0, e) == 1 { inblk = 0; next }
    inblk { next }
    /^[[:space:]]*set(-option)?[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*(status-style|status-left|status-right|status-left-style|status-right-style|window-status-style|window-status-current-style|pane-border-style|pane-active-border-style)([[:space:]]|$)/ {
      printf "%d: %s\n", NR, $0
    }
  ' "$LOCAL_CONF")"
  [ -n "$hits" ] || return 0
  echo
  echo "[!!] These lines in $LOCAL_CONF sit OUTSIDE the managed block and"
  echo "     override it, so your machine colour will not apply:"
  printf '%s\n' "$hits" | sed 's/^/       /'
  echo "     Delete them — install.sh --color generates all of these."
  echo
}

# ── Arguments ─────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --color|-c)
      [ $# -ge 2 ] || { echo "[!!] $1 needs a value" >&2; exit 1; }
      COLOR_ARG="$2"; shift 2 ;;
    --color-current)
      [ $# -ge 2 ] || { echo "[!!] $1 needs a value" >&2; exit 1; }
      COLOR_CURRENT_ARG="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[!!] Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [ -z "$COLOR_ARG" ] && [ -n "$COLOR_CURRENT_ARG" ]; then
  echo "[!!] --color-current requires --color" >&2
  exit 1
fi

# Recover the colour this machine already chose, from the block's own header.
# write_color_block records it as "# Machine colour: #rrggbb", so the block is
# its own source of truth and nothing has to be stored twice.
stored_color() {
  [ -r "$LOCAL_CONF" ] || return 1
  awk '/^# Machine colour:/ {print $4; exit}' "$LOCAL_CONF" | grep -qE '^#[0-9a-fA-F]{6}$' \
    && awk '/^# Machine colour:/ {print $4; exit}' "$LOCAL_CONF"
}

# No --color: generate one on a machine that has none yet, and otherwise reuse
# the one already recorded. Both paths end with COLOR_ARG set, so the block is
# rewritten on every install.
#
# Rewriting matters as much as not re-rolling. The colour is sticky — update.sh
# forwards its arguments here, so a bare `update.sh` must never repaint a colour
# you already have — but the *body* of the block is generated code, and leaving
# it alone is how an upgrade breaks. The shell version's block invoked
# bin/render-bar.sh; those scripts are gone, so a bare install that declined to
# rewrite left the bar calling nothing at all.
if [ -z "$COLOR_ARG" ]; then
  if block_exists && COLOR_ARG="$(stored_color)" && [ -n "$COLOR_ARG" ]; then
    :                       # reuse what this machine already picked
  else
    COLOR_ARG="random"      # no block, or one with no readable colour in it
  fi
fi

[ -n "$COLOR_ARG" ] && resolve_color "$COLOR_ARG"

# ── 1. Link ~/.tmuxm → this clone ─────────────────────────────
# tmux.conf refers to ~/.tmuxm/bin/... so the config is identical on every
# machine no matter where the repo was cloned.
if [ -L "$LINK" ]; then
  ln -sfn "$REPO_DIR" "$LINK"
  echo "[OK] Linked $LINK → $REPO_DIR"
elif [ -d "$LINK" ]; then
  if [ "$(cd "$LINK" && pwd -P)" = "$REPO_DIR" ]; then
    echo "[OK] $LINK is this clone"
  else
    echo "[!!] $LINK is a real directory holding a different checkout:" >&2
    echo "       $(cd "$LINK" && pwd -P)" >&2
    echo "     but you are installing from:" >&2
    echo "       $REPO_DIR" >&2
    echo "     Remove or rename $LINK, then re-run." >&2
    exit 1
  fi
elif [ -e "$LINK" ]; then
  echo "[!!] $LINK exists and is not a directory. Remove it and re-run." >&2
  exit 1
else
  ln -s "$REPO_DIR" "$LINK"
  echo "[OK] Linked $LINK → $REPO_DIR"
fi

# ── 2. Back up a foreign ~/.tmux.conf ─────────────────────────
if [ -e "$TARGET" ] || [ -L "$TARGET" ]; then
  case "$(readlink "$TARGET" 2>/dev/null || true)" in
    "$SOURCE"|"$REPO_DIR/tmux.conf") ;;
    *)
      backup="$TARGET.bak.$(date +%Y%m%d-%H%M%S)"
      mv "$TARGET" "$backup"
      echo "[OK] Backed up existing $TARGET → $backup"
      ;;
  esac
fi

# ── 3. Symlink ~/.tmux.conf ───────────────────────────────────
ln -sfn "$SOURCE" "$TARGET"
echo "[OK] Linked $TARGET → $SOURCE"

# ── 3b. Retire the sampler this version replaced ──────────────
# A daemon already running does not stop just because its script was deleted —
# bash read the file into memory long ago and will happily keep looping. Left
# alone it outlives the upgrade, writing a cache nothing reads, until reboot.
# Idempotent: after the first run there is no pidfile to find.
OLD_PIDFILE="/tmp/tmuxm-sampler-${USER}.pid"
if [ -r "$OLD_PIDFILE" ]; then
  old_pid="$(cat "$OLD_PIDFILE" 2>/dev/null || true)"
  if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
    kill "$old_pid" 2>/dev/null || true
    echo "[OK] Stopped the background sampler this version removes (PID $old_pid)"
  fi
  rm -f "$OLD_PIDFILE"
fi
rm -f "/tmp/tmuxm-stats-${USER}"

# ── 4. Build the renderer ─────────────────────────────────────
# Built from source on every machine rather than shipped, so the oldest
# toolchain in the fleet is the one that has to work. Say so plainly instead of
# letting cargo fail with a version error nobody reads.
if ! command -v cargo >/dev/null 2>&1; then
  echo "[!!] cargo not found — tmuxm's status bar is a Rust binary now." >&2
  echo "     Install a toolchain:  curl https://sh.rustup.rs -sSf | sh" >&2
  exit 1
fi
mkdir -p "$REPO_DIR/bin"
if cargo build --release --manifest-path "$REPO_DIR/rust/Cargo.toml" 2>&1 | sed 's/^/     /'; then
  # Install by rename, not by copy. tmux runs bin/tmuxm every couple of
  # seconds, and writing over a binary that is currently executing fails with
  # ETXTBSY. A rename swaps the directory entry instead: anything mid-flight
  # keeps the old inode and the next run picks up the new one.
  cp "$REPO_DIR/rust/target/release/tmuxm" "$REPO_DIR/bin/.tmuxm.new"
  chmod +x "$REPO_DIR/bin/.tmuxm.new"
  mv -f "$REPO_DIR/bin/.tmuxm.new" "$REPO_DIR/bin/tmuxm"
  echo "[OK] Built bin/tmuxm ($("$REPO_DIR/bin/tmuxm" tz >/dev/null 2>&1 && echo working || echo "built, but not runnable"))"
else
  echo "[!!] cargo build failed — see above. Minimum supported Rust is 1.75." >&2
  exit 1
fi

# ── 5. Clone TPM if missing ───────────────────────────────────
if [ ! -d "$TPM_DIR" ]; then
  git clone https://github.com/tmux-plugins/tpm "$TPM_DIR"
  echo "[OK] Cloned TPM"
else
  echo "[OK] TPM already present"
fi

# ── 6. Machine colour ─────────────────────────────────────────
if [ -n "$COLOR_ARG" ]; then
  [ "$AUTO_RANDOM" -eq 1 ] && echo "[OK] Generated a random colour for this machine"
  write_color_block
fi
warn_conflicts

# ── 7. Reload tmux if running ─────────────────────────────────
if tmux info &>/dev/null; then
  tmux source "$TARGET"
  echo "[OK] Reloaded tmux. Press C-a Shift+I inside tmux to install plugins."
else
  echo "[OK] tmux not running. Start tmux and press C-a Shift+I to install plugins."
fi
