#!/usr/bin/env bash
# Print network throughput for one direction. Usage: net-speed.sh <in|out>
# Cross-platform: macOS (netstat -ibn) and Linux (/proc/net/dev).
# Per-direction state file in /tmp so in/out calls don't share state.
set -u

DIR="${1:-}"
case "$DIR" in in|out) ;; *) echo "usage: $0 <in|out>" >&2; exit 1 ;; esac

STATE_FILE="/tmp/tmux-net-speed-${USER}-${DIR}.state"

# Sum bytes across non-loopback interfaces.
case "$(uname -s)" in
  Darwin)
    # netstat -ibn columns: Name Mtu Network Address Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll
    # Skip header and lo0; skip duplicate rows per interface (netstat lists one per address).
    read -r ib ob < <(
      netstat -ibn 2>/dev/null | awk '
        NR==1 || $1=="lo0" { next }
        seen[$1]++         { next }
        { ib += $7; ob += $10 }
        END { print ib+0, ob+0 }
      '
    )
    ;;
  Linux)
    # /proc/net/dev columns: iface: rx_bytes rx_pkts ... tx_bytes tx_pkts ...
    read -r ib ob < <(
      awk -F'[ :]+' 'NR>2 && $2!="lo" {ib+=$3; ob+=$11} END {print ib+0, ob+0}' /proc/net/dev
    )
    ;;
  *)
    printf "  ?  "
    exit 0
    ;;
esac

case "$DIR" in
  in)  cur=$ib ;;
  out) cur=$ob ;;
esac

now=$(date +%s)
prev_t=$now
prev=$cur
[ -r "$STATE_FILE" ] && read -r prev_t prev < "$STATE_FILE"
echo "$now $cur" > "$STATE_FILE"

dt=$(( now - prev_t ))
(( dt <= 0 )) && dt=1
bps=$(( (cur - prev) / dt ))
(( bps < 0 )) && bps=0

awk -v b="$bps" 'BEGIN {
  if      (b < 1024)       printf "%4dB/s",   b
  else if (b < 1048576)    printf "%5.1fKB/s", b/1024
  else if (b < 1073741824) printf "%5.1fMB/s", b/1048576
  else                     printf "%5.1fGB/s", b/1073741824
}'
