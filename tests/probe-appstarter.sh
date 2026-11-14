#!/usr/bin/env bash
# AppStarter's role: is it a HOME app, does it run at boot, and is it the default?
set -u
SER="${SER:-192.168.1.101:5555}"
A="adb -s $SER"

echo "== who is the resolved HOME right now =="
$A shell cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME | tail -1 | tr -d '\r' | sed 's/^/  /'

echo
echo "== every app that claims to be a HOME screen =="
$A shell "cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.HOME 2>/dev/null | head -12" | tr -d '\r' | sed 's/^/  /'

echo
echo "== AppStarter: what does its manifest declare? =="
python3 - <<'PY'
import re, zipfile
z = zipfile.ZipFile('/tmp/xalahub.apk')
man = z.read('AndroidManifest.xml')
def has(s):
    return s.encode() in man or s.encode('utf-16-le') in man
for token in ('android.intent.category.HOME', 'android.intent.category.LEANBACK_LAUNCHER',
              'android.intent.action.BOOT_COMPLETED', 'android.intent.action.QUICKBOOT_POWERON',
              'android.intent.category.LAUNCHER', 'android.permission.WRITE_SETTINGS',
              'android.intent.action.MY_PACKAGE_REPLACED'):
    print(f"  {'yes' if has(token) else 'no ':3} {token}")
PY

echo
echo "== is it set to start something at boot (AppStarter keeps that in its own prefs) =="
echo "  running processes: $($A shell ps -A 2>/dev/null | grep -c xalahub)"
echo "  any AppStarter files on shared storage: $($A shell 'ls /sdcard/Android/data/com.xalahub.appstarter 2>/dev/null; ls /sdcard/AppStarter* 2>/dev/null' | tr -d '\r' | tr '\n' ' ')"

echo
echo "== what starts on boot that we know about =="
echo "  home on fire (accessibility): $($A shell settings get secure enabled_accessibility_services | tr -d '\r')"
echo "  launch on boot package:       $($A shell pm path news.androidtv.launchonboot 2>/dev/null | head -1 | tr -d '\r')"
