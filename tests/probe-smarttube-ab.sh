#!/usr/bin/env bash
# SmartTube buffering investigation, part 1: is anything blocking ad/stream domains from this TV?
set -u
SER="${SER:-192.168.1.100:5555}"
A="adb -s $SER"

adb connect "$SER" >/dev/null 2>&1
sleep 2
st=$(adb devices | awk -v d="$SER" '$1==d {print $2}')
echo "== $SER state: ${st:-not connected} =="
[ "$st" = device ] || { echo "nothing to probe yet"; exit 1; }

echo
echo "== DNS answers for ad hosts vs a control host =="
for h in doubleclick.net googleads.g.doubleclick.net googlesyndication.com \
         static.doubleclick.net i.ytimg.com rr1---sn-4g5e6nez.googlevideo.com; do
  printf '  %-42s ' "$h"
  out=$($A shell "ping -c 1 -w 3 $h" 2>&1 | tr -d '\r' | head -2 | tr '\n' ' ')
  case "$out" in
    *"(0.0.0.0)"*|*"127.0.0.1"*) echo "BLOCKED  (resolves to a null address)" ;;
    *"unknown host"*|*"Name or service not known"*) echo "NO DNS ANSWER" ;;
    *"bytes from"*) echo "resolves and answers" ;;
    *) echo "unclear: $out" ;;
  esac
done

echo
echo "== do the ad hosts even resolve over https (no ping reply needed) =="
for h in doubleclick.net googleads.g.doubleclick.net; do
  printf '  %-42s ' "$h"
  $A shell "getprop net.dns1" >/dev/null 2>&1
  $A shell "nslookup $h 2>/dev/null | tail -2" 2>/dev/null | tr -d '\r' | tr '\n' ' ' | sed 's/^ *//' || echo "(no nslookup on this build)"
  echo
done

echo
echo "== private DNS setting (would explain null answers) =="
$A shell settings get global private_dns_mode
$A shell settings get global private_dns_specifier

echo
echo "== what is the TV showing =="
$A shell dumpsys window | grep -m1 mCurrentFocus
