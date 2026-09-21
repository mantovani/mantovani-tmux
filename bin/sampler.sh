#!/usr/bin/env bash
# Long-lived stats sampler for the tmux status bar.
# Samples cpu/mem/bat/gpu/net every INTERVAL seconds and atomically writes to
# /tmp/tmuxm-stats-$USER. Pidfile-guarded: only one sampler per user even
# with multiple tmux servers attached.
set -u

INTERVAL=2
CACHE="/tmp/tmuxm-stats-${USER}"
PIDFILE="/tmp/tmuxm-sampler-${USER}.pid"
OS="$(uname -s)"

# GPU detection, shared verbatim with install.sh so the two can never disagree
# about whether this machine has one. Sourced relative to this script, which keeps
# the sampler location-independent; absent, the gpu/vram keys are simply never
# written and the bar is unaffected.
_GPU_LIB="${BASH_SOURCE[0]%/*}/gpu.sh"
[ -r "$_GPU_LIB" ] && . "$_GPU_LIB"

# Single-instance guard. Creating the pidfile under `noclobber` is atomic;
# test-then-write is not. Two tmux servers starting in the same instant would
# both see no pidfile, both write, and both run — and the loser's PID would be
# the one recorded, leaving an orphan that no later run can find or reap.
claim_pidfile() { ( set -o noclobber; echo $$ > "$PIDFILE" ) 2>/dev/null; }

if ! claim_pidfile; then
  owner="$(cat "$PIDFILE" 2>/dev/null || true)"
  if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
    exit 0                    # a live sampler already owns it
  fi
  rm -f "$PIDFILE"            # stale pidfile from a sampler that was killed -9
  claim_pidfile || exit 0     # someone else won the retry; let them have it
fi

# Only clear the pidfile if it is still ours. A sampler that lost a race must
# never delete the winner's claim.
trap '[ "$(cat "$PIDFILE" 2>/dev/null)" = "$$" ] && rm -f "$PIDFILE"' EXIT

# update.sh stops the running sampler with SIGTERM before restarting it.
# Handling it means we exit 0 rather than dying by the signal, so tmux stops
# logging "'bash ~/.tmuxm/bin/sampler.sh' terminated by signal 15" — and, more
# importantly, we exit *promptly*: update.sh only waits about a second for the
# pidfile to clear, and a sampler still sitting in `sleep` past that window
# makes the replacement think a live sampler is present and quietly give up,
# leaving no sampler running at all.
trap 'exit 0' TERM INT

# Summing every interface double-counts. A packet to a container or over a VPN
# crosses the overlay device (docker0, veth*, tun0, utun3) *and* the physical
# NIC it ultimately leaves through, so a naive total reports twice the real
# throughput. Count only the hardware interfaces: overlay-only traffic is still
# measured, because it has to cross a NIC to reach the network at all.

# Linux: a netdev backed by real hardware has a /sys/class/net/<if>/device
# symlink. Virtual ones — lo, docker0, veth*, br-*, bond0, tun0, wg0 and VLAN
# sub-interfaces — do not. Re-read each sample so hotplug (USB tethering, a
# docked NIC) is picked up without restarting the sampler.
linux_phys_ifaces() {
  local d n out=""
  for d in /sys/class/net/*; do
    n="${d##*/}"
    [ "$n" = "*" ] && continue          # glob didn't match: no /sys/class/net
    [ -e "$d/device" ] && out="$out $n"
  done
  printf '%s' "${out# }"
}

read_net_bytes() {
  case "$OS" in
    Darwin)
      # netstat -ibn cols: Name Mtu Network Address Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll
      # The <Link#N> row holds the cumulative interface byte counters; other
      # rows are per-address subsets. Filter on $3 for stability.
      #
      # macOS has no /sys, and every virtual device still reports a hardware
      # address, so there is no structural "is this real hardware" test to
      # apply — the names are the only signal. Skip the overlay prefixes:
      # utun/ipsec/gif/stf (VPN and tunnels), bridge/vmenet/ap (VM and
      # internet-sharing bridges), awdl/llw (AirDrop/low-latency radios, which
      # carry no internet traffic and whose bytes are already counted on the
      # Wi-Fi interface they share).
      #
      # Skipping them also keeps the column numbers honest: a row for an
      # interface with no link-layer address (lo0, utun*, gif*) omits the
      # Address column entirely and shifts Ibytes/Obytes one field left. Every
      # interface left after the filter is real hardware, so it has a MAC and
      # the full column set.
      netstat -ibn 2>/dev/null | awk '
        $3 ~ /^<Link/ &&
        $1 !~ /^(lo|gif|stf|utun|ipsec|bridge|vmenet|ap|awdl|llw)[0-9]*$/ {
          ib += $7; ob += $10
        }
        END { print ib+0, ob+0 }
      '
      ;;
    Linux)
      # /proc/net/dev right-pads the interface name into a 6-char column, so
      # short names ("    lo:", "  wlo1:") arrive with leading whitespace and
      # longer ones ("enp1s0:", "docker0:") do not. Splitting on /[ :]+/ made
      # the field numbers depend on that padding: the leading separator created
      # an empty $1 for short names but not for long ones, shifting every
      # column by one and making us read RX/TX *packets* as bytes on exactly
      # the interfaces that carry real traffic. Normalise instead: turn the
      # name's colon into a space and let awk's default whitespace splitting
      # handle the padding, so the columns are positional on every line.
      #
      # An empty `want` means no hardware interface exists — we are inside a
      # container or a network namespace, where eth0 is itself a veth. There is
      # nothing to double-count there, so fall back to summing every non-lo
      # interface rather than reporting a flat zero.
      awk -v want="$(linux_phys_ifaces)" '
        BEGIN { filter = (want != "") }
        NR>2 {
          sub(/:/, " ")
          if ($1 == "lo") next
          if (filter && index(" " want " ", " " $1 " ") == 0) next
          ib += $2; ob += $10
        }
        END { print ib+0, ob+0 }
      ' /proc/net/dev
      ;;
    *)
      echo "0 0"
      ;;
  esac
}

_PREV_CPU_IDLE=0
_PREV_CPU_TOTAL=0

# Linux: cumulative "idle total" tick counters from /proc/stat.
_linux_cpu_snapshot() {
  awk '/^cpu / {
    t=0; for (i=2;i<=8;i++) t+=$i
    print $5, t
  }' /proc/stat
}

# Sets the global CPU. Must NOT be called via $(...) — the Linux branch keeps
# delta state in globals (_PREV_CPU_{IDLE,TOTAL}) that a subshell would discard.
read_cpu() {
  case "$OS" in
    Darwin)
      # macOS 26 (Tahoe) removed sysctl kern.cp_time. iostat -c does its own
      # 1-second internal delta; the second (tail) row is the real sample.
      # Cost ~1 s per call — fine in the background sampler.
      CPU=$(iostat -c 2 -w 1 -n 0 2>/dev/null | tail -1 | awk '{
        c = 100 - $3
        if (c < 0)   c = 0
        if (c > 100) c = 100
        printf "%d", c
      }')
      ;;
    Linux)
      local idle total d_idle d_total
      read idle total < <(_linux_cpu_snapshot)
      : "${idle:=0}" "${total:=0}"
      d_idle=$(( idle - _PREV_CPU_IDLE ))
      d_total=$(( total - _PREV_CPU_TOTAL ))
      _PREV_CPU_IDLE=$idle
      _PREV_CPU_TOTAL=$total
      if (( d_total <= 0 )); then CPU=0; return; fi
      CPU=$(( 100 - (d_idle * 100 / d_total) ))
      (( CPU < 0 )) && CPU=0
      (( CPU > 100 )) && CPU=100
      ;;
  esac
}

read_mem() {
  case "$OS" in
    Darwin)
      vm_stat 2>/dev/null | awk '
        /Pages free/        {gsub(/[^0-9]/,"",$3); free=$3}
        /Pages active/      {gsub(/[^0-9]/,"",$3); active=$3}
        /Pages inactive/    {gsub(/[^0-9]/,"",$3); inactive=$3}
        /Pages speculative/ {gsub(/[^0-9]/,"",$3); spec=$3}
        /Pages wired/       {gsub(/[^0-9]/,"",$4); wired=$4}
        /Pages occupied by compressor/ {gsub(/[^0-9]/,"",$5); compr=$5}
        END {
          total=free+active+inactive+spec+wired+compr
          if (total==0) {print 0; exit}
          used=active+wired+compr
          printf "%d", used*100/total
        }
      '
      ;;
    Linux)
      awk '
        /^MemTotal:/     {total=$2}
        /^MemAvailable:/ {avail=$2}
        END {
          if (total==0) {print 0; exit}
          printf "%d", (total-avail)*100/total
        }
      ' /proc/meminfo
      ;;
  esac
}

read_bat() {
  case "$OS" in
    Darwin)
      pmset -g batt 2>/dev/null | grep -Eo '[0-9]+%' | head -1 | tr -d '%'
      ;;
    Linux)
      for b in /sys/class/power_supply/BAT*; do
        [ -r "$b/capacity" ] && { cat "$b/capacity"; return; }
      done
      ;;
  esac
}

# Sets GPU and VRAM, or leaves both empty on a machine without a readable GPU.
# Globals rather than stdout because there are two values and splitting a string
# back apart at the call site would be the only thing gained by printing.
GPU=""
VRAM=""
read_gpu() {
  GPU=""
  VRAM=""
  command -v gpu_sample >/dev/null 2>&1 || return 0
  local out
  out="$(gpu_sample)" || return 0
  read -r GPU VRAM <<EOF
$out
EOF
}

# Baseline so the first delta isn't a huge spike
prev_t=$(date +%s)
read prev_ib prev_ob <<< "$(read_net_bytes)"
# Prime Linux's delta counters (Darwin's iostat is self-priming)
CPU=0
[ "$OS" = "Linux" ] && read_cpu

while :; do
  # Backgrounded so a trapped signal interrupts `wait` immediately. A plain
  # `sleep` would defer the TERM handler until the sleep finished — measured at
  # up to INTERVAL seconds, which is longer than update.sh waits for us to go.
  sleep "$INTERVAL" & wait $! 2>/dev/null || true
  now=$(date +%s)
  read ib ob <<< "$(read_net_bytes)"
  dt=$(( now - prev_t )); (( dt <= 0 )) && dt=1
  net_in=$(( (ib - prev_ib) / dt )); (( net_in < 0 )) && net_in=0
  net_out=$(( (ob - prev_ob) / dt )); (( net_out < 0 )) && net_out=0
  prev_ib=$ib; prev_ob=$ob; prev_t=$now

  read_cpu; cpu=${CPU:-0}
  mem=$(read_mem); mem=${mem:-0}
  bat=$(read_bat || true)
  read_gpu

  # A metric the machine does not have is omitted, never written as zero — a
  # renderer reading a missing key already falls back to 0, and writing it would
  # be indistinguishable from a real idle reading.
  #
  # Order is load-bearing. The `&&` below binds to the exit status of the whole
  # group, which is the status of its LAST command, and a guarded `[ -n … ] &&
  # echo` returns 1 when the metric is absent. An optional key placed last would
  # therefore skip the mv on exactly the machines that lack it, and freeze the
  # cache for good. The two unconditional net lines have to stay at the end.
  {
    echo "cpu $cpu"
    echo "mem $mem"
    [ -n "${bat:-}" ]  && echo "bat $bat"
    [ -n "${GPU:-}" ]  && echo "gpu $GPU"
    [ -n "${VRAM:-}" ] && echo "vram $VRAM"
    echo "net_in $net_in"
    echo "net_out $net_out"
  } > "$CACHE.tmp" && mv "$CACHE.tmp" "$CACHE"
done
