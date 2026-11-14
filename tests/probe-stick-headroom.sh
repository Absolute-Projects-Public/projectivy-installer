#!/usr/bin/env bash
# Firestick: swap, the filter's real footprint, and which big consumers are already disabled.
# Read-only. Nothing is disabled here.
set -u
SER="${SER:-192.168.1.101:5555}"
A="adb -s $SER"

echo "== swap =="
$A shell "cat /proc/swaps 2>/dev/null" | tr -d '\r' | sed 's/^/  /'
$A shell "grep -E 'SwapTotal|SwapFree|MemFree|MemAvailable|Cached' /proc/meminfo" | tr -d '\r' | sed 's/^/  /'

echo
echo "== the DNS filter's footprint =="
$A shell "ps -A -o PID,RSS,NAME 2>/dev/null | grep -i dnsfilter" | tr -d '\r' | sed 's/^/  /'
echo "  tun interfaces: $($A shell 'ip -o link show 2>/dev/null | grep -c tun' | tr -d '\r')"

echo
echo "== are the big consumers already disabled? =="
dis=$($A shell pm list packages -d 2>/dev/null | sed 's/package://' | tr -d '\r')
for p in com.amazon.tv.livetv com.amazon.venezia com.amazon.firebat \
         com.amazon.whisperjoin.middleware.v2.np com.amazon.prism.android.service \
         com.amazon.diode com.android.proxyhandler com.plexapp.android; do
  case " $dis " in
    *" $p "*) echo "  DISABLED  $p" ;;
    *)        echo "  enabled   $p" ;;
  esac
done
echo "  total disabled: $(printf '%s\n' "$dis" | grep -c .)"

echo
echo "== do these declare a launcher/foreground service (why they wake up) =="
for p in com.amazon.tv.livetv com.amazon.firebat com.amazon.whisperjoin.middleware.v2.np; do
  flags=$($A shell "dumpsys package $p 2>/dev/null | grep -m1 pkgFlags" | tr -d '\r' | sed 's/.*pkgFlags=//')
  boot=$($A shell "dumpsys package $p 2>/dev/null | grep -c BOOT_COMPLETED" | tr -d '\r')
  printf '  %-46s flags=%-40s boot-receivers=%s\n' "$p" "$flags" "$boot"
done

echo
echo "== what the launcher itself costs =="
$A shell "dumpsys meminfo tv.dumbtv.home 2>/dev/null | grep -E 'TOTAL|TOTAL PSS|TOTAL RSS' | head -3" | tr -d '\r' | sed 's/^/  /'
