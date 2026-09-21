#!/usr/bin/env bash
# GPU presence and sampling — ONE definition, sourced by both install.sh (which
# decides whether the bar gets GPU segments at all) and bin/sampler.sh (which
# fills them). If those two could disagree you would get a segment that is
# permanently flat, so neither is allowed its own test.
#
# NVIDIA only, on Linux. A Mac, a box with just an Intel/AMD iGPU, or a card with
# no driver loaded reports nothing at all — and a bar with no GPU segments is
# exactly the intended result, not a degraded one.
#
# This file only defines functions: no `set`, no side effects at source time.

# NVIDIA display controllers, straight out of sysfs: vendor 0x10de, PCI class 03xx.
#
# Deliberately NOT derived from `nvidia-smi --query-gpu=pci.bus_id`, which prints an
# 8-digit domain (00000000:01:00.0) where sysfs writes 4 (0000:01:00.0). Normalising
# between the two is a trap for no gain — sysfs already knows the answer, and it
# knows it without loading the driver.
nvidia_pci_devices() {
  local d vendor class root
  # Overridable so the test suite can point at an empty tree and get the same
  # answer on every machine; nothing but tests ever sets it.
  root="${NVIDIA_SYSFS_DIR:-/sys/bus/pci/devices}"
  for d in "$root"/*; do
    [ -r "$d/vendor" ] && [ -r "$d/class" ] || continue
    read -r vendor < "$d/vendor" || continue
    read -r class  < "$d/class"  || continue
    [ "$vendor" = "0x10de" ] || continue
    case "$class" in 0x03*) printf '%s\n' "$d" ;; esac
  done
}

# True when there is at least one NVIDIA device and every one of them is parked.
#
# A Max-Q dGPU drops to D3cold when idle. nvidia-smi wakes it, and polling every
# INTERVAL seconds would hold it awake for the whole session — a real battery cost
# for a reading that is 0% anyway. Desktops never runtime-suspend, so they take the
# normal path.
gpu_all_suspended() {
  local d st any=0
  for d in $(nvidia_pci_devices); do
    any=1
    st="$(cat "$d/power/runtime_status" 2>/dev/null || true)"
    [ "$st" = "suspended" ] || return 1
  done
  [ "$any" = 1 ]
}

# Prints "<util%> <vram%>". Fails, silently and with no output, on any machine
# whose GPU cannot be read — which is what makes the metric optional everywhere
# else.
gpu_sample() {
  [ "$(uname -s)" = "Linux" ] || return 1
  command -v nvidia-smi >/dev/null 2>&1 || return 1

  # Parked: report idle without touching nvidia-smi, so the dGPU stays asleep.
  if gpu_all_suspended; then
    echo "0 0"
    return 0
  fi

  local out
  out="$(nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total \
                    --format=csv,noheader,nounits 2>/dev/null)" || return 1
  [ -n "$out" ] || return 1

  # One row per card. A card that cannot report a field prints "[N/A]", so a row
  # counts only when all three fields are numeric — better a missing metric than a
  # bar drawn from a string. With several cards, utilisation is the busiest one
  # ("is anything running?") and VRAM is pooled ("is there room left?").
  printf '%s\n' "$out" | awk -F'[,[:space:]]+' '
    $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ {
      if ($1 > util) util = $1
      used  += $2
      total += $3
      seen = 1
    }
    END {
      if (!seen || total == 0) exit 1
      printf "%d %d\n", util, used * 100 / total
    }
  '
}

# The honest presence test: if it cannot produce a reading, it gets no segment.
gpu_present() { gpu_sample >/dev/null 2>&1; }
