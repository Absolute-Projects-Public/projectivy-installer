#!/usr/bin/env bash
# Firestick part 3: identify the leftover filter, the unknown package, and the DNS setup.
set -u
SER="${SER:-192.168.1.101:5555}"
A="adb -s $SER"

echo "== dnsfilter.android (the thing holding the VPN) =="
$A shell dumpsys package dnsfilter.android 2>/dev/null | grep -m8 -E 'userId=|versionName|firstInstallTime|lastUpdateTime|installerPackageName|codePath|pkgFlags' | tr -d '\r' | sed 's/^/  /'
echo "  is it the VPN owner? (uid above vs OwnerUid 10266 in the VPN network)"
echo "  services it runs: $($A shell dumpsys activity services dnsfilter.android 2>/dev/null | grep -m3 -E 'ServiceRecord|isForeground' | tr -d '\r' | tr '\n' ' ')"
echo "  has a tun device: $($A shell 'ls /dev/tun* 2>/dev/null; ip -o link show 2>/dev/null | grep -c tun' | tr -d '\r')"

echo
echo "== com.xalahub.appstarter (unknown to me - what is it?) =="
$A shell dumpsys package com.xalahub.appstarter 2>/dev/null | grep -m10 -E 'versionName|firstInstallTime|lastUpdateTime|installerPackageName|codePath|pkgFlags|userId=' | tr -d '\r' | sed 's/^/  /'
echo "  permissions:"
$A shell dumpsys package com.xalahub.appstarter 2>/dev/null | sed -n '/requested permissions:/,/install permissions:/p' | grep -E 'android.permission' | head -12 | tr -d '\r' | sed 's/^/    /'
echo "  activities/receivers:"
$A shell dumpsys package com.xalahub.appstarter 2>/dev/null | sed -n '/Activity Resolver Table/,/^$/p' | head -6 | tr -d '\r' | sed 's/^/    /'
echo "  install source: $($A shell pm list packages -i 2>/dev/null | grep xalahub | tr -d '\r')"
echo "  apk path: $($A shell pm path com.xalahub.appstarter 2>/dev/null | tr -d '\r')"
echo "  running now: $($A shell ps -A 2>/dev/null | grep -c xalahub)"

echo
echo "== dns setup on the stick =="
echo "  private dns mode:      $($A shell settings get global private_dns_mode | tr -d '\r')"
echo "  private dns specifier: $($A shell settings get global private_dns_specifier | tr -d '\r')"
echo "  dns servers in use:    $($A shell getprop | grep -E 'net.dns[0-9]' | tr -d '\r' | tr '\n' ' ')"

echo
echo "== disabled packages that are also running (should be none) =="
dis=$($A shell pm list packages -d 2>/dev/null | sed 's/package://' | tr -d '\r')
for p in $($A shell ps -A 2>/dev/null | awk '{print $9}' | grep '\.' | sort -u); do
  case " $dis " in *" $p "*) echo "  RUNNING but disabled: $p" ;; esac
done
echo "  (none listed above means nothing disabled is running)"

echo
echo "== first install times of everything third-party (spot the strays) =="
for p in $($A shell pm list packages -3 2>/dev/null | sed 's/package://' | tr -d '\r'); do
  t=$($A shell dumpsys package "$p" 2>/dev/null | grep -m1 firstInstallTime | tr -d '\r' | sed 's/.*=//')
  printf '  %-46s %s\n' "$p" "$t"
done | sort -k2
