#!/usr/bin/env bash
# Regression tests for Install-Projectivy.sh. No Fire TV and no real adb required:
# the wizard is run against tests/mock-adb with the network scan stubbed to return one device.
#
#   ./tests/run-paths.sh
#
# Each path is driven with piped menu answers (1, 2, 3 ... then blank lines for "press Enter" prompts).
# Exit status is 0 only when every assertion passes.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WIZ="$HERE/../Install-Projectivy.sh"
TMP="$(mktemp -d)"
PASS=0; FAIL=0
trap 'rm -rf "$TMP"' EXIT

[ -f "$WIZ" ] || { echo "cannot find $WIZ"; exit 1; }

# The wizard reads lib/cleanup.sh and data/*.txt relative to itself, so the sandbox copy needs
# both, or every cleanup stage would be "command not found".
cp -r "$HERE/../lib" "$HERE/../data" "$TMP/"

# ---- mock adb on PATH, isolated HOME so nothing real is touched -----------
mkdir -p "$TMP/bin" "$TMP/home"
cp "$HERE/mock-adb" "$TMP/bin/adb"; chmod +x "$TMP/bin/adb"
export PATH="$TMP/bin:$PATH" HOME="$TMP/home" TERM=dumb
export MOCK_STATE="$TMP/state"

# ---- offline fixtures: the wizard must never download during tests ---------
# The pinned checksums are overridden with the fixture's own hash, so the verification path is
# still exercised (a corrupted fixture would be rejected) without touching the network.
FIX="$TMP/fixtures"; mkdir -p "$FIX"
: > "$FIX/ProjectivyLauncher-4.71-c95-xda-release.apk"
: > "$FIX/dnsfilter.android_1506103.apk"
: > "$FIX/SmartTube_stable_32.56_universal.apk"
: > "$FIX/dumbtv-home.apk"
for f in "$FIX"/*.apk; do printf 'fixture payload\n' > "$f"; done
export CLEANUP_APK_DIR="$FIX"
export DNSF_SHA256="$(sha256sum "$FIX/dnsfilter.android_1506103.apk" | awk '{print $1}')"
export SMARTTUBE_SHA256="$(sha256sum "$FIX/SmartTube_stable_32.56_universal.apk" | awk '{print $1}')"
export DUMBTV_SHA256="$(sha256sum "$FIX/dumbtv-home.apk" | awk '{print $1}')"
# a small stand-in for the HaGeZi Amazon feed
printf 'device-metrics-us.amazon.com\narcus.amazon.com\nceviche.amazon.com\n' > "$FIX/feed.txt"
export CLEANUP_BLOCKLIST="$FIX/feed.txt"

# ---- harness: the same wizard, with the network probes stubbed -------------
# scan_network returns one device; port_open returns MOCK_PORT (0 = listening,
# 1 = closed) so the "nothing is answering on 5555" path can be tested too.
sed "/^# -\{10,\} main$/i\\
scan_network() { SCAN_RESULTS=\"192.168.1.100 \"; return 0; }\\
port_open() { return \"\${MOCK_PORT:-0}\"; }\\
" "$WIZ" > "$TMP/wizard.sh"
chmod +x "$TMP/wizard.sh"
bash -n "$TMP/wizard.sh" || { echo "harness has a syntax error"; exit 1; }

check() {  # check <description> <condition-result>
  if [ "$2" = 0 ]; then printf '  %sPASS%s %s\n' "$(tput setaf 2 2>/dev/null)" "$(tput sgr0 2>/dev/null)" "$1"; PASS=$((PASS+1))
  else printf '  %sFAIL%s %s\n' "$(tput setaf 1 2>/dev/null)" "$(tput sgr0 2>/dev/null)" "$1"; FAIL=$((FAIL+1)); fi
}

contains() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
not_contains() { case "$1" in *"$2"*) return 1 ;; *) return 0 ;; esac; }
count_of() { printf '%s' "$1" | grep -cF "$2"; }

seed_device() {  # a believable Fire TV: ad packages, one protected, one system-off, the usual apps
  {
    sed 's/#.*//' "$HERE/../data/packages.txt" | awk 'NF' | head -12
    printf '%s\n' com.amazon.device.metrics com.amazon.device.software.ota com.android.nfc \
      com.amazon.aca com.netflix.ninja com.amazon.firetv.youtube com.amazon.avod
  } | awk 'NF' > "$TMP/state/pkgs"
}

run_path() {  # run_path <input> [extra flags] ; output in $OUT
  rm -rf "$TMP/state"; mkdir -p "$TMP/state"
  [ "${SEED_EMPTY:-0}" = 1 ] || seed_device
  [ "${PRE_INSTALL:-0}" = 1 ] && touch "$TMP/state/proj"
  [ "${PRE_LONG_UPTIME:-0}" = 1 ] && touch "$TMP/state/long_uptime"
  OUT="$(printf '%b' "$1" | timeout 120 bash "$TMP/wizard.sh" ${2:-} 2>/dev/null)"
}

DNS_HOST="abcd1234.dns.nextdns.io"
TAIL="\n\n1\n$DNS_HOST\n\n1\n"          # TV prompt, reboot prompt, DNS=NextDNS, hostname, DNS done, close

echo "Installing Projectivy - wizard regression tests"
echo

# ---- A: his reported bug - "Scan the network for a Firestick first" --------
PRE_INSTALL=0
run_path "2\n\n3\n1\n1\n$TAIL"
echo "Path A: install decision deferred to a network scan"
check "scan option is offered"                 "$(contains "$OUT" 'Scan the network for a Firestick first'; echo $?)"
check "found device is selectable by name"     "$(contains "$OUT" 'Select 192.168.1.100 from scan result'; echo $?)"
check "install question is asked AFTER the scan (2x total)" "$([ "$(count_of "$OUT" 'How should Projectivy be installed?')" = 2 ]; echo $?)"
check "the post-scan answer is honoured"       "$(contains "$OUT" 'Installing Projectivy over ADB, as chosen earlier'; echo $?)"
check "Projectivy really installed"            "$(contains "$OUT" 'OK Projectivy installed'; echo $?)"
check "reachability hook applied"              "$(contains "$OUT" 'accessibility service registered'; echo $?)"
check "cold-boot check passes"                 "$(contains "$OUT" 'PASS - the stick rebooted and came back to Projectivy'; echo $?)"
check "run reaches the end"                    "$(contains "$OUT" 'Finished'; echo $?)"
check "did not stop early"                     "$(not_contains "$OUT" 'Input ended'; echo $?)"
echo

# ---- B: install over ADB chosen up front, scan used later -----------------
PRE_INSTALL=0
run_path "2\n\n1\n2\n1\n$TAIL"
echo "Path B: install over ADB chosen first, scan later"
check "install question asked only once"       "$([ "$(count_of "$OUT" 'How should Projectivy be installed?')" = 1 ]; echo $?)"
check "installed without asking again"         "$(contains "$OUT" 'Installing Projectivy over ADB, as chosen earlier'; echo $?)"
check "run reaches the end"                    "$(contains "$OUT" 'Finished'; echo $?)"
echo

# ---- C: "already installed", and it really is -----------------------------
PRE_INSTALL=1
run_path "2\n\n2\n1\n192.168.1.100\n\n1\n$DNS_HOST\n\n1\n"
echo "Path C: already installed on the TV (package present)"
check "package detected"                       "$(contains "$OUT" 'found com.spocky.projengmenu'; echo $?)"
check "no install menu offered"                "$(not_contains "$OUT" 'How do you want to install it?'; echo $?)"
check "run reaches the end"                    "$(contains "$OUT" 'Finished'; echo $?)"
echo

# ---- D: "already installed", but it is NOT --------------------------------
PRE_INSTALL=0
run_path "2\n\n2\n1\n192.168.1.100\n1\n\n1\n$DNS_HOST\n\n1\n"
echo "Path D: said already installed, but the stick has nothing"
check "mismatch is reported"                   "$(contains "$OUT" 'even though it was said to be installed already'; echo $?)"
check "install is then offered"                "$(contains "$OUT" 'How do you want to install it?'; echo $?)"
check "install completes"                      "$(contains "$OUT" 'OK Projectivy installed'; echo $?)"
check "run reaches the end"                    "$(contains "$OUT" 'Finished'; echo $?)"
echo

# ---- E: blank answer at the IP prompt must not end the wizard -------------
PRE_INSTALL=0
run_path "2\n\n1\n1\n\n"
echo "Path E: blank IP, then input runs out"
check "returns to the connect menu"            "$(contains "$OUT" 'Step 3 of 6'; echo $?)"
check "stops explicitly, not as 'Finished'"    "$(contains "$OUT" 'Input ended'; echo $?)"
check "never claims success"                   "$(not_contains "$OUT" 'Finished'; echo $?)"
echo

# ---- F: debug log ---------------------------------------------------------
PRE_INSTALL=0
rm -rf "$TMP/logs"
run_path "2\n\n1\n1\n192.168.1.100\n$TAIL" --debug
LOG="$(ls "$TMP/logs"/install-projectivy-*.log 2>/dev/null | head -n1)"
echo "Path F: --debug writes a usable log"
check "log file created under ./logs/"         "$([ -n "$LOG" ]; echo $?)"
if [ -n "$LOG" ]; then
  LOGTXT="$(cat "$LOG")"
  check "header records host/user/args"        "$(contains "$LOGTXT" 'bash    :'; echo $?)"
  check "records menu selections"              "$(contains "$LOGTXT" '[SELECT'; echo $?)"
  check "records typed input"                  "$(contains "$LOGTXT" '[INPUT'; echo $?)"
  check "records adb commands"                 "$(contains "$LOGTXT" '[ADB-REQ'; echo $?)"
  check "records adb output"                   "$(contains "$LOGTXT" '[ADB-OUT'; echo $?)"
  check "records stage transitions"            "$(contains "$LOGTXT" '[STAGE'; echo $?)"
  check "records the DNS hostname entered"     "$(contains "$LOGTXT" "$DNS_HOST"; echo $?)"
  check "records the final result"             "$(contains "$LOGTXT" '[END'; echo $?)"
  check "captured the screen text too"         "$(contains "$LOGTXT" 'setup wizard'; echo $?)"
  check "no raw ANSI escapes in the log"       "$(grep -q "$(printf '\033')" "$LOG" && echo 1 || echo 0)"
  check "log says where it is"                 "$(contains "$OUT" 'Log written to:'; echo $?)"
else
  check "log exists (cannot inspect further)" 1
fi
echo

# ---- G: numbered options are shown ---------------------------------------
PRE_INSTALL=0
run_path "2\n\n1\n1\n192.168.1.100\n$TAIL"
echo "Path G: every menu option is numbered"
check "install menu numbered 1:"               "$(contains "$OUT" '1: Install Projectivy for me over ADB'; echo $?)"
check "install menu numbered 2:"               "$(contains "$OUT" '2: I have already installed it'; echo $?)"
check "install menu numbered 3:"               "$(contains "$OUT" '3: Scan the network for a Firestick'; echo $?)"
check "selection echoes the number"            "$(contains "$OUT" 'selected: 1:'; echo $?)"
echo

# ---- I/J/K: the cold-boot check must diagnose, not accuse -----------------
# Real bug from a user log: the stick was sitting in Plex, and the wizard announced "showing Amazon home
# instead of Projectivy" and pushed them into the Home on Fire fallback. Two cases make the check
# meaningless rather than failing - another app in the foreground, and no actual power cycle.
SETUP="2\n\n1\n1\n192.168.1.100\n\n\n"

PRE_INSTALL=0; PRE_LONG_UPTIME=0; export MOCK_FOCUS=plex
run_path "${SETUP}3\n"
echo "Path I: the stick is sitting in another app"
check "says it is in another app"              "$(contains "$OUT" 'sitting in another app'; echo $?)"
check "does NOT blame Amazon home"             "$(not_contains "$OUT" 'came back to Amazon home'; echo $?)"
check "does NOT push the fallback at them"     "$(not_contains "$OUT" 'The fallback - Home on Fire'; echo $?)"
check "offers to check again instead"          "$(contains "$OUT" 'Check again'; echo $?)"
echo

PRE_LONG_UPTIME=1; export MOCK_FOCUS=projectivy
run_path "${SETUP}3\n"
echo "Path J: no actual power cycle (uptime not reset)"
check "catches the missing reboot"             "$(contains "$OUT" 'has not actually been power-cycled'; echo $?)"
check "does NOT blame Amazon home"             "$(not_contains "$OUT" 'came back to Amazon home'; echo $?)"
check "tells them to unplug it for 30s"        "$(contains "$OUT" 'wait a full 30 seconds'; echo $?)"
echo

PRE_LONG_UPTIME=0; export MOCK_FOCUS=amazon
run_path "${SETUP}3\n"
echo "Path K: a genuine failure - Amazon home after a real reboot"
check "says it came back to Amazon home"       "$(contains "$OUT" 'came back to Amazon home'; echo $?)"
check "offers the Home on Fire fallback"       "$(contains "$OUT" 'The fallback - Home on Fire'; echo $?)"
unset MOCK_FOCUS PRE_LONG_UPTIME
echo

# ---- H: the debug log must not block the terminal -------------------------
# Regression: a filter (sed/awk) between the script and `tee` block-buffers, so with --debug the user
# sees an empty terminal until Ctrl+C. Piped tests can't see it (buffers flush at exit), so this path
# checks the redirect line statically AND, when python3 is available, checks real terminal timing.
echo "Path H: debug mode stays visible on a real terminal"
REDIR="$(grep -h 'exec > >(.*tee -a "\$LOG_FILE"' "$TMP/wizard.sh" | head -n1)"
check "log redirect is tee only, no filtering stage" \
      "$(case "$REDIR" in *sed*|*awk*) echo 1 ;; *) [ -n "$REDIR" ] && echo 0 || echo 1 ;; esac)"

if command -v python3 >/dev/null 2>&1; then
  # NOTE: this must look for text the wizard actually prints. An earlier version accepted "any bytes
  # that aren't the clear-screen sequence" and happily passed on a build that was erroring out instead.
  PTY_RESULT="$(python3 - "$TMP/wizard.sh" <<'PY' 2>/dev/null
import os, pty, select, sys, time, signal
wiz = sys.argv[1]
want = (b"Debug mode", b"setup wizard", b"What would you like")
pid, fd = pty.fork()
if pid == 0:
    os.environ["TERM"] = "xterm"
    os.execv("/bin/bash", ["bash", wiz, "--debug"])
deadline = time.time() + 5
seen = False
while time.time() < deadline:
    r, _, _ = select.select([fd], [], [], 0.2)
    if not r: continue
    try: chunk = os.read(fd, 4096)
    except OSError: break
    if not chunk: break
    if any(w in chunk for w in want):
        seen = True
        break
try: os.kill(pid, signal.SIGKILL); os.waitpid(pid, 0)
except Exception: pass
print("yes" if seen else "no")
PY
)"
  check "wizard's own text appears under a pty (not buffered away)" "$([ "$PTY_RESULT" = "yes" ]; echo $?)"
else
  echo "  SKIP  real-terminal timing check (python3 not installed)"
fi
echo

echo "Path L: port 5555 is closed - clear warning, short wait, still ends cleanly"
PRE_INSTALL=0; PRE_LONG_UPTIME=0; export MOCK_PORT=1
run_path "2\n\n1\n1\n192.168.1.100\n\n\n"
check "warns that the port is not answering"    "$(contains "$OUT" 'Port 5555 is not answering'; echo $?)"
check "the warning names the address to check"  "$(contains "$OUT" 'check ADB debugging is ON and the address is right'; echo $?)"
check "still finishes without hanging"          "$(contains "$OUT" 'Done.'; echo $?)"
unset MOCK_PORT
echo

echo "Path M: port 5555 answers - no false warning"
PRE_INSTALL=0; PRE_LONG_UPTIME=0; export MOCK_PORT=0
run_path "2\n\n1\n1\n192.168.1.100\n\n\n"
check "no port warning when the port answers"   "$(not_contains "$OUT" 'Port 5555 is not answering'; echo $?)"
check "connects and reaches the end"            "$(contains "$OUT" 'Done.'; echo $?)"
unset MOCK_PORT
echo

# ---- N: full cleanup, every default answer --------------------------------
# menu 1=full cleanup, Enter past prepare, 1=enter IP, then
# prime=y alexa=y launcher=Projectivy dns=on-device smarttube=n apps=none, go, close
echo "Path N: full cleanup with the default answers"
SEED_EMPTY=0
run_path "1\n\n1\n192.168.1.100\ny\ny\n1\n1\nn\n\n1\n1\n"
echo "Path N: full cleanup with the default answers"
check "asks the six questions"                  "$(contains "$OUT" 'Do you watch Prime Video?'; echo $?)"
check "default keeps Prime Video"               "$(contains "$OUT" 'Prime Video: kept working'; echo $?)"
check "default keeps Alexa"                     "$(contains "$OUT" 'Alexa: kept'; echo $?)"
check "takes a snapshot before changing"        "$(contains "$OUT" 'Snapshot kept in'; echo $?)"
check "disables the ad packages"                "$(contains "$OUT" 'com.amazon.tv.acr'; echo $?)"
check "stars the protected ones"                "$(contains "$OUT" 'protected - starved'; echo $?)"
check "reports a per-package summary"           "$(contains "$OUT" 'disabled,'; echo $?)"
check "tightens the ad settings"                "$(contains "$OUT" 'setting(s) tightened'; echo $?)"
check "installs Projectivy"                     "$(contains "$OUT" 'Projectivy installed'; echo $?)"
check "takes HOME without the manual toggle"    "$(contains "$OUT" 'no remote presses needed'; echo $?)"
check "installs the on-device filter"           "$(contains "$OUT" 'Filter installed'; echo $?)"
check "builds a blocklist"                      "$(contains "$OUT" 'hosts in the list'; echo $?)"
check "verifies the blocked hosts"              "$(contains "$OUT" 'is blocked'; echo $?)"
check "writes the undo log"                     "$(ls "$TMP"/logs/cleanup-*/undo.tsv >/dev/null 2>&1; echo $?)"
check "undo log records disabled packages"      "$(grep -q $'\tdisabled' "$TMP"/logs/cleanup-*/undo.tsv 2>/dev/null; echo $?)"
check "finishes"                                "$(contains "$OUT" 'Cleanup finished'; echo $?)"
echo

# ---- O: Alexa off, dumbtv home, no DNS, SmartTube, one app removed --------
echo "Path O: non-default answers (Alexa off, dumbtv home, no DNS, SmartTube, remove Netflix)"
SEED_EMPTY=0
run_path "1\n\n1\n192.168.1.100\nn\nn\n2\n4\ny\nnetflix\n1\n1\n"
echo "Path O: non-default answers"
check "Prime Video can be given up"             "$(contains "$OUT" 'will not play'; echo $?)"
check "Alexa packages are switched off"         "$(contains "$OUT" 'com.amazon.aca'; echo $?)"
check "dumbtv home installs and is verified"    "$(contains "$OUT" 'checksum verified'; echo $?)"
check "dumbtv home takes the front"             "$(contains "$OUT" 'dumbtv home is the home screen'; echo $?)"
check "SmartTube installs"                      "$(contains "$OUT" 'SmartTube installed'; echo $?)"
check "the stock YouTube app is disabled"       "$(contains "$OUT" 'YouTube app disabled'; echo $?)"
check "a named app is resolved and removed"     "$(contains "$OUT" 'com.netflix.ninja'; echo $?)"
check "no DNS filter when told to skip"         "$(not_contains "$OUT" 'Filter installed'; echo $?)"
check "finishes"                                "$(contains "$OUT" 'Cleanup finished'; echo $?)"
echo

# ---- P: Fire OS 8 hides the app folder -> media fallback + manual step ----
echo "Path P: Fire OS 8 hides the app directory, so the media fallback is used"
SEED_EMPTY=0; export MOCK_APP_DIR=hidden
run_path "1\n\n1\n192.168.1.100\ny\ny\n1\n1\nn\n\n1\n\n1\n"
echo "Path P: media fallback"
check "explains the one tap needed on the TV"   "$(contains "$OUT" 'One tap is needed on the TV'; echo $?)"
check "names the file to point the app at"      "$(contains "$OUT" 'Android/media/dnsfilter.android/blocklist.txt'; echo $?)"
check "still finishes"                          "$(contains "$OUT" 'Cleanup finished'; echo $?)"
unset MOCK_APP_DIR
echo

# ---- Q: undo everything from the log Path N wrote -------------------------
echo "Path Q: undo everything"
OUT="$(printf '%b' '192.168.1.100\n\n' | timeout 120 bash "$TMP/wizard.sh" --undo 2>/dev/null)"
echo "Path Q: undo everything"
check "re-enables the disabled packages"        "$(contains "$OUT" 're-enabled com.amazon.tv.acr'; echo $?)"
check "removes the DNS filter"                  "$(contains "$OUT" 'DNS filter removed'; echo $?)"
check "gives HOME back to Amazon"               "$(contains "$OUT" 'Amazon home screen restored'; echo $?)"
echo

printf 'passed %d, failed %d\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
