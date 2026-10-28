#!/usr/bin/env bash
# Install Home on Fire on the TV and enable the permission its "launch on boot" needs.
set -u
S="${SER:-192.168.50.252:5555}"
A="adb -s $S"
PKG=io.github.toolicious.homeonfire

echo "== fetch =="
cd /tmp || exit 1
rm -f hof.apk
curl -fsSL -o hof.apk https://github.com/toolicious/home-on-fire/releases/latest/download/home-on-fire.apk || { echo "download failed"; exit 1; }
ls -l hof.apk

echo "== install =="
$A install -r /tmp/hof.apk 2>&1 | tail -2
echo "installed: $($A shell pm path $PKG | head -1)"

echo "== permission =="
$A shell pm grant $PKG android.permission.WRITE_SECURE_SETTINGS 2>&1
$A shell dumpsys package $PKG | grep -m1 'WRITE_SECURE_SETTINGS' || echo "(no grant line)"

echo "== activities =="
$A shell dumpsys package $PKG | sed -n '/Activity Resolver Table/,/^$/p' | head -12

echo "== services =="
$A shell dumpsys package $PKG | sed -n '/Service Resolver Table/,/^$/p' | head -10
