# tmuxm

Portable tmux config. **AI Wizard** theme: a badge on the left, live system metrics on
the right, and **one colour per machine running through all of it** — so a glance at the
bar tells you which box you're on. Every machine picks its own colour on first install.
Cross-platform (macOS & Linux).

## What it looks like

```
 🧙 AI Wizard 🔮 │ 1:zsh* 2:vim 3:logs        CPU █▁▁▁  23% │ MEM ███▂  79% │ ↓ 99.3K ↑  1.9K │ @host │ 25/05/2026 13:14 -3
└── status-left ─┘└─── window list ────┘         └──────────────────── status-right (metrics) ─────────────────────┘
   black end-cap      machine colour                          black end-cap, machine colour
```

The black end-caps are fixed so the bar has a constant frame; everything drawn *on* them
takes the machine colour.

On a machine with an NVIDIA GPU, two more segments sit between `MEM` and the network:

```
 … │ MEM ███▂  79% │ GPU ██▂▁  54% │ VRAM ██▄▁  61% │ ↓ 99.3K ↑  1.9K │ …
                     └── only where there is one ───┘
```

`GPU` is how busy it is, `VRAM` how full its memory is — `CPU`/`MEM` one level down, drawn
the same way. Everywhere else the bar is **exactly** the one above: no segment, no
placeholder, no flat `0%`. See [GPU and VRAM](#gpu-and-vram).

| Segment | Colour |
|---|---|
| `🧙 AI Wizard 🔮` badge | the accent, bold, on black |
| **Window list** | the machine colour; current window on the active shade |
| Bar background | the machine colour |
| CPU/MEM/GPU/VRAM bars | the accent — the *same* at 1% and at 100% |
| Net throughput | the accent. Fixed-width 6 chars (`    0B` / ` 99.3K` / `  1.2M`) |
| `@host` | the accent, bold |
| Date + UTC offset | the accent, bold. European `dd/mm/yyyy hh:mm`, then the UTC offset `-3` |
| `│` separators, pane borders | the accent, dimmed |

**Black is the only fixed colour in the theme.** Everything else on the bar is that one
machine colour or a shade derived from it.

Under load the bars fill; the colour does not change:
```
 🧙 AI Wizard 🔮 │ windows…        CPU ███▅  88% │ MEM ████  95% │ ↓18.4M ↑ 2.1M │ @host │ 25/05/2026 13:14 -3
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

**You need a Rust toolchain.** The status bar is a small binary built from source on
install — nothing prebuilt is downloaded, so `cargo` has to be there
(`curl https://sh.rustup.rs -sSf | sh`). Minimum supported Rust is **1.75**.

`install.sh` is idempotent: links `~/.tmuxm`, backs up a pre-existing `~/.tmux.conf`
and symlinks the new one, builds `bin/tmuxm`, clones
[TPM](https://github.com/tmux-plugins/tpm) if missing, and sources the config if tmux is
running. Upgrading from the shell version, it also stops the background sampler that
version ran — a daemon does not exit just because its script was deleted.

With no arguments it picks a **random colour, but only on a machine that doesn't have one
yet**. Re-running never changes a colour you already have — `update.sh` forwards its
arguments to `install.sh`, so a bare `update.sh` is the common case and it must not
repaint your machine on every update. To deliberately re-roll, use `--color random`.

## Update

```bash
~/.tmuxm/update.sh
```

Fast-forwards from origin, re-runs `install.sh` (which rebuilds `bin/tmuxm` and sources
tmux), then verifies the binary runs. There is no process to stop or restart. Arguments are
forwarded, so `update.sh --color random` works.

`update.sh` never re-rolls a colour on its own — it forwards to `install.sh`, which only
picks randomly when the machine has no colour yet.

## GPU and VRAM

Two extra segments, `GPU` (how busy it is) and `VRAM` (how full its memory is), drawn
exactly like `CPU` and `MEM`. **Only on a machine that has a GPU** — everywhere else the
bar is byte-for-byte the one it has always been.

```bash
nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total --format=csv
```

is the whole source. That means **NVIDIA on Linux, and nothing else**: an Intel or AMD
iGPU, a Mac, a card whose driver isn't loaded — all of them get today's bar. The iGPU
case is deliberate rather than lazy; the readings its sysfs offers are clock frequencies,
not utilisation, and a segment that means something different per machine is worse than no
segment.

**A machine without a GPU sees no difference at all** — no segment to hide, no `0%` to
explain. The generated `status-right` is identical on every machine; only what the binary
prints differs.

Presence is a **runtime** fact: the binary draws the whole metric block, so it decides on
each refresh. A machine that gains a GPU shows it on the next redraw — no re-install, and
nothing to keep in sync between an installer and a sampler.

### A sleeping GPU is left asleep

A Max-Q laptop dGPU parks in D3cold when idle. `nvidia-smi` **wakes it**, so polling every
2 s would hold it awake for an entire session — real battery cost for a reading that is 0%
anyway. So `power/runtime_status` on the NVIDIA PCI devices is checked first, and idle is
reported without waking anything when they are all suspended. Desktops never
runtime-suspend and take the direct path.

The devices come from sysfs (`vendor 0x10de`, PCI class `03xx`) rather than from
`nvidia-smi --query-gpu=pci.bus_id`, which prints an 8-digit domain (`00000000:01:00.0`)
where sysfs writes four (`0000:01:00.0`).

### Several cards, and cards that won't answer

`GPU` is the **busiest** card (is anything running?) and `VRAM` is the **pooled** total
(is there room left?). A card that cannot report a field prints `[N/A]`; rows count only
when all three fields are numeric, and if none are, the metric is absent rather than
invented — better a bar you don't have than a bar drawn from a string.

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

The CPU/MEM/GPU/VRAM bars are the machine's colour at 1% and at 100%. Load is encoded by the height
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
set -g status-right "#[bg=#000000,fg=#ff69b4]#(~/.tmuxm/bin/tmuxm render ff69b4 7a004b) … %d/%m/%Y %H:%M #(~/.tmuxm/bin/tmuxm tz) "
# <<< tmuxm colour <<<
```

This block is the **single source of truth for colour**. `tmux.conf` deliberately sets no
coloured option at all — it would be a second definition of the same thing, and whichever
loaded last would win. `tmux.conf` keeps only geometry (`status-left-length`,
`status-right-length`, `status-interval`) and behaviour.

> **Why the colour argument has no `#`.** tmux expands its legacy format shorthands *inside*
> `#(…)` before handing the command to the shell, and `#F` is one of them — window flags. So
> `'#FBBF24'` arrives at the binary as `'*BBF24'`, which isn't a colour, and the bar
> silently stops changing. Lowercase `#f` happens *not* to be a shorthand, so this fails for
> only some colours — which makes it very easy to miss. `install.sh` passes bare hex and
> the binary puts the `#` back.

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

One binary, run by tmux on its own refresh. There is no background process.

```
   tmux status-right, every status-interval (2 s)
        │
        ├──► bin/tmuxm render <accent> <dim>          ~1.6 ms
        │      ├─ /proc/stat, /proc/meminfo, /proc/net/dev      0.08 ms
        │      ├─ NVML, when the cached reading has expired    ~21.7 ms
        │      ├─ diff against /tmp/tmuxm-state-$USER  (monotonic ns)
        │      └─ print the metric block, exit
        │
        └──► bin/tmuxm tz                             ~0.8 ms
               └─ localtime_r().tm_gmtoff → "-3"
```

Two processes per refresh. It used to be fourteen: seven `bash` interpreters,
each forking an `awk` or a `date`, plus a long-lived bash daemon sampling in
parallel.

### Why there is no daemon

The daemon existed for one reason: a rate needs a previous reading, and a shell
script that exits cannot remember one. So it held a pidfile claimed under
`noclobber`, took over stale claims, trapped `TERM` so `update.sh` could stop it,
backgrounded its own `sleep` so the trap fired promptly, and clamped a
deadline-based sleep at both ends so a backward clock step could not park it.
Every one of those mechanisms was there to keep a process alive so it could
remember four numbers.

`/tmp/tmuxm-state-$USER` remembers them instead:

```
ts 103428778033098     ← CLOCK_MONOTONIC nanoseconds
cpu_idle 197926265
cpu_total 226071754
net_rx 16578226068
net_tx 2833138310
gpu_at 103428778033098
gpu 0
vram 56
```

Written to a temp file and renamed, so a reader never sees a partial one. Two
tmux servers rendering at the same instant race by design; the loser costs one
skewed interval, never a torn read.

### Monotonic time, and the bug that motivated this

The shell divided byte deltas by the difference of two `date +%s` readings.
Whole seconds cannot express the interval they measure: a real 1.05 s gap was
still divided by 2, and the throughput came out at half. Measured
interval-by-interval against `/proc/net/dev`, individual samples ranged from
**0.52 to 1.27** of the true rate — accurate when integrated over a minute,
wrong on almost every individual reading.

`CLOCK_MONOTONIC` is system-wide and immune to NTP, so two separate processes
can subtract each other's timestamps. The same audit against the binary: **0.95
to 1.03**, with the 1.05 s intervals — the exact case that used to read 0.52 —
landing on 0.99.

### The GPU reading is cached, and why

NVML is what `nvidia-smi` is built on, so reading it directly avoids a 23 ms
fork. But in a *fresh* process NVML costs ~21.7 ms of its own, almost all of it
mapping and relocating `libnvidia-ml.so` — a cost a daemon pays once and a
stateless binary would pay on every refresh. Measured, that made the render
path slower than the shell it replaced.

So the reading is carried in the state file and refreshed when it is older than
six seconds. NVML is asked on roughly every third render; the GPU number is at
most six seconds behind, and the average render costs ~8 ms instead of 23 ms.

| path | cost |
|---|---|
| `render`, GPU reading still fresh | **1.6 ms** |
| `render`, NVML consulted | 23.3 ms |
| `tz` | 0.8 ms |
| *average at a 2 s refresh* | **~8 ms** |
| *the shell this replaced* | 17.8 ms render **+ 32 ms daemon** |

### Cross-platform

`#[cfg(target_os = ...)]`, never `target_arch` — nothing in these six numbers is
architecture-dependent. The one real trap is assuming a page size, and the macOS
path reads it rather than assuming it.

| | Linux | macOS |
|---|---|---|
| CPU | `/proc/stat`, fields 2..9 | `host_statistics64(HOST_CPU_LOAD_INFO)` |
| MEM | `MemTotal - MemAvailable` | `HOST_VM_INFO64` over `sysctl hw.memsize` |
| Net | `/proc/net/dev`, interfaces with a `/sys/class/net/<if>/device` symlink | `getifaddrs`, `if_data64`, filtered on `sdl_type` |
| GPU | NVML via `dlopen` | not available |

Two bugs the shell had to fix by hand cannot occur here, because both were
text-parsing bugs and there is no text: `/proc/net/dev`'s 6-character name
padding used to shift every column, and `netstat` suffixes `*` to an interface
that is down, which silently un-skipped it. `getifaddrs` hands over a name, a
type and two integers.

## File locations

| Path | Purpose |
|---|---|
| `~/.tmuxm` | The clone, or a symlink to it (created by `install.sh`) |
| `~/.tmux.conf` | Symlink → `~/.tmuxm/tmux.conf` |
| `~/.tmux.conf.bak.<timestamp>` | Backup of a pre-existing `~/.tmux.conf` |
| `rust/` | The renderer's source |
| `bin/tmuxm` | The built binary — **git-ignored**; every machine builds its own |
| `test.sh` | Shell suite (installer, colour engine, generated block) |
| `~/.tmux.local.conf` | **Per-machine colour + overrides** — not tracked in git |
| `~/.tmux.local.conf.bak.<timestamp>` | Backup made the first time `--color` touches an existing file |
| `~/.tmux/plugins/tpm/` | TPM (cloned by `install.sh`) |
| `/tmp/tmuxm-state-$USER` | Previous sample (~8 lines); recreated if deleted |

## Requirements

| Component | Version | Notes |
|---|---|---|
| `tmux` | ≥ 2.1 | |
| `cargo` / `rustc` | **≥ 1.75** | the bar is built from source on install |
| `bash` | ≥ 3.2 | for `install.sh` only; macOS stock bash is fine |
| `git` | any | for the TPM clone |
| `awk` | any | the OKLCH colour engine; BWK awk (macOS stock) included |
| `nvidia-smi` driver | optional | supplies `libnvidia-ml.so`; without it, no GPU segments |
| Terminal | UTF-8, supports `▁▂▃▄▅▆▇█`, emoji | iTerm2 / WezTerm / Ghostty / Kitty / Alacritty / GNOME Terminal all fine |

Nothing is downloaded prebuilt, so the **oldest toolchain in your fleet sets the
floor**. The MSRV is 1.75 — what Debian and Ubuntu ship — and CI builds at
exactly that version so it cannot drift upward by accident.

A metric the machine cannot report is omitted rather than zeroed: no GPU means
no `GPU`/`VRAM` segments at all, not a flat `0%`.

## Resource usage

Measured on Linux/x86_64 with an NVIDIA dGPU:

| | |
|---|---|
| Processes per refresh | **2** (was 14, plus a daemon) |
| Render, GPU reading fresh | 1.6 ms |
| Render, NVML consulted | 23.3 ms (≈ every third refresh) |
| Average cost per 2 s refresh | **~8 ms** (was ~50 ms) |
| Resident processes between refreshes | **0** (was 1) |
| Binary size | 455 KB |
| State file | ~120 bytes |

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
├── install.sh             # installer + --color, OKLCH colour engine, cargo build
├── update.sh              # pull, rebuild, verify
├── test.sh                # shell suite; runs the Rust suite too
├── rust/
│   ├── Cargo.toml
│   └── src/
│       ├── main.rs        # render | tz
│       ├── bar.rs         # blocks, gauges, throughput, offset
│       ├── state.rs       # the previous sample
│       ├── gpu.rs         # NVML via dlopen
│       └── metrics/
│           ├── mod.rs     # rates and percentages
│           ├── linux.rs   # /proc, /sys
│           ├── darwin.rs  # macOS arithmetic — built everywhere, so it is tested
│           └── macos.rs   # macOS syscalls
├── .github/workflows/ci.yml
├── .gitignore
└── README.md
```

[sysstat]: https://github.com/samoshkin/tmux-plugin-sysstat
