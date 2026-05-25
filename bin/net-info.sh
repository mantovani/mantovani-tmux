#!/usr/bin/env bash
# Print active default interface + SSID (if WiFi), styled in matrix green.
# Usage: net-info.sh
set -u

iface=$(route -n get default 2>/dev/null | awk '/interface:/ {print $2}')

if [ -z "${iface:-}" ]; then
  printf "#[fg=#FF0000,bold]offline#[fg=default,nobold]"
  exit 0
fi

# Only WiFi interfaces return an SSID; wired returns empty.
ssid=$(networksetup -getairportnetwork "$iface" 2>/dev/null \
  | sed -n 's/^Current Wi-Fi Network: //p')

if [ -n "$ssid" ]; then
  printf "#[fg=#00FF41]%s #[fg=#003B00]◉#[fg=#39FF14] %s#[fg=default]" "$iface" "$ssid"
else
  printf "#[fg=#00FF41]%s#[fg=default]" "$iface"
fi
