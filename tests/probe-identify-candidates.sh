#!/usr/bin/env bash
# Identify the candidates that are NOT on our never-disable list, before touching them.
set -u
SER="${SER:-192.168.1.101:5555}"
A="adb -s $SER"

for p in com.amazon.prism.android.service com.amazon.diode \
         com.amazon.whisperjoin.middleware.v2.np com.android.proxyhandler; do
  echo "== $p =="
  $A shell dumpsys package "$p" 2>/dev/null | grep -m4 -E 'versionName|codePath|pkgFlags|userId=' | tr -d '\r' | sed 's/^/  /'
  echo "  services:"
  $A shell dumpsys package "$p" 2>/dev/null | sed -n '/Service Resolver Table/,/^$/p' | grep -E '^\s+[0-9a-f]{6,}' | head -4 | tr -d '\r' | sed 's/^/    /'
  echo "  activities:"
  $A shell dumpsys package "$p" 2>/dev/null | sed -n '/Activity Resolver Table/,/^$/p' | grep -E '^\s+[0-9a-f]{6,}' | head -4 | tr -d '\r' | sed 's/^/    /'
  echo "  receivers/boot: $($A shell "dumpsys package $p 2>/dev/null | grep -c BOOT_COMPLETED" | tr -d '\r')"
  echo "  permissions of interest:"
  $A shell dumpsys package "$p" 2>/dev/null | grep -E 'android.permission.(INTERNET|RECEIVE_BOOT|WRITE_|READ_|BIND_|ACCESS_)' | head -6 | tr -d '\r' | sed 's/^/    /'
  echo "  running now: $($A shell ps -A 2>/dev/null | grep -c "$p")"
  echo
done
