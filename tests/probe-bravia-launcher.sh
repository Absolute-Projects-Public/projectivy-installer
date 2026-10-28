#!/usr/bin/env bash
# Install dumbtv home on an Android TV using dumbtv's own installer, with a pre-state snapshot.
set -u
SER="${SER:-192.168.1.100:5555}"
A="adb -s $SER"

echo "== 1. pre-state snapshot =="
{
  echo "serial: $SER"
  echo "model: $($A shell getprop ro.product.model | tr -d '\r')"
  echo "maker: $($A shell getprop ro.product.manufacturer | tr -d '\r')"
  echo "android: $($A shell getprop ro.build.version.release | tr -d '\r') sdk $($A shell getprop ro.build.version.sdk | tr -d '\r')"
  echo "home: $($A shell cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME | tail -1)"
  echo "a11y: $($A shell settings get secure enabled_accessibility_services | tr -d '\r')"
  echo "disabled: $($A shell pm list packages -d | wc -l)"
  echo "alarm-futurity: $($A shell settings get global alarm_manager_constants | tr -d '\r')"
} | tee /tmp/bravia-pre.txt

echo
echo "== 2. their repo =="
cd "$HOME" || exit 1
if [ -d dumbtv/.git ]; then
  echo "already cloned, updating"
  git -C dumbtv pull --ff-only >/dev/null 2>&1 || true
else
  git clone --depth 1 https://github.com/humblemuzzu/dumbtv dumbtv 2>&1 | tail -2
fi
cd dumbtv || exit 1
echo "launcher version: $(sed -n 's/^VERSION=//p' launcher/version.env 2>/dev/null)"

echo
echo "== 3. their launcher installer, aimed only at this TV =="
ADB_SERIAL="$SER" ./launcher/install.sh 2>&1 | tail -25
echo "exit=$?"
