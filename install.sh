#!/usr/bin/env bash
# Idempotent installer for the mantovani-tmux config.
# Symlinks ~/.tmux.conf, clones TPM if missing, sources the config.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$HOME/.tmux.conf"
SOURCE="$REPO_DIR/tmux.conf"
TPM_DIR="$HOME/.tmux/plugins/tpm"

# 1. Backup existing ~/.tmux.conf if it's not already our symlink
if [ -e "$TARGET" ] && [ "$(readlink "$TARGET")" != "$SOURCE" ]; then
  backup="$TARGET.bak.$(date +%Y%m%d-%H%M%S)"
  mv "$TARGET" "$backup"
  echo "[OK] Backed up existing $TARGET → $backup"
fi

# 2. Symlink
ln -sfn "$SOURCE" "$TARGET"
echo "[OK] Linked $TARGET → $SOURCE"

# 3. Ensure matrix-bar.sh is executable
chmod +x "$REPO_DIR/bin/matrix-bar.sh"

# 4. Clone TPM if missing
if [ ! -d "$TPM_DIR" ]; then
  git clone https://github.com/tmux-plugins/tpm "$TPM_DIR"
  echo "[OK] Cloned TPM"
else
  echo "[OK] TPM already present"
fi

# 5. Reload tmux if running
if tmux info &>/dev/null; then
  tmux source "$TARGET"
  echo "[OK] Reloaded tmux. Press C-a Shift+I inside tmux to install plugins."
else
  echo "[OK] tmux not running. Start tmux and press C-a Shift+I to install plugins."
fi
