#!/usr/bin/env bash
# Updater for the tmuxm config on this machine.
# Pulls latest from origin, kills the stale sampler, re-runs install.sh
# (which sources tmux and spawns a fresh sampler), then verifies.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIDFILE="/tmp/tmuxm-sampler-${USER}.pid"
CACHE="/tmp/tmuxm-stats-${USER}"

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

# 2. Stop the running sampler so the new code is used on the next spawn.
#    It traps TERM and exits promptly, releasing the pidfile.
#
#    Waiting for the process to actually be gone matters: install.sh reloads
#    tmux, which respawns the sampler, and a replacement that starts while the
#    old one is still alive sees a live owner and exits — leaving no sampler at
#    all. Budget 5s, because on macOS the TERM handler can be deferred until an
#    in-flight `iostat` returns (~1s), which the old 1s budget did not cover.
if [ -r "$PIDFILE" ]; then
  old_pid=$(cat "$PIDFILE")
  if kill -0 "$old_pid" 2>/dev/null; then
    kill "$old_pid"
    for _ in $(seq 1 50); do
      kill -0 "$old_pid" 2>/dev/null || break
      sleep 0.1
    done
    if kill -0 "$old_pid" 2>/dev/null; then
      echo "[!!] Sampler PID $old_pid ignored SIGTERM after 5s; forcing"
      kill -9 "$old_pid" 2>/dev/null || true
      rm -f "$PIDFILE"
    else
      echo "[OK] Stopped sampler (PID $old_pid)"
    fi
  else
    rm -f "$PIDFILE"   # pidfile outlived its process
  fi
fi

# 3. Run installer: link ~/.tmuxm, symlink ~/.tmux.conf, chmod, TPM, and
#    `tmux source` which respawns the sampler via `run-shell -b` in tmux.conf.
#    Args are forwarded, so `update.sh --color random` works. A bare update.sh
#    forwards nothing and install.sh leaves an existing colour alone. ${@+"$@"} keeps
#    this safe under `set -u` on macOS stock bash 3.2 when there are no args.
"$REPO_DIR/install.sh" ${@+"$@"}

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
