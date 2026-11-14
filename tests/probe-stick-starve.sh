#!/usr/bin/env bash
# diode cannot be disabled, so starve it the same way the tool does for protected packages.
set -u
SER="${SER:-192.168.1.101:5555}"
A="adb -s $SER"
PKG=com.amazon.diode

uid=$($A shell "dumpsys package $PKG | grep -m1 userId=" | tr -d '\r' | sed 's/.*userId=//')
echo "== $PKG (uid $uid) =="
echo "  before:"
echo "    appops RUN_IN_BACKGROUND: $($A shell "appops get $PKG RUN_IN_BACKGROUND" 2>&1 | tr -d '\r' | tr '\n' ' ')"
echo "    netpolicy restrict-background: $($A shell 'cmd netpolicy list restrict-background-blacklist' 2>&1 | tr -d '\r' | tr '\n' ' ')"

$A shell "appops set $PKG RUN_IN_BACKGROUND deny" >/dev/null 2>&1
$A shell "appops set $PKG RUN_ANY_IN_BACKGROUND deny" >/dev/null 2>&1
[ -n "$uid" ] && $A shell "cmd netpolicy add restrict-background-blacklist $uid" >/dev/null 2>&1

echo "  after:"
echo "    appops RUN_IN_BACKGROUND:     $($A shell "appops get $PKG RUN_IN_BACKGROUND" 2>&1 | tr -d '\r' | tr '\n' ' ')"
echo "    appops RUN_ANY_IN_BACKGROUND: $($A shell "appops get $PKG RUN_ANY_IN_BACKGROUND" 2>&1 | tr -d '\r' | tr '\n' ' ')"
echo "    netpolicy restrict-background: $($A shell 'cmd netpolicy list restrict-background-blacklist' 2>&1 | tr -d '\r' | tr '\n' ' ')"
echo "    process running now: $($A shell ps -A 2>/dev/null | grep -c diode)"

echo
echo "== the other protected ones: are they already starved on this stick? =="
for p in com.amazon.device.metrics com.amazon.device.crashmanager com.amazon.device.rdmapplication \
         com.amazon.ftvads.deeplinking com.amazon.tv.csapp com.amazon.device.software.ota; do
  op=$($A shell "appops get $p RUN_IN_BACKGROUND" 2>&1 | tr -d '\r' | head -1)
  printf '  %-44s %s\n' "$p" "${op:-<no appops entry>}"
done

echo
echo "== device still fine? =="
$A shell input keyevent KEYCODE_HOME >/dev/null 2>&1
sleep 4
echo "  on screen: $($A shell dumpsys window 2>/dev/null | grep -m1 mCurrentFocus | sed 's/.*u0 //;s/}.*//')"
$A shell "grep -E 'MemAvailable|SwapFree' /proc/meminfo" | tr -d '\r' | sed 's/^/  /'
