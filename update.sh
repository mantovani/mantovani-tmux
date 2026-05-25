#!/usr/bin/env bash
# Updater for the mantovani-tmux config on this machine.
# Pulls latest from origin, kills the stale sampler, re-runs install.sh
# (which sources tmux and spawns a fresh sampler), then verifies.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIDFILE="/tmp/tmux-sampler-${USER}.pid"
CACHE="/tmp/tmux-stats-${USER}"

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

# 2. Kill stale sampler so the new code is used on the next spawn.
#    The sampler's EXIT trap removes the pidfile.
if [ -r "$PIDFILE" ]; then
  old_pid=$(cat "$PIDFILE")
  if kill -0 "$old_pid" 2>/dev/null; then
    kill "$old_pid"
    echo "[OK] Killed stale sampler (PID $old_pid)"
    for _ in 1 2 3 4 5; do
      [ -e "$PIDFILE" ] || break
      sleep 0.2
    done
  fi
fi

# 3. Run installer: symlink, chmod, TPM, and `tmux source` which respawns
#    the sampler via `run-shell -b` in tmux.conf.
"$REPO_DIR/install.sh"

# 4. Verify the new sampler is alive and writing the cache.
if tmux info &>/dev/null; then
  sleep 3
  if [ -r "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "[OK] Sampler alive (PID $(cat "$PIDFILE"))"
    if [ -r "$CACHE" ]; then
      sed 's/^/       /' "$CACHE"
    fi
  else
    echo "[!!] Sampler not running despite tmux being up — check tmux config"
    exit 1
  fi
else
  echo "[OK] No tmux running; sampler will start when you launch tmux"
fi
