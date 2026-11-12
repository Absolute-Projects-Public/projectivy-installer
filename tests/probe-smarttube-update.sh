#!/usr/bin/env bash
# Stage SmartTube 32.71 (and install it if the TV is awake). Fixes the SponsorBlock playback loop:
# upstream yuliskov/SmartTube#5550, "fixed with the next update" after 32.56.
set -u
SER="${SER:-192.168.1.100:5555}"
A="adb -s $SER"
VER=32.71
VARIANT=armeabi-v7a                      # this set is 32-bit: ro.product.cpu.abilist=armeabi-v7a
URL="https://github.com/yuliskov/SmartTube/releases/download/32.71s/SmartTube_stable_${VER}_${VARIANT}.apk"
WANT=288e8caaa11417f6b64d2a7f906cead85c0b8a9bb5904753d7cb4f79d117d023
APK="/tmp/smarttube-${VER}-${VARIANT}.apk"

echo "== stage the APK =="
if [ ! -s "$APK" ]; then
  curl -fsSL -o "$APK" "$URL" || { echo "  download failed"; exit 1; }
fi
got=$(sha256sum "$APK" | cut -d' ' -f1)
echo "  file:   $APK ($(stat -c %s "$APK") bytes)"
echo "  sha256: $got"
if [ "$got" != "$WANT" ]; then
  echo "  !! checksum does not match the published digest - not installing"
  exit 1
fi
echo "  checksum matches the release digest"

echo
echo "== is the TV awake? =="
if ! timeout 3 bash -c "echo > /dev/tcp/${SER%%:*}/5555" 2>/dev/null; then
  echo "  no answer on 5555 - TV is off or asleep. Re-run this when it is on."
  exit 0
fi
adb connect "$SER" >/dev/null 2>&1
sleep 2
st=$(adb devices | awk -v d="$SER" '$1==d {print $2}')
echo "  state: ${st:-unknown}"
[ "$st" = device ] || { echo "  not authorised yet - accept the prompt on the TV, then re-run"; exit 0; }

echo
echo "== before =="
$A shell dumpsys package org.smarttube.stable 2>/dev/null | grep -m1 versionName

echo
echo "== install (push + device-side pm install: Play Protect is already off) =="
$A push "$APK" /data/local/tmp/smarttube.apk 2>&1 | tail -1
$A shell pm install -r -d /data/local/tmp/smarttube.apk 2>&1 | tail -2

echo
echo "== after =="
$A shell dumpsys package org.smarttube.stable 2>/dev/null | grep -m1 -E 'versionName|versionCode'
$A shell rm -f /data/local/tmp/smarttube.apk 2>/dev/null
