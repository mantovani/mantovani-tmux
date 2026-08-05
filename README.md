# tmuxm

Portable tmux config. **AI Wizard** theme: a badge on the left, live system metrics on
the right, and **one colour per machine running through all of it** — so a glance at the
bar tells you which box you're on. Every machine picks its own colour on first install.
Cross-platform (macOS & Linux).

## What it looks like

```
 🧙 AI Wizard 🔮 │ 1:zsh* 2:vim 3:logs        CPU █▁▁▁  23% │ MEM ███▂  79% │ ↓ 99.3K ↑  1.9K │ @host │ 25/05/2026 13:14 -3 GMT
└── status-left ─┘└─── window list ────┘         └──────────────────── status-right (metrics) ─────────────────────────┘
   black end-cap      machine colour                          black end-cap, machine colour
```

The black end-caps are fixed so the bar has a constant frame; everything drawn *on* them
takes the machine colour.

| Segment | Colour |
|---|---|
| `🧙 AI Wizard 🔮` badge | the accent, bold, on black |
| **Window list** | the machine colour; current window on the active shade |
| Bar background | the machine colour |
| CPU/MEM bars | the accent — the *same* at 1% and at 100% |
| Net throughput | the accent. Fixed-width 6 chars (`    0B` / ` 99.3K` / `  1.2M`) |
| `@host` | the accent, bold |
| Date + UTC offset | the accent, bold. European `dd/mm/yyyy hh:mm`, then `-3 GMT` |
| `│` separators, pane borders | the accent, dimmed |

**Black is the only fixed colour in the theme.** Everything else on the bar is that one
machine colour or a shade derived from it.

Under load the bars fill; the colour does not change:
```
 🧙 AI Wizard 🔮 │ windows…        CPU ███▅  88% │ MEM ████  95% │ ↓18.4M ↑ 2.1M │ @host │ 25/05/2026 13:14 -3 GMT
```

## Install

```bash
git clone git@github.com:mantovani/mantovani-tmux.git ~/.tmuxm
~/.tmuxm/install.sh                 # picks a random colour for this machine
~/.tmuxm/install.sh --color '#3366cc'   # ...or choose one yourself
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
sources the config if tmux is running.

With no arguments it picks a **random colour, but only on a machine that doesn't have one
yet**. Re-running never changes a colour you already have — `update.sh` forwards its
arguments to `install.sh`, so a bare `update.sh` is the common case and it must not
repaint your machine on every update. To deliberately re-roll, use `--color random`.

## Update

```bash
~/.tmuxm/update.sh
```

Fast-forwards from origin, kills the running sampler so the new code is loaded, re-runs
`install.sh` (which sources tmux and respawns the sampler), then verifies the sampler is
alive and writing the cache. Arguments are forwarded, so `update.sh --color random` works.

`update.sh` never re-rolls a colour on its own — it forwards to `install.sh`, which only
picks randomly when the machine has no colour yet.

## The machine colour

This is the whole point of the bar. One colour per machine, kept, and you'll never again
run a command on the wrong box because two windows looked alike.

```bash
~/.tmuxm/install.sh                      # first install: generates a random colour
~/.tmuxm/install.sh --color '#3366cc'    # or pick any 24-bit colour
~/.tmuxm/install.sh --color random       # re-roll
```

**There is no palette.** No list of named colours exists in this repo, because a list is
just hardcoding with extra steps. You give it a hex, or it generates one. The only fixed
colour in the theme is the black the badge and metrics sit on.

Everything else is derived from that single colour, so you never hand-pick shades:

| Derived | How |
|---|---|
| Bar + window list background | the colour itself; text black or white by luminance |
| Active window | lightened if the colour is dark, darkened if light |
| Accent (badge, labels, bars, date) | the colour, **lifted** if too dark to read on black |
| Separators + inactive pane border | the accent at lightness 0.38 |
| `@host`, date, active pane border | the accent itself |

Reload with `tmux source ~/.tmux.conf` (or `C-a` then `:source ~/.tmux.conf`).

### How random works

Random means random — roughly 1.5 million reachable colours, not a draw from a list. The
generator picks a **uniform hue over the full circle**, a lightness inside the legible band,
and a chroma between 60% and 100% of the most that hue can hold in sRGB.

It works in **OKLCH**, and that choice is what makes a random hue safe. The classic recipe
([Ankerl][ankerl]) is "fix saturation and lightness, randomise hue" in HSL/HSV — right shape,
wrong space. HSL is not perceptually uniform, so a yellow and a blue at the same nominal
lightness differ wildly in apparent brightness, and "legible on black" would hold for some
hues and not others. In OKLCH, [equal lightness looks equally light at every hue][oklch], so
the guarantee holds for all 360 of them.

**The legible band is measured, not guessed.** Sweeping every hue at maximum chroma and
computing WCAG contrast against black:

| OKLCH L | worst hue | contrast | |
|---|---|---|---|
| 0.55 | 299° | 3.65:1 | fails |
| 0.61 | ~310° | 4.50:1 | **AA floor** |
| 0.65 | 322° | 5.49:1 | AA |
| 0.72 | ~328° | 7.28:1 | **AAA floor — used** |
| 0.90 | 326° | 15.01:1 | AAA |

The generator uses `L ∈ [0.72, 0.90]`. The floor is the AAA threshold; the ceiling is where
hues wash toward white and stop being tellable apart. Violet is consistently the worst case —
it carries the least luminance per unit of perceptual lightness.

A colour you supply yourself is used exactly as given for the bar, and lifted to the floor
only for drawing on black. `#ff69b4` (L=0.728) already clears it and is used untouched;
`#1e3a8a` (L=0.379) becomes `#79a1ff` for the badge and metrics while the bar stays navy.

### Load is shown by height, not colour

The CPU/MEM bars are the machine's colour at 1% and at 100%. Load is encoded by the height
of the blocks — `▁▂▃▄▅▆▇█` — which is a channel that survives every kind of colour-blindness,
and keeps one machine looking like one colour.

[ankerl]: https://martin.ankerl.com/2009/12/09/how-to-create-random-colors-programmatically/
[oklch]: https://colorarchive.org/guides/oklch-color-space-guide/

### What it writes, and what it won't touch

`--color` writes a marked block to `~/.tmux.local.conf`, which `tmux.conf` sources `-q` at
the very end. The file is **git-ignored**, so each machine carries its own.

```tmux
# >>> tmuxm colour (managed by install.sh --color) >>>
# Machine colour: #ff69b4 — regenerate with: ~/.tmuxm/install.sh --color '#ff69b4'
# Derived: accent #ff69b4, dim #7a004b, active #d80088
set -g status-style "bg=#ff69b4,fg=black"
set -g window-status-style "bg=#ff69b4,fg=black"
set -g window-status-current-style "bg=#d80088,fg=white,bold"
set -g pane-border-style "fg=#7a004b"
set -g pane-active-border-style "fg=#ff69b4"
set -g status-left "#[bg=#000000,fg=#ff69b4,bold] 🧙 AI Wizard 🔮 #[bg=#000000,fg=white] "
set -g status-right "#[bg=#000000,fg=#ff69b4] CPU #(bash ~/.tmuxm/bin/render-bar.sh cpu ff69b4) … %d/%m/%Y %H:%M #(bash ~/.tmuxm/bin/render-tz.sh) "
# <<< tmuxm colour <<<
```

This block is the **single source of truth for colour**. `tmux.conf` deliberately sets no
coloured option at all — it would be a second definition of the same thing, and whichever
loaded last would win. `tmux.conf` keeps only geometry (`status-left-length`,
`status-right-length`, `status-interval`) and behaviour.

> **Why the colour argument has no `#`.** tmux expands its legacy format shorthands *inside*
> `#(…)` before handing the command to the shell, and `#F` is one of them — window flags. So
> `'#FBBF24'` arrives at `render-bar.sh` as `'*BBF24'`, which isn't a colour, and the bar
> silently stops changing. Lowercase `#f` happens *not* to be a shorthand, so this fails for
> only some colours — which makes it very easy to miss. `install.sh` passes bare hex and
> `render-bar.sh` puts the `#` back.

Re-running `--color` rewrites **only** that block. Everything else in the file is left
alone — `~/.tmux.local.conf` is also where per-machine bits like the `xclip` copy-pipe
bindings live, and those survive. If the file already existed without the markers, it's
backed up to `~/.tmux.local.conf.bak.<timestamp>` before the block is appended.

> **Pitfall — don't hand-write theme lines.** Every coloured option is generated. A copy
> **outside** the markers sits later in the file, so tmux's last-wins rule makes it silently
> override the managed block and your machine colour stops applying.
>
> `install.sh` detects exactly this and prints the offending line numbers on every run, but
> never edits your file — delete them by hand, then re-run `--color`.

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
  The pidfile at `/tmp/tmuxm-sampler-$USER.pid` is claimed with `set -o noclobber`, which
  creates it atomically — a test-then-write would let two tmux servers starting in the same
  instant both pass the check and both run. If the claim fails and the recorded PID is
  alive, the new instance exits; if it is dead, the stale file is taken over. A sampler only
  clears the pidfile if it still owns it, so a loser never releases the winner's claim.
- **Stops promptly on SIGTERM** — `update.sh` stops the sampler before reloading tmux, which
  respawns it. The handler is trapped (so tmux never logs `terminated by signal 15`) and the
  interval `sleep` is backgrounded behind `wait`, so the signal is acted on in milliseconds
  rather than at the end of the current sleep. Without that, the old sampler can outlive
  `update.sh`'s wait, the replacement sees a live owner and exits, and you end up with **no
  sampler running** and a frozen status bar.
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
| `test.sh` | Test suite — run it from anywhere, exits 0 on success |
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
├── install.sh             # installer + --color, OKLCH colour engine
├── update.sh              # pull, restart sampler, verify
├── test.sh                # test suite
├── bin/
│   ├── sampler.sh         # background daemon, writes cache
│   ├── render-bar.sh      # cpu/mem/bat → bar in the machine colour
│   ├── render-net.sh      # net throughput → fixed-width string
│   └── render-tz.sh       # UTC offset → "-3 GMT"
├── .gitignore
└── README.md
```

[sysstat]: https://github.com/samoshkin/tmux-plugin-sysstat
