#!/usr/bin/env bash
# Standalone debug driver for one cleanup path. Prints where it stops, and keeps the temp dir.
#   ./tests/debug-cleanup-path.sh ["input with \n escapes"]
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
R="$(cd "$HERE/.." && pwd)"
TMP=$(mktemp -d /tmp/dbgclean.XXXXXX)
mkdir -p "$TMP/bin" "$TMP/home" "$TMP/state" "$TMP/fixtures"
cp "$HERE/mock-adb" "$TMP/bin/adb"; chmod +x "$TMP/bin/adb"
for apk in ProjectivyLauncher-4.71-c95-xda-release.apk dnsfilter.android_1506103.apk \
           SmartTube_stable_32.56_universal.apk dumbtv-home.apk; do
  printf 'fixture payload\n' > "$TMP/fixtures/$apk"
done
printf 'device-metrics-us.amazon.com\narcus.amazon.com\nceviche.amazon.com\n' > "$TMP/fixtures/feed.txt"
cp -r "$R/lib" "$R/data" "$TMP/"
sed "/^# -\\{10,\\} main$/i\\
scan_network() { SCAN_RESULTS=\"192.168.1.100 \"; return 0; }\\
port_open() { return 0; }
" "$R/Install-Projectivy.sh" > "$TMP/wizard.sh"
chmod +x "$TMP/wizard.sh"
printf '%s\n' com.amazon.tv.acr com.amazon.hedwig com.amazon.hybridadidservice \
  com.amazon.device.metrics com.amazon.device.software.ota com.android.nfc \
  com.amazon.aca com.netflix.ninja com.amazon.firetv.youtube com.amazon.avod > "$TMP/state/pkgs"

export PATH="$TMP/bin:$PATH" HOME="$TMP/home" MOCK_STATE="$TMP/state" TERM=dumb
export CLEANUP_APK_DIR="$TMP/fixtures" CLEANUP_BLOCKLIST="$TMP/fixtures/feed.txt"
export DNSF_SHA256=$(sha256sum "$TMP/fixtures/dnsfilter.android_1506103.apk" | awk '{print $1}')
export SMARTTUBE_SHA256=$(sha256sum "$TMP/fixtures/SmartTube_stable_32.56_universal.apk" | awk '{print $1}')
export DUMBTV_SHA256=$(sha256sum "$TMP/fixtures/dumbtv-home.apk" | awk '{print $1}')

INPUT="${1:-1\n\n1\n192.168.1.100\ny\ny\n1\n1\nn\n\n1\n1\n}"
printf '%b' "$INPUT" > "$TMP/in.txt"
cd "$TMP"
timeout "${DEBUG_TIMEOUT:-25}" bash ./wizard.sh < in.txt > out.txt 2>&1
code=$?
echo "exit=$code (124 = timed out, i.e. it is waiting for input)"
echo "TMP=$TMP"
echo "---- last 30 lines ----"
tail -30 out.txt
echo "---- stages seen ----"
grep -o 'stage=[a-z_]*' out.txt 2>/dev/null | tail -10 || true
