#!/usr/bin/env bash
# Install Launch on Boot (F-Droid build) and show what it can actually do.
set -u
S="${SER:-192.168.50.252:5555}"
A="adb -s $S"
PKG=news.androidtv.launchonboot
URL=https://f-droid.org/repo/news.androidtv.launchonboot_12.apk

echo "== fetch from F-Droid =="
cd /tmp || exit 1
rm -f lob.apk
curl -fsSL -o lob.apk "$URL" || { echo "download failed"; exit 1; }
ls -l lob.apk
echo "sha256: $(sha256sum lob.apk | cut -d' ' -f1)"
python3 - <<'PY'
import zipfile
z = zipfile.ZipFile('/tmp/lob.apk')
print("entries:", len(z.namelist()))
PY

echo "== install =="
$A install -r /tmp/lob.apk 2>&1 | tail -1
echo "path: $($A shell pm path $PKG | head -1)"

echo "== does it declare a boot receiver? =="
$A shell dumpsys package $PKG | grep -iE 'BOOT_COMPLETED|RECEIVE_BOOT' | head -5

echo "== activities =="
$A shell dumpsys package $PKG | sed -n '/Activity Resolver Table/,/^$/p' | grep -E '^\s+[0-9a-f]{6,}' | head -5

echo "== version =="
$A shell dumpsys package $PKG | grep -m1 versionName
