#!/usr/bin/env bash
# Clean measurement: what the stick costs idle, and the exact reason diode will not disable.
set -u
SER="${SER:-192.168.1.101:5555}"
A="adb -s $SER"

echo "== full error from diode (no trimming this time) =="
$A shell "pm disable-user --user 0 com.amazon.diode" 2>&1 | tr -d '\r' | sed 's/^/  /'
echo "  still disabled? $($A shell pm list packages -d 2>/dev/null | grep -c 'com.amazon.diode' | tr -d '\r')"

echo
echo "== whisperjoin v2 (the one that worked) =="
echo "  in the disabled list: $($A shell pm list packages -d 2>/dev/null | grep -c 'whisperjoin.middleware.v2' | tr -d '\r')"
echo "  process running:      $($A shell ps -A 2>/dev/null | grep -c 'whisperjoin.middleware.v2')"

echo
echo "== back to the launcher, then measure idle =="
$A shell input keyevent KEYCODE_HOME >/dev/null 2>&1
sleep 25
echo "  on screen: $($A shell dumpsys window 2>/dev/null | grep -m1 mCurrentFocus | sed 's/.*u0 //;s/}.*//')"
$A shell "grep -E 'MemFree|MemAvailable|SwapFree' /proc/meminfo" | tr -d '\r' | sed 's/^/  /'
echo "  top 10:"
$A shell "ps -A -o RSS,NAME 2>/dev/null | sort -rn | head -10" | tr -d '\r' | sed 's/^/    /'

echo
echo "== and 60s later, with the screensaver up (what it costs while nobody is using it) =="
sleep 60
echo "  on screen: $($A shell dumpsys window 2>/dev/null | grep -m1 mCurrentFocus | sed 's/.*u0 //;s/}.*//')"
$A shell "grep -E 'MemFree|MemAvailable|SwapFree' /proc/meminfo" | tr -d '\r' | sed 's/^/  /'
echo "  top 7:"
$A shell "ps -A -o RSS,NAME 2>/dev/null | sort -rn | head -7" | tr -d '\r' | sed 's/^/    /'
