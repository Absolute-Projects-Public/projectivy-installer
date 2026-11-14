#!/usr/bin/env bash
# Does Plex come back on its own, and what does stopping it actually return?
set -u
SER="${SER:-192.168.1.101:5555}"
A="adb -s $SER"

echo "== before =="
$A shell "grep -E 'MemFree|MemAvailable|SwapFree' /proc/meminfo" | tr -d '\r' | sed 's/^/  /'
$A shell "ps -A -o RSS,NAME 2>/dev/null | grep -i plex" | tr -d '\r' | sed 's/^/  /'
echo "  plex boot receivers: $($A shell 'dumpsys package com.plexapp.android | grep -c BOOT_COMPLETED' | tr -d '\r')"

echo
echo "== stopping it (this is what happens when you back out of the app) =="
$A shell am force-stop com.plexapp.android
sleep 4
echo "  plex now: $($A shell 'ps -A -o RSS,NAME 2>/dev/null | grep -ci plex' | tr -d '\r') process(es)"

echo
echo "== after =="
$A shell "grep -E 'MemFree|MemAvailable|SwapFree' /proc/meminfo" | tr -d '\r' | sed 's/^/  /'

echo
echo "== what is holding ram now, top 12 =="
$A shell "ps -A -o RSS,NAME 2>/dev/null | sort -rn | head -12" | tr -d '\r' | sed 's/^/  /'

echo
echo "== does Plex come back if we leave it alone for 30s =="
sleep 30
echo "  plex: $($A shell 'ps -A -o RSS,NAME 2>/dev/null | grep -i plex' | tr -d '\r' | sed 's/^/    /' || echo '  still stopped')"
