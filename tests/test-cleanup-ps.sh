#!/usr/bin/env bash
# Runs Install-Cleanup.ps1 (the Windows wizard) against tests/mock-adb, on any OS with pwsh.
# Proves the Windows path works without a Windows machine or a Fire TV.
#
#   ./tests/test-cleanup-ps.sh
#
# Needs PowerShell 7 (`pwsh`) on PATH, or set PWSH=/path/to/pwsh.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PWSH="${PWSH:-$(command -v pwsh || true)}"
[ -n "$PWSH" ] || { echo "pwsh not found - install PowerShell 7 or set PWSH="; exit 2; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/psclean.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
check() { if [ "$2" = 0 ]; then printf '  PASS %s\n' "$1"; PASS=$((PASS+1)); else printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); fi; }
contains() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
not_contains() { case "$1" in *"$2"*) return 1 ;; *) return 0 ;; esac; }

mkdir -p "$TMP/bin" "$TMP/home" "$TMP/state" "$TMP/fixtures"
cp "$HERE/mock-adb" "$TMP/bin/adb"; chmod +x "$TMP/bin/adb"
cp -r "$ROOT/data" "$ROOT/Install-Cleanup.ps1" "$TMP/"
for apk in ProjectivyLauncher-4.71-c95-xda-release.apk dnsfilter.android_1506103.apk \
           SmartTube_stable_32.56_universal.apk dumbtv-home.apk; do
  printf 'fixture payload\n' > "$TMP/fixtures/$apk"
done
printf 'device-metrics-us.amazon.com\narcus.amazon.com\nceviche.amazon.com\n' > "$TMP/fixtures/feed.txt"

# a believable Fire TV
sed 's/#.*//' "$ROOT/data/packages.txt" | awk 'NF' | head -12 > "$TMP/state/pkgs"
printf '%s\n' com.amazon.device.metrics com.amazon.device.software.ota com.android.nfc \
  com.amazon.aca com.netflix.ninja com.amazon.firetv.youtube com.amazon.avod >> "$TMP/state/pkgs"

export PATH="$TMP/bin:$PATH" HOME="$TMP/home" MOCK_STATE="$TMP/state" TERM=dumb
export ADB="$TMP/bin/adb"
export CLEANUP_APK_DIR="$TMP/fixtures" CLEANUP_BLOCKLIST="$TMP/fixtures/feed.txt"
export DNSF_SHA256=$(sha256sum "$TMP/fixtures/dnsfilter.android_1506103.apk" | awk '{print $1}')
export SMARTTUBE_SHA256=$(sha256sum "$TMP/fixtures/SmartTube_stable_32.56_universal.apk" | awk '{print $1}')
export DUMBTV_SHA256=$(sha256sum "$TMP/fixtures/dumbtv-home.apk" | awk '{print $1}')
export CLEANUP_ANSWERS=''   # set per path below

echo "Path PS-1: full cleanup, defaults except one app removed"
OUT="$(cd "$TMP" && CLEANUP_ANSWERS='y y 1 1 n netflix 1' timeout 180 "$PWSH" -NoProfile -NonInteractive -File ./Install-Cleanup.ps1 -Ip 192.168.1.100 2>&1)"
check "asks the six questions"                "$(contains "$OUT" 'Do you watch Prime Video?'; echo $?)"
check "keeps Prime Video and Alexa by default" "$(contains "$OUT" 'Prime Video: kept working'; echo $?)"
check "takes a preflight snapshot"            "$(contains "$OUT" 'Snapshot kept in'; echo $?)"
check "disables the ad packages"              "$(contains "$OUT" 'com.amazon.tv.acr'; echo $?)"
check "stars the protected ones"              "$(contains "$OUT" 'protected - starved'; echo $?)"
check "tightens ad tracking"                  "$(contains "$OUT" 'setting(s) tightened'; echo $?)"
check "installs Projectivy"                   "$(contains "$OUT" 'Projectivy installed'; echo $?)"
check "takes HOME without the toggle"         "$(contains "$OUT" 'no remote presses needed'; echo $?)"
check "removes the named app"                 "$(contains "$OUT" 'com.netflix.ninja'; echo $?)"
check "installs the DNS filter"               "$(contains "$OUT" 'Filter installed'; echo $?)"
check "verifies a blocked host"               "$(contains "$OUT" 'is blocked'; echo $?)"
check "writes an undo log"                    "$(ls "$TMP"/logs/cleanup-*/undo.tsv >/dev/null 2>&1; echo $?)"
check "finishes"                              "$(contains "$OUT" 'Cleanup finished'; echo $?)"
echo

echo "Path PS-2: dumbtv home, no DNS, SmartTube on"
OUT="$(cd "$TMP" && CLEANUP_ANSWERS='n n 2 3 y - 1' timeout 180 "$PWSH" -NoProfile -NonInteractive -File ./Install-Cleanup.ps1 -Ip 192.168.1.100 2>&1)"
check "dumbtv home installs (checksum verified)" "$(contains "$OUT" 'checksum verified'; echo $?)"
check "dumbtv home takes the front"            "$(contains "$OUT" 'dumbtv home is the home screen'; echo $?)"
check "SmartTube installs"                     "$(contains "$OUT" 'SmartTube installed'; echo $?)"
check "stock YouTube is disabled"              "$(contains "$OUT" 'YouTube app disabled'; echo $?)"
check "no filter when told to skip"            "$(not_contains "$OUT" 'Filter installed'; echo $?)"
echo

echo "Path PS-3: undo from the log"
OUT="$(cd "$TMP" && timeout 180 "$PWSH" -NoProfile -NonInteractive -File ./Install-Cleanup.ps1 \
        -Undo -Ip 192.168.1.100 2>&1)"
check "re-enables disabled packages"          "$(contains "$OUT" 're-enabled'; echo $?)"
check "gives HOME back to Amazon"             "$(contains "$OUT" 'Amazon home screen restored'; echo $?)"
echo

printf 'passed %d, failed %d\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
