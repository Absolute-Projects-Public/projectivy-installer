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

# ---- mock adb on PATH, isolated HOME so nothing real is touched -----------
mkdir -p "$TMP/bin" "$TMP/home"
cp "$HERE/mock-adb" "$TMP/bin/adb"; chmod +x "$TMP/bin/adb"
export PATH="$TMP/bin:$PATH" HOME="$TMP/home" TERM=dumb
export MOCK_STATE="$TMP/state"

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

run_path() {  # run_path <input> [extra flags] ; output in $OUT
  rm -rf "$TMP/state"; mkdir -p "$TMP/state"
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
run_path "1\n\n3\n1\n1\n$TAIL"
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
run_path "1\n\n1\n2\n1\n$TAIL"
echo "Path B: install over ADB chosen first, scan later"
check "install question asked only once"       "$([ "$(count_of "$OUT" 'How should Projectivy be installed?')" = 1 ]; echo $?)"
check "installed without asking again"         "$(contains "$OUT" 'Installing Projectivy over ADB, as chosen earlier'; echo $?)"
check "run reaches the end"                    "$(contains "$OUT" 'Finished'; echo $?)"
echo

# ---- C: "already installed", and it really is -----------------------------
PRE_INSTALL=1
run_path "1\n\n2\n1\n192.168.1.100\n\n1\n$DNS_HOST\n\n1\n"
echo "Path C: already installed on the TV (package present)"
check "package detected"                       "$(contains "$OUT" 'found com.spocky.projengmenu'; echo $?)"
check "no install menu offered"                "$(not_contains "$OUT" 'How do you want to install it?'; echo $?)"
check "run reaches the end"                    "$(contains "$OUT" 'Finished'; echo $?)"
echo

# ---- D: "already installed", but it is NOT --------------------------------
PRE_INSTALL=0
run_path "1\n\n2\n1\n192.168.1.100\n1\n\n1\n$DNS_HOST\n\n1\n"
echo "Path D: said already installed, but the stick has nothing"
check "mismatch is reported"                   "$(contains "$OUT" 'even though it was said to be installed already'; echo $?)"
check "install is then offered"                "$(contains "$OUT" 'How do you want to install it?'; echo $?)"
check "install completes"                      "$(contains "$OUT" 'OK Projectivy installed'; echo $?)"
check "run reaches the end"                    "$(contains "$OUT" 'Finished'; echo $?)"
echo

# ---- E: blank answer at the IP prompt must not end the wizard -------------
PRE_INSTALL=0
run_path "1\n\n1\n1\n\n"
echo "Path E: blank IP, then input runs out"
check "returns to the connect menu"            "$(contains "$OUT" 'Step 3 of 6'; echo $?)"
check "stops explicitly, not as 'Finished'"    "$(contains "$OUT" 'Input ended'; echo $?)"
check "never claims success"                   "$(not_contains "$OUT" 'Finished'; echo $?)"
echo

# ---- F: debug log ---------------------------------------------------------
PRE_INSTALL=0
rm -rf "$TMP/logs"
run_path "1\n\n1\n1\n192.168.1.100\n$TAIL" --debug
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
run_path "1\n\n1\n1\n192.168.1.100\n$TAIL"
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
SETUP="1\n\n1\n1\n192.168.1.100\n\n\n"

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
run_path "1\n\n1\n1\n192.168.1.100\n\n\n"
check "warns that the port is not answering"    "$(contains "$OUT" 'Port 5555 is not answering'; echo $?)"
check "the warning names the address to check"  "$(contains "$OUT" 'check ADB debugging is ON and the address is right'; echo $?)"
check "still finishes without hanging"          "$(contains "$OUT" 'Done.'; echo $?)"
unset MOCK_PORT
echo

echo "Path M: port 5555 answers - no false warning"
PRE_INSTALL=0; PRE_LONG_UPTIME=0; export MOCK_PORT=0
run_path "1\n\n1\n1\n192.168.1.100\n\n\n"
check "no port warning when the port answers"   "$(not_contains "$OUT" 'Port 5555 is not answering'; echo $?)"
check "connects and reaches the end"            "$(contains "$OUT" 'Done.'; echo $?)"
unset MOCK_PORT
echo

printf 'passed %d, failed %d\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]