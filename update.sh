#!/usr/bin/env bash
# Updater for the tmuxm config on this machine.
# Pulls latest from origin, re-runs install.sh (which rebuilds the binary and
# sources tmux), then verifies the binary runs.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cd "$REPO_DIR"

# 1. Pull latest (only if behind)
git fetch --quiet
LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse @{u})
if [ "$LOCAL" = "$REMOTE" ]; then
  echo "[OK] Already up to date ($(git rev-parse --short HEAD))"
else
  git pull --ff-only
  echo "[OK] Pulled to $(git rev-parse --short HEAD)"
fi

# 2. (Nothing to stop.) There is no sampler any more — the bar is a binary tmux
#    runs on its own refresh, so an update needs no process wrangling. This used
#    to SIGTERM the daemon and wait up to 5s for its pidfile to clear, because a
#    replacement that started while the old one still held the claim would exit
#    and leave none running at all.

# 3. Run installer: link ~/.tmuxm, symlink ~/.tmux.conf, rebuild bin/tmuxm, TPM,
#    and `tmux source`. Args are forwarded, so `update.sh --color random` works.
#    A bare update.sh
#    forwards nothing and install.sh leaves an existing colour alone. ${@+"$@"} keeps
#    this safe under `set -u` on macOS stock bash 3.2 when there are no args.
"$REPO_DIR/install.sh" ${@+"$@"}

# 4. Verify the rebuilt binary actually renders.
if "$REPO_DIR/bin/tmuxm" tz >/dev/null 2>&1; then
  echo "[OK] bin/tmuxm runs ($("$REPO_DIR/bin/tmuxm" tz) UTC offset)"
else
  echo "[!!] bin/tmuxm did not run — the status bar will be empty" >&2
  exit 1
fi
if tmux info &>/dev/null; then
  echo "[OK] tmux reloaded; the bar refreshes within $(tmux show -gv status-interval)s"
else
  echo "[OK] No tmux running; the bar will draw when you launch it"
fi
