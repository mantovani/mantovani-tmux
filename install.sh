#!/usr/bin/env bash
# Idempotent installer for the tmuxm config.
# Links ~/.tmuxm → this clone, symlinks ~/.tmux.conf, clones TPM if missing,
# sources the config. Optionally writes this machine's accent colour.
#
# Usage:
#   install.sh                        install / re-install, touches no colours
#   install.sh --color pink           also set this machine's accent colour
#   install.sh --color '#3366cc'      arbitrary hex; active shade is derived
#   install.sh --color '#3366cc' --color-current '#88aaff'
#   install.sh --list-colors          show the presets
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
COLOR_CUR=""
COLOR_NAME=""

# ── Colour presets ────────────────────────────────────────────
# name|bar background|active window|note
presets() {
  cat <<'EOF'
red|#8B0000|#DC143C|shipped default (AI Vampire)
pink|#ff69b4|#d63384|
blue|#1e3a8a|#3b82f6|
green|#14532d|#22c55e|
purple|#4c1d95|#8b5cf6|
amber|#92400e|#f59e0b|
slate|#334155|#64748b|
EOF
}

usage() {
  cat <<'EOF'
Usage: install.sh [--color <name|#rrggbb>] [--color-current <#rrggbb>]
                  [--list-colors] [-h|--help]

With no arguments this installs/re-installs and leaves ~/.tmux.local.conf alone.
EOF
}

list_colors() {
  echo "Presets (pick one per machine so you can tell them apart):"
  presets | while IFS='|' read -r name base cur note; do
    printf '  %-7s bar %s  active %s%s\n' \
      "$name" "$base" "$cur" "${note:+  — $note}"
  done
  echo
  echo "Or pass any hex: install.sh --color '#3366cc'"
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

# "#rrggbb" -> "r g b"
hex_rgb() {
  local h="${1#\#}"
  echo "$(( 16#${h:0:2} )) $(( 16#${h:2:2} )) $(( 16#${h:4:2} ))"
}

# Perceived luminance decides whether text on this background reads better
# black or white.
fg_for() {
  local r=$1 g=$2 b=$3
  if [ $(( (299*r + 587*g + 114*b) / 1000 )) -gt 140 ]; then
    echo black
  else
    echo white
  fi
}

# Derive an active-window shade that actually contrasts with the bar: lighten a
# dark base toward white, darken a light one. Keeps custom hex colours usable
# without asking for a second value.
derive_current() {
  local r=$1 g=$2 b=$3
  if [ $(( (299*r + 587*g + 114*b) / 1000 )) -gt 140 ]; then
    r=$(( r * 65 / 100 )); g=$(( g * 65 / 100 )); b=$(( b * 65 / 100 ))
  else
    r=$(( r + (255-r)*45/100 )); g=$(( g + (255-g)*45/100 )); b=$(( b + (255-b)*45/100 ))
  fi
  printf '#%02x%02x%02x\n' "$r" "$g" "$b"
}

# Sets COLOR_BASE / COLOR_CUR / COLOR_NAME from --color (+ optional override).
resolve_color() {
  local want="$1" line
  line="$(presets | awk -F'|' -v n="$want" '$1==n {print; exit}')"
  if [ -n "$line" ]; then
    COLOR_NAME="$want"
    COLOR_BASE="$(printf '%s' "$line" | cut -d'|' -f2)"
    COLOR_CUR="$(printf '%s' "$line" | cut -d'|' -f3)"
  else
    case "$want" in
      '#'*|[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])
        COLOR_BASE="$(normalize_hex "$want")"
        COLOR_CUR="$(derive_current $(hex_rgb "$COLOR_BASE"))"
        COLOR_NAME="$COLOR_BASE"
        ;;
      *)
        echo "[!!] Unknown colour '$want'. Run --list-colors, or pass #rrggbb." >&2
        exit 1
        ;;
    esac
  fi
  if [ -n "$COLOR_CURRENT_ARG" ]; then
    COLOR_CUR="$(normalize_hex "$COLOR_CURRENT_ARG")"
  fi
}

# The three lines that repaint the bar background and the window list. Nothing
# else — status-left and status-right carry their own #[bg=...] on purpose.
write_color_block() {
  local base_fg cur_fg blockfile tmp ts
  base_fg="$(fg_for $(hex_rgb "$COLOR_BASE"))"
  cur_fg="$(fg_for $(hex_rgb "$COLOR_CUR"))"

  blockfile="$(mktemp "${TMPDIR:-/tmp}/tmuxm-block.XXXXXX")"
  trap 'rm -f "$blockfile"' RETURN
  {
    printf '%s\n' "$BEGIN_MARK"
    printf '# Machine accent: %s — regenerate with: ~/.tmuxm/install.sh --color %s\n' \
      "$COLOR_NAME" "$COLOR_NAME"
    printf 'set -g status-style "bg=%s,fg=%s"\n' "$COLOR_BASE" "$base_fg"
    printf 'set -g window-status-style "bg=%s,fg=%s"\n' "$COLOR_BASE" "$base_fg"
    printf 'set -g window-status-current-style "bg=%s,fg=%s,bold"\n' "$COLOR_CUR" "$cur_fg"
    printf '%s\n' "$END_MARK"
  } > "$blockfile"

  if [ ! -e "$LOCAL_CONF" ] && [ ! -L "$LOCAL_CONF" ]; then
    cat "$blockfile" > "$LOCAL_CONF"
    echo "[OK] Created $LOCAL_CONF (accent $COLOR_BASE, active $COLOR_CUR)"
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
    echo "[OK] Updated managed block in $LOCAL_CONF (accent $COLOR_BASE, active $COLOR_CUR)"
  else
    # Pre-existing hand-written file: keep all of it, back it up, append.
    ts="$(date +%Y%m%d-%H%M%S)"
    cp "$LOCAL_CONF" "$LOCAL_CONF.bak.$ts"
    printf '\n' >> "$LOCAL_CONF"
    cat "$blockfile" >> "$LOCAL_CONF"
    echo "[OK] Backed up $LOCAL_CONF → $LOCAL_CONF.bak.$ts"
    echo "[OK] Appended managed block to $LOCAL_CONF (accent $COLOR_BASE, active $COLOR_CUR)"
  fi
}

# status-left-style / status-right-style / status-left in an override change the
# left/right region geometry and the metrics collapse leftward. We never edit
# the user's own lines — just point at them.
warn_conflicts() {
  local hits
  [ -r "$LOCAL_CONF" ] || return 0
  hits="$(grep -nE '^[[:space:]]*set(-option)?[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*(status-left-style|status-right-style|status-left)([[:space:]]|$)' "$LOCAL_CONF" || true)"
  [ -n "$hits" ] || return 0
  echo
  echo "[!!] $LOCAL_CONF sets options that collapse the right-hand metrics:"
  printf '%s\n' "$hits" | sed 's/^/       /'
  echo "     Delete those lines. The vampire badge and the matrix metrics paint"
  echo "     their own backgrounds, so an override never needs to touch them."
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
    --list-colors) list_colors; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[!!] Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [ -z "$COLOR_ARG" ] && [ -n "$COLOR_CURRENT_ARG" ]; then
  echo "[!!] --color-current requires --color" >&2
  exit 1
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
# A symlink we placed ourselves (old or new path) is just replaced, not backed up.
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

# ── 4. Ensure bin scripts are executable ──────────────────────
chmod +x "$REPO_DIR"/bin/*.sh

# ── 5. Clone TPM if missing ───────────────────────────────────
if [ ! -d "$TPM_DIR" ]; then
  git clone https://github.com/tmux-plugins/tpm "$TPM_DIR"
  echo "[OK] Cloned TPM"
else
  echo "[OK] TPM already present"
fi

# ── 6. Per-machine colour (only when asked) ───────────────────
if [ -n "$COLOR_ARG" ]; then
  write_color_block
fi
warn_conflicts

# ── 7. One-time migration off the pre-rename /tmp/tmux-* names ─
# The old sampler holds the old pidfile, so the new code cannot see it and
# would start a second one. Safe to delete this block once every machine has
# run install.sh at least once.
LEGACY_PIDFILE="/tmp/tmux-sampler-${USER}.pid"
LEGACY_CACHE="/tmp/tmux-stats-${USER}"
if [ -r "$LEGACY_PIDFILE" ]; then
  legacy_pid="$(cat "$LEGACY_PIDFILE" 2>/dev/null || true)"
  if [ -n "$legacy_pid" ] && kill -0 "$legacy_pid" 2>/dev/null; then
    kill "$legacy_pid" 2>/dev/null || true
    echo "[OK] Stopped pre-rename sampler (PID $legacy_pid)"
  fi
  rm -f "$LEGACY_PIDFILE"
fi
rm -f "$LEGACY_CACHE"

# ── 8. Reload tmux if running ─────────────────────────────────
if tmux info &>/dev/null; then
  tmux source "$TARGET"
  echo "[OK] Reloaded tmux. Press C-a Shift+I inside tmux to install plugins."
else
  echo "[OK] tmux not running. Start tmux and press C-a Shift+I to install plugins."
fi

if [ -z "$COLOR_ARG" ] && ! grep -qsF "$BEGIN_MARK" "$LOCAL_CONF"; then
  echo "[--] Give this machine its own colour: $LINK/install.sh --list-colors"
fi
