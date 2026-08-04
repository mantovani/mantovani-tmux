# tmuxm

Portable tmux config. **AI Wizard** theme: a fixed badge on the left, arcane-violet
live system metrics on the right, and a **window list in the middle that you colour
differently on every machine** — so a glance at the bar tells you which box you're on.
Cross-platform (macOS & Linux).

## What it looks like

```
 🧙 AI Wizard 🔮 │ 1:zsh* 2:vim 3:logs           CPU █▁▁▁  23% │ MEM ███▂  79% │ ↓ 99.3K ↑  1.9K │ @host │ 25/05/2026 13:14
└── status-left ─┘└─── window list ────┘         └──────────────────── status-right (metrics) ─────────────────────────┘
      fixed             per-machine                                    fixed
```

| Segment | Colour | Per-machine? |
|---|---|---|
| `🧙 AI Wizard 🔮` badge | gold `#FBBF24` on black | **No** — same everywhere |
| **Window list** | white on deep violet `#4c1d95`; current window on `#8b5cf6` | **Yes — this is the machine colour** |
| Bar background | deep violet `#4c1d95` | **Yes** — matches the window list |
| CPU/MEM bars | arcane violet `#A78BFA` → gold `#FBBF24` → red `#FF0000` | No. Fixed-width `  0%` … `100%` |
| Net throughput | arcane violet | No. Fixed-width 6 chars (`    0B` / ` 99.3K` / `  1.2M`) |
| `@host` | pale violet `#C4B5FD`, bold | No |
| Date | arcane violet, bold | No. European `dd/mm/yyyy hh:mm` |

Under load (colour escalates, bars fill):
```
 🧙 AI Wizard 🔮 │ windows…           CPU ███▅  88% │ MEM ████  95% │ ↓18.4M ↑ 2.1M │ @host │ 25/05/2026 13:14
```

## Install

```bash
git clone git@github.com:mantovani/mantovani-tmux.git ~/.tmuxm
~/.tmuxm/install.sh
~/.tmuxm/install.sh --color blue    # give this machine its own colour
tmux                                # or reattach
# inside tmux: press C-a Shift+I to install TPM plugins
```

**Clone wherever you like.** `tmux.conf` refers to `~/.tmuxm/bin/…`, and `install.sh`
makes that path exist either way: if the clone *is* `~/.tmuxm` it does nothing, and
otherwise it creates `~/.tmuxm` as a symlink to wherever you cloned. So this works
just as well:

```bash
git clone git@github.com:mantovani/mantovani-tmux.git ~/projects/github/tmuxm
~/projects/github/tmuxm/install.sh   # creates ~/.tmuxm -> ~/projects/github/tmuxm
```

`install.sh` is idempotent: links `~/.tmuxm`, backs up a pre-existing `~/.tmux.conf`
and symlinks the new one, clones [TPM](https://github.com/tmux-plugins/tpm) if missing,
sources the config if tmux is running. With no arguments it never touches
`~/.tmux.local.conf`.

## Update

```bash
~/.tmuxm/update.sh
```

Fast-forwards from origin, kills the running sampler so the new code is loaded, re-runs
`install.sh` (which sources tmux and respawns the sampler), then verifies the sampler is
alive and writing the cache. Arguments are forwarded, so `update.sh --color green` works.

`update.sh` never rewrites `~/.tmux.local.conf` on its own — see the pitfall below if
you set this machine up before the `--color` flag existed.

## Per-machine colour

This is the point of the middle region. Pick one colour per machine and keep it, and
you'll never again run a command on the wrong box because two windows looked alike.

```bash
~/.tmuxm/install.sh --list-colors     # show the presets
~/.tmuxm/install.sh --color pink      # apply one
```

| Preset | Bar + window list | Current window | Suggested for |
|---|---|---|---|
| `red` | `#8B0000` | `#DC143C` | secondary machine |
| `pink` | `#ff69b4` | `#d63384` | personal desktop |
| `blue` | `#1e3a8a` | `#3b82f6` | work laptop |
| `green` | `#14532d` | `#22c55e` | dev / staging box |
| `purple` | `#4c1d95` | `#8b5cf6` | the shipped default |
| `amber` | `#92400e` | `#f59e0b` | **production — think before you type** |
| `slate` | `#334155` | `#64748b` | anything neutral |

Any hex works too. The active-window shade is derived automatically (lightened if your
colour is dark, darkened if it's light) and the text colour is picked from the
background's luminance, so it stays readable:

```bash
~/.tmuxm/install.sh --color '#3366cc'
~/.tmuxm/install.sh --color '#3366cc' --color-current '#88aaff'   # or set it yourself
```

Reload with `tmux source ~/.tmux.conf` (or `C-a` then `:source ~/.tmux.conf`).

### What it writes, and what it won't touch

`--color` appends a marked block to `~/.tmux.local.conf`, which `tmux.conf` sources
`-q` at the very end. The file is **git-ignored**, so each machine carries its own.

```tmux
# >>> tmuxm colour (managed by install.sh --color) >>>
# Machine accent: pink — regenerate with: ~/.tmuxm/install.sh --color pink
set -g status-style "bg=#ff69b4,fg=black"
set -g window-status-style "bg=#ff69b4,fg=black"
set -g window-status-current-style "bg=#d63384,fg=white,bold"
# <<< tmuxm colour <<<
```

Re-running `--color` rewrites **only** that block. Everything else in the file is left
alone — `~/.tmux.local.conf` is also where per-machine bits like the `xclip` copy-pipe
bindings live, and those survive. If the file already existed without the markers, it's
backed up to `~/.tmux.local.conf.bak.<timestamp>` before the block is appended.

Three lines is the whole theme. That's deliberate: the badge and the metrics embed their
own `#[bg=…]`, so they look identical on every machine — the constant frame is what makes
the varying window colour easy to read at a glance.

> **Pitfall — do not add these:**
> ```tmux
> set -g status-left-style  …    # changes left/right region geometry — right metrics collapse leftward
> set -g status-right-style …    # same
> set -g status-left "…"          # unnecessary; status-left already paints its own bg
> ```
> The base `tmux.conf` does set all five styles, but only because they share the same
> dark-red bg — that's the special case where the geometry works out. In an override
> they're almost always a different colour from `status-style`, which is exactly when
> tmux collapses the right region.
>
> **Machines set up before `--color` existed** may still carry a six-line override with
> these in it. `install.sh` prints the offending line numbers on every run but never
> edits your file — delete them by hand, then re-run `--color`.

To re-style the right-hand metrics too, redefine `status-right` in your local file —
copy it out of the *Status bar* section of `tmux.conf` and change the colour values.

## Architecture

Sampler-and-cache pattern (inspired by [samoshkin/tmux-plugin-sysstat][sysstat]):

```
                    once per machine, pidfile-guarded
                                │
            ┌───────────────────▼──────────────────┐
            │ bin/sampler.sh                       │
            │ samples cpu/mem/bat/net every 2 s    │
            │ writes /tmp/tmuxm-stats-$USER (50 B) │
            └───────────────────┬──────────────────┘
                                │ atomic rename
                                ▼
              /tmp/tmuxm-stats-$USER  (key = value, 5 lines)
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
  Pidfile at `/tmp/tmuxm-sampler-$USER.pid` is checked on each launch; if the recorded
  PID is alive (`kill -0` succeeds), the new instance exits immediately.
- **Atomic writes** — the sampler writes to `$CACHE.tmp` and renames, so renderers always
  read a consistent file.
- **Cross-platform** — `sampler.sh` branches on `uname -s`:
  - Darwin: `iostat -c` (CPU), `vm_stat`, `pmset -g batt`, `netstat -ibn`
  - Linux: `/proc/stat`, `/proc/meminfo`, `/sys/class/power_supply/BAT*`, `/proc/net/dev`
- **Fixed-width renders** — bars are always 4 chars + ` 999%` (9 chars total), throughput
  is always 6 chars. The status bar never jitters.
- **The bin scripts are location-independent** — they only read and write `/tmp`, so the
  only thing tying the config to a directory is `~/.tmuxm`.

## File locations

| Path | Purpose |
|---|---|
| `~/.tmuxm` | The clone, or a symlink to it (created by `install.sh`) |
| `~/.tmux.conf` | Symlink → `~/.tmuxm/tmux.conf` |
| `~/.tmux.conf.bak.<timestamp>` | Backup of a pre-existing `~/.tmux.conf` |
| `~/.tmux.local.conf` | **Per-machine colour + overrides** — not tracked in git |
| `~/.tmux.local.conf.bak.<timestamp>` | Backup made the first time `--color` touches an existing file |
| `~/.tmux/plugins/tpm/` | TPM (cloned by `install.sh`) |
| `/tmp/tmuxm-stats-$USER` | Sampler cache (~50 bytes, 5 lines) |
| `/tmp/tmuxm-sampler-$USER.pid` | Sampler pidfile |

## Requirements

| Component | Version | Notes |
|---|---|---|
| `tmux` | ≥ 2.1 | for `run-shell -b` |
| `bash` | ≥ 3.2 | macOS stock bash is fine |
| `git` | any | for the TPM clone |
| macOS tools | `iostat`, `vm_stat`, `pmset`, `netstat` | all preinstalled |
| Linux tools | `awk`, `cat`, `/proc`, optional `/sys/class/power_supply/` | preinstalled on any distro |
| `xclip` / `pbcopy` | optional | only if you add clipboard bindings to `~/.tmux.local.conf` |
| Terminal | UTF-8, supports `▁▂▃▄▅▆▇█`, emoji | iTerm2 / WezTerm / Ghostty / Kitty / Alacritty / GNOME Terminal all fine |

Battery is omitted automatically if `/sys/class/power_supply/BAT*` doesn't exist
(desktops, VMs).

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
| Mouse | Enabled (scroll, resize, click panes, drag-select) |
| `C-a` `[` | Copy mode — **vi keys** (`mode-keys vi`) |
| `C-a` `Shift+I` | TPM: install plugins from `@plugin` declarations |
| `C-a` `Shift+U` | TPM: update plugins |

`mode-keys vi` is set so `copy-mode-vi` bindings work; the actual clipboard bind (`y` →
`xclip`/`pbcopy`) is per-machine and belongs in `~/.tmux.local.conf`.

## Layout

```
tmuxm/
├── tmux.conf              # main config — symlinked to ~/.tmux.conf
├── install.sh             # idempotent installer + --color
├── update.sh              # pull, restart sampler, verify
├── bin/
│   ├── sampler.sh         # background daemon, writes cache
│   ├── render-bar.sh      # cpu/mem/bat → arcane bar
│   └── render-net.sh      # net throughput → fixed-width string
├── .gitignore
└── README.md
```

[sysstat]: https://github.com/samoshkin/tmux-plugin-sysstat
