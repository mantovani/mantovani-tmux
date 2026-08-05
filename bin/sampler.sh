#!/usr/bin/env bash
# Long-lived stats sampler for the tmux status bar.
# Samples cpu/mem/bat/net every INTERVAL seconds and atomically writes to
# /tmp/tmuxm-stats-$USER. Pidfile-guarded: only one sampler per user even
# with multiple tmux servers attached.
set -u

INTERVAL=2
CACHE="/tmp/tmuxm-stats-${USER}"
PIDFILE="/tmp/tmuxm-sampler-${USER}.pid"
OS="$(uname -s)"

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

read_net_bytes() {
  case "$OS" in
    Darwin)
      # netstat -ibn cols: Name Mtu Network Address Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll
      # The <Link#N> row holds the cumulative interface byte counters; other
      # rows are per-address subsets. Filter on $3 for stability.
      netstat -ibn 2>/dev/null | awk '
        $3 ~ /^<Link/ && $1 != "lo0" { ib += $7; ob += $10 }
        END { print ib+0, ob+0 }
      '
      ;;
    Linux)
      awk -F'[ :]+' 'NR>2 && $2!="lo" {ib+=$3; ob+=$11} END {print ib+0, ob+0}' /proc/net/dev
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

  {
    echo "cpu $cpu"
    echo "mem $mem"
    [ -n "${bat:-}" ] && echo "bat $bat"
    echo "net_in $net_in"
    echo "net_out $net_out"
  } > "$CACHE.tmp" && mv "$CACHE.tmp" "$CACHE"
done
