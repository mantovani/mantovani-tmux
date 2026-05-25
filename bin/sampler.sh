#!/usr/bin/env bash
# Long-lived stats sampler for the tmux status bar.
# Samples cpu/mem/bat/net every INTERVAL seconds and atomically writes to
# /tmp/tmux-stats-$USER. Pidfile-guarded: only one sampler per user even
# with multiple tmux servers attached.
set -u

INTERVAL=2
CACHE="/tmp/tmux-stats-${USER}"
PIDFILE="/tmp/tmux-sampler-${USER}.pid"
OS="$(uname -s)"

# Single-instance guard
if [ -r "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
  exit 0
fi
echo $$ > "$PIDFILE"
trap 'rm -f "$PIDFILE"' EXIT

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

read_cpu() {
  case "$OS" in
    Darwin)
      top -l1 -n0 2>/dev/null | awk '/CPU usage/ {
        gsub("%",""); printf "%d", $3+$5
      }'
      ;;
    Linux)
      awk '/^cpu / {
        idle=$5; total=0
        for (i=2;i<=8;i++) total+=$i
        if (total==0) {print 0; exit}
        printf "%d", 100 - (idle*100/total)
      }' /proc/stat
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

while :; do
  sleep "$INTERVAL"
  now=$(date +%s)
  read ib ob <<< "$(read_net_bytes)"
  dt=$(( now - prev_t )); (( dt <= 0 )) && dt=1
  net_in=$(( (ib - prev_ib) / dt )); (( net_in < 0 )) && net_in=0
  net_out=$(( (ob - prev_ob) / dt )); (( net_out < 0 )) && net_out=0
  prev_ib=$ib; prev_ob=$ob; prev_t=$now

  cpu=$(read_cpu); cpu=${cpu:-0}
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
