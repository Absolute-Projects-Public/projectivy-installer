#!/usr/bin/env bash
# Firestick memory: the OS's own totals, and who holds the RAM.
set -u
SER="${SER:-192.168.1.101:5555}"
A="adb -s $SER"

echo "== the OS's totals =="
$A shell dumpsys meminfo 2>/dev/null | sed -n '1,12p' | tr -d '\r' | sed 's/^/  /'

echo
echo "== total and free, from /proc =="
$A shell "cat /proc/meminfo 2>/dev/null | head -6" | tr -d '\r' | sed 's/^/  /'

echo
echo "== top 20 processes by PSS (the number that matters) =="
$A shell dumpsys meminfo 2>/dev/null | awk '
  /^ *[0-9]+ kB: / { }
  /^ *[0-9]+ kB:/ { }
  /[0-9]+ *kB: *[A-Za-z\._0-9]+/ { print }
' | head -5 | sed 's/^/  /'
$A shell "dumpsys meminfo 2>/dev/null | grep -E 'kB: ' | sort -k2 -rn | head -22" | tr -d '\r' | sed 's/^/  /'

echo
echo "== third-party processes running right now =="
$A shell "ps -A -o PID,RSS,NAME 2>/dev/null | sort -k2 -rn | head -24" | tr -d '\r' | sed 's/^/  /'

echo
echo "== services running (foreground ones cost the most) =="
$A shell "dumpsys activity services 2>/dev/null | grep -E 'ServiceRecord\{' | sed 's/.*u0 //' | sort -u | head -20" | tr -d '\r' | sed 's/^/  /'

echo
echo "== what is already disabled (so we do not suggest it twice) =="
$A shell pm list packages -d 2>/dev/null | sed 's/package://' | tr -d '\r' | tr '\n' ' ' | fold -w 100 | sed 's/^/  /'
