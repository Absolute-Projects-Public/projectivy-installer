#!/usr/bin/env bash
# Update SmartTube on the Firestick to the current stable, using the APK already staged and verified.
set -u
SER="${SER:-192.168.1.101:5555}"
A="adb -s $SER"
APK=/tmp/smarttube-32.71-armeabi-v7a.apk
WANT=288e8caaa11417f6b64d2a7f906cead85c0b8a9bb5904753d7cb4f79d117d023

echo "== the APK we already verified =="
[ -s "$APK" ] || { curl -fsSL -o "$APK" "https://github.com/yuliskov/SmartTube/releases/download/32.71s/SmartTube_stable_32.71_armeabi-v7a.apk" || exit 1; }
got=$(sha256sum "$APK" | cut -d' ' -f1)
[ "$got" = "$WANT" ] && echo "  checksum ok" || { echo "  checksum mismatch, stopping"; exit 1; }

adb connect "$SER" >/dev/null 2>&1
sleep 2
st=$(adb devices | awk -v d="$SER" '$1==d {print $2}')
echo
echo "== device state: ${st:-unknown} =="
[ "$st" = device ] || { echo "  not authorised"; exit 1; }
echo "  model:       $($A shell getprop ro.product.model | tr -d '\r')"
echo "  abi:         $($A shell getprop ro.product.cpu.abilist | tr -d '\r')"
echo "  SmartTube:   $($A shell dumpsys package org.smarttube.stable | grep -m1 versionName | tr -d '\r' | tr -s ' ')"

echo
echo "== install =="
$A push "$APK" /data/local/tmp/smarttube.apk 2>&1 | tail -1
$A shell pm install -r -d /data/local/tmp/smarttube.apk 2>&1 | tail -2

echo
echo "== after =="
$A shell dumpsys package org.smarttube.stable | grep -m1 -E 'versionName|versionCode' | tr -d '\r' | tr -s ' '
$A shell rm -f /data/local/tmp/smarttube.apk 2>/dev/null
echo
echo "== does it still launch =="
$A shell monkey -p org.smarttube.stable -c android.intent.category.LEANBACK_LAUNCHER 1 2>&1 | tail -1
sleep 5
$A shell dumpsys window | grep -m1 mCurrentFocus
