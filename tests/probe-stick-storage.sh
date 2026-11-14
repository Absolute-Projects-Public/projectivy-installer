#!/usr/bin/env bash
# Firestick: where the space went, and what is running / listening.
set -u
SER="${SER:-192.168.1.101:5555}"
A="adb -s $SER"

adb connect "$SER" >/dev/null 2>&1
sleep 2
echo "== device =="
echo "  state: $($A get-state 2>&1 | tail -1)"
echo "  model: $($A shell getprop ro.product.model | tr -d '\r')  build: $($A shell getprop ro.build.version.name | tr -d '\r')"

echo
echo "== filesystems =="
$A shell df -h 2>/dev/null | tr -d '\r' | sed 's/^/  /'

echo
echo "== android's own accounting =="
$A shell dumpsys diskstats 2>/dev/null | tr -d '\r' | head -12 | sed 's/^/  /'

echo
echo "== biggest things under /sdcard =="
$A shell "du -sm /sdcard/* 2>/dev/null | sort -rn | head -12" | tr -d '\r' | sed 's/^/  /'
echo "  -- and inside Android/data (app caches live here) --"
$A shell "du -sm /sdcard/Android/data/* 2>/dev/null | sort -rn | head -8" | tr -d '\r' | sed 's/^/  /'

echo
echo "== installed third-party apps (the usual hogs) =="
$A shell pm list packages -3 2>/dev/null | sed 's/package://' | tr -d '\r' | sort | sed 's/^/  /'

echo
echo "== app code+data sizes, largest first =="
for p in $($A shell pm list packages -3 2>/dev/null | sed 's/package://' | tr -d '\r'); do
  line=$($A shell "dumpsys package $p 2>/dev/null | grep -m1 -E 'dataDir|codePath'" | tr -d '\r')
  apk=$($A shell "pm path $p 2>/dev/null | head -1" | tr -d '\r')
  [ -n "$apk" ] || continue
  path=${apk#package:}
  dir=$(dirname "$path" 2>/dev/null)
  sz=$($A shell "du -sm '$dir' 2>/dev/null | cut -f1" | tr -d '\r')
  printf '  %-42s %6s MB (apk dir)\n' "$p" "${sz:-?}"
done

echo
echo "== top processes by memory =="
$A shell "top -b -n 1 -o %MEM,RES,CMDLINE 2>/dev/null | head -18" | tr -d '\r' | sed 's/^/  /' \
  || $A shell "ps -A 2>/dev/null | head -25" | tr -d '\r' | sed 's/^/  /'

echo
echo "== listening sockets (who is proxying?) =="
$A shell "netstat -tuln 2>/dev/null || ss -tuln 2>/dev/null || echo '(no netstat/ss)'" | tr -d '\r' | sed 's/^/  /'

echo
echo "== proxy / vpn settings =="
for k in global_http_proxy_host global_http_proxy_port http_proxy global_proxy_pac_url; do
  printf '  %-28s %s\n' "$k" "$($A shell settings get global $k 2>/dev/null | tr -d '\r')"
done
echo "  vpn packages: $($A shell pm list packages 2>/dev/null | grep -iE 'vpn|proxy|dnsfilter|personal' | tr -d '\r' | tr '\n' ' ')"
echo "  vpn service:  $($A shell dumpsys connectivity 2>/dev/null | grep -m2 -iE 'VPN|Proxy' | tr -d '\r' | tr '\n' ' ')"
