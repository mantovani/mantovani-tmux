# mantovani-tmux

Personal tmux config. **AI Vampire** theme: blood-red status bar on the left,
matrix-green live system metrics on the right. Cross-platform (macOS & Linux).

## What it looks like

```
 🧛 AI Vampire │ 1:zsh* 2:vim 3:logs           CPU █▁▁▁  23% │ MEM ███▂  79% │ ↓ 99.3K ↑  1.9K │ @host │ 25/05/2026 13:14
└──── left ───┘└──── windows ─────┘           └────────────────── matrix-green metrics (black bg) ──────────────────┘
```

| Segment | Color | Notes |
|---|---|---|
| `🧛 AI Vampire` | crimson `#DC143C` on black bg | Themable (per-machine override) |
| Windows | white on blood-red `#8B0000`; current window on bright `#DC143C` | Themable |
| CPU/MEM bars | matrix-green `#00FF41`, escalates yellow `#FFFF00` → red `#FF0000` | Fixed-width `  0%` … `100%` |
| Net throughput | matrix-green | Fixed-width 6 chars (`    0B` / ` 99.3K` / `  1.2M`) |
| `@host` | brighter green `#39FF14`, bold | `#h` (short hostname) |
| Date | matrix-green, bold | European format `dd/mm/yyyy hh:mm` |

Under load (color escalates, bars fill):
```
 🧛 AI Vampire │ windows…           CPU ███▅  88% │ MEM ████  95% │ ↓18.4M ↑ 2.1M │ @host │ 25/05/2026 13:14
```

## Install

```bash
git clone git@github.com:mantovani/mantovani-tmux.git ~/projects/github/mantovani-tmux
~/projects/github/mantovani-tmux/install.sh
tmux                           # or reattach
# inside tmux: press C-a Shift+I to install TPM plugins
```

`install.sh` is idempotent: backs up an existing `~/.tmux.conf`, symlinks the new
one, clones [TPM](https://github.com/tmux-plugins/tpm) if missing, sources the
config if tmux is running.

> **Path note:** `tmux.conf` hardcodes the repo at `~/projects/github/mantovani-tmux`.
> If you clone elsewhere, symlink: `ln -s /your/path ~/projects/github/mantovani-tmux`.

## Update

```bash
~/projects/github/mantovani-tmux/update.sh
```

`update.sh` is also idempotent: fast-forwards from origin, kills the running
sampler so the new code is loaded, re-runs `install.sh` (which sources tmux and
respawns the sampler via `run-shell -b`), then verifies the new sampler is alive
and writing to the cache.

## Per-machine theming

The repo ships the blood-red vampire theme. To use a different colour scheme on
a specific machine, create `~/.tmux.local.conf`. It is sourced at the very end
of `tmux.conf`, so anything set there overrides the defaults. The file is
**git-ignored** so each machine carries its own.

### Example: pink theme on a desktop

`~/.tmux.local.conf`:
```tmux
set -g status-style "bg=#ff69b4,fg=black"
set -g status-left-style "bg=#ff69b4,fg=black"
set -g status-right-style "bg=#ff69b4,fg=black"
set -g window-status-style "bg=#ff69b4,fg=black"
set -g window-status-current-style "bg=#d63384,fg=white,bold"
set -g status-left "#[bg=#000000,fg=#DC143C,bold] 🧛 AI Vampire #[bg=#ff69b4,fg=black] "
```

Reload with `C-a` then `:source ~/.tmux.conf` (or `tmux source ~/.tmux.conf`
from any shell). The matrix-green right side stays the same against its own
black background; only the vampire/windows region picks up the new colour.

To re-style the right side too, redefine `status-right` in the local file
(copy from `tmux.conf:26` and tweak the colour values).

## Architecture

Sampler-and-cache pattern (inspired by [samoshkin/tmux-plugin-sysstat][sysstat]):

```
                    once per machine, pidfile-guarded
                                │
            ┌───────────────────▼─────────────────┐
            │ bin/sampler.sh                      │
            │ samples cpu/mem/bat/net every 2 s   │
            │ writes /tmp/tmux-stats-$USER (50 B) │
            └───────────────────┬─────────────────┘
                                │ atomic rename
                                ▼
              /tmp/tmux-stats-$USER  (key = value, 5 lines)
                                │
            ┌───────────────────┴────────────────┐
            │                                    │
            ▼                                    ▼
   bin/render-bar.sh                    bin/render-net.sh
   (cpu | mem | bat)                    (in | out)
   ~2 ms per call                       ~2 ms per call
            │                                    │
            └──────────────► tmux status-right ◄─┘
```

- **One sampler per user**, no matter how many tmux servers/sessions/clients.
  Pidfile at `/tmp/tmux-sampler-$USER.pid` is checked on each launch; if the
  recorded PID is alive (`kill -0` succeeds), the new instance exits immediately.
- **Atomic writes** — the sampler writes to `$CACHE.tmp` and renames, so renderers
  always read a consistent file.
- **Cross-platform** — `sampler.sh` branches on `uname -s`:
  - Darwin: `top -l1`, `vm_stat`, `pmset -g batt`, `netstat -ibn`
  - Linux: `/proc/stat`, `/proc/meminfo`, `/sys/class/power_supply/BAT*`, `/proc/net/dev`
- **Fixed-width renders** — bars are always 4 chars + ` 999%` (9 chars total),
  throughput is always 6 chars. The status bar never jitters.

## File locations

| Path | Purpose |
|---|---|
| `~/projects/github/mantovani-tmux/` | This repo (recommended clone location) |
| `~/.tmux.conf` | Symlink → `tmux.conf` in repo (created by `install.sh`) |
| `~/.tmux.conf.bak.<timestamp>` | Backup of pre-install `~/.tmux.conf` |
| `~/.tmux.local.conf` | **Per-machine overrides** — not tracked in git |
| `~/.tmux/plugins/tpm/` | TPM (cloned by `install.sh`) |
| `/tmp/tmux-stats-$USER` | Sampler cache (~50 bytes, 5 lines) |
| `/tmp/tmux-sampler-$USER.pid` | Sampler pidfile |

## Requirements

| Component | Version | Notes |
|---|---|---|
| `tmux` | ≥ 2.1 | for `run-shell -b` |
| `bash` | ≥ 3.2 | macOS stock bash is fine |
| `git` | any | for the TPM clone |
| macOS tools | `top`, `vm_stat`, `pmset`, `netstat` | all preinstalled |
| Linux tools | `awk`, `cat`, `/proc`, optional `/sys/class/power_supply/` | preinstalled on any distro |
| Terminal | UTF-8, supports `▁▂▃▄▅▆▇█`, emoji | iTerm2 / WezTerm / Ghostty / Kitty / Alacritty / GNOME Terminal all fine |

Battery line is omitted automatically if `/sys/class/power_supply/BAT*` doesn't
exist (desktops, VMs).

## Resource usage

Steady-state on macOS (measured):

| | |
|---|---|
| Sampler RSS | 1.7 MB |
| Sampler CPU | ~240 ms per 2 s cycle (≈12 % of one core during the sample) |
| Per-render cost | ~2 ms (vs ~190 ms for the previous per-refresh `top -l1`) |
| Cache file | 50 bytes |
| Process count | 1 sampler regardless of how many tmux servers/clients |

## Keybinds (defaults from `tmux.conf`)

| Bind | Action |
|---|---|
| `C-a` | Prefix (remapped from `C-b`) |
| `C-a` `C-a` | Send literal `C-a` |
| Mouse | Enabled (scroll, resize, click panes) |
| `C-a` `Shift+I` | TPM: install plugins from `@plugin` declarations |
| `C-a` `Shift+U` | TPM: update plugins |

## Layout

```
mantovani-tmux/
├── tmux.conf              # main config — symlinked to ~/.tmux.conf
├── install.sh             # idempotent installer
├── bin/
│   ├── sampler.sh         # background daemon, writes cache
│   ├── render-bar.sh      # cpu/mem/bat → matrix bar
│   └── render-net.sh      # net throughput → fixed-width string
├── .gitignore
└── README.md
```

[sysstat]: https://github.com/samoshkin/tmux-plugin-sysstat
