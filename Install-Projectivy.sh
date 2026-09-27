#!/usr/bin/env bash
# Install-Projectivy.sh - click-through wizard for Linux / macOS
#
# Makes Projectivy Launcher the home screen on an Amazon Fire TV Stick (Fire OS 7/8) and optionally
# stops Amazon's updates from arriving by pointing the stick at a DNS profile. Nothing here uses the
# old system-user exploit, which Amazon patched in Oct 2025.
#
#   ./Install-Projectivy.sh              # full wizard
#   ./Install-Projectivy.sh --debug      # same, plus a full log under ./logs/
#   ./Install-Projectivy.sh --no-clear   # keep the scrollback instead of clearing between steps
#   ./Install-Projectivy.sh --undo       # restore the Amazon home screen and clear DNS
#   ./Install-Projectivy.sh --ota-list   # just print the domains to denylist
#
# Double-click Install-Projectivy.desktop, or run add-to-app-menu.sh once, if you would rather not
# use a terminal. Non-interactive equivalent: setup-firestick.sh -h

set -uo pipefail

PROJ_PKG='com.spocky.projengmenu'
PROJ_SVC='com.spocky.projengmenu/com.spocky.projengmenu.services.ProjectivyAccessibilityService'
PROJ_APK_URL='https://github.com/spocky/miproja1/releases/download/4.71/ProjectivyLauncher-4.71-c95-xda-release.apk'
HOF_PKG='io.github.toolicious.homeonfire'
HOF_APK_URL='https://github.com/toolicious/home-on-fire/releases/latest/download/home-on-fire.apk'
ADGUARD_DOT='dns.adguard-dns.com'
CLOUDFLARE_DOT='1dot1dot1dot1.cloudflare-dns.com'

OTA_HOSTS=(
  softwareupdates.amazon.com
  updates.amazon.com
  prod.ota-cloudfront.net
  d1s31zyz7dcc2d.cloudfront.net
  d1s31zyz7dcc2d.cloudfront.prod.ota-cloudfront.net
  amzdigital-a.akamaihd.net
  amzdigitaldownloads.edgesuite.net
)

# ---- flags ----------------------------------------------------------------
DEBUG=0; NO_CLEAR=0
STAGE_OVERRIDE=''
for arg in "$@"; do
  case "$arg" in
    --debug)     DEBUG=1 ;;
    --no-clear)  NO_CLEAR=1 ;;
    --undo)      STAGE_OVERRIDE='undo' ;;
    --ota-list)  for h in "${OTA_HOSTS[@]}"; do echo "$h"; done; exit 0 ;;
    -h|--help)
      sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
  esac
done

# ---- terminal detection ---------------------------------------------------
# Done before any redirection: once stdout is piped through `tee` for the debug log, `[ -t 1 ]` is
# false and the menu/colour code would silently fall back to the plain path.
TTY_IN=0;  [ -t 0 ] && TTY_IN=1
TTY_OUT=0; [ -t 1 ] && TTY_OUT=1
if [ "$TTY_OUT" = 1 ]; then
  C_TITLE=$'\033[1;36m'; C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_BAD=$'\033[31m'
  C_DIM=$'\033[2m'; C_OFF=$'\033[0m'; C_INV=$'\033[7m'
else
  C_TITLE=''; C_OK=''; C_WARN=''; C_BAD=''; C_DIM=''; C_OFF=''; C_INV=''
fi

# ---- debug logging --------------------------------------------------------
LOGDIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/logs"
LOG_FILE=''

log_event() {  # log_event <TAG> <message>
  [ "$DEBUG" = 1 ] || return 0
  [ -n "$LOG_FILE" ] || return 0
  printf '%s [%-9s] %s\n' "$(date '+%H:%M:%S')" "$1" "$2" >> "$LOG_FILE" 2>/dev/null || true
}

start_logging() {
  mkdir -p "$LOGDIR" 2>/dev/null || LOGDIR="$HOME/.local/state/install-projectivy/logs"
  mkdir -p "$LOGDIR" 2>/dev/null || LOGDIR="${TMPDIR:-/tmp}"
  LOG_FILE="$LOGDIR/install-projectivy-$(date '+%Y%m%d-%H%M%S').log"
  {
    printf '=== Install-Projectivy.sh debug log ===\n'
    printf 'started : %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
    printf 'host    : %s\n' "$(uname -srm)"
    printf 'user    : %s@%s\n' "$(id -un 2>/dev/null || echo '?')" "$(hostname 2>/dev/null || echo '?')"
    printf 'home    : %s\n' "$HOME"
    printf 'args    : %s\n' "$*"
    printf 'bash    : %s\n' "$BASH_VERSION"
    printf 'payload : %s\n' "$PROJ_APK_URL"
    printf '=======================================\n'
  } >> "$LOG_FILE" 2>/dev/null || true

  # The live path is deliberately `tee` and nothing else: tee writes to the terminal immediately, so the
  # user sees output as it happens. Filters in this pipeline are a trap - `sed` block-buffers (its stdout
  # is a pipe, not a terminal) and a line-flushing `awk` variant failed outright on this system. Both
  # leave the terminal blank until Ctrl+C. ANSI escapes are stripped from the finished log instead, see
  # strip_ansi_from_log below.
  exec > >(tee -a "$LOG_FILE") 2>&1
}

# Best-effort cleanup of the finished log: remove the colour/cursor escapes so it is readable. Done once
# at exit rather than in the stream, so a failure here costs nothing but prettiness.
strip_ansi_from_log() {
  [ "$DEBUG" = 1 ] || return 0
  [ -n "$LOG_FILE" ] && [ -f "$LOG_FILE" ] || return 0
  local esc tmp="$LOG_FILE.clean"
  esc=$(printf '\033')
  if sed "s/${esc}\[[0-9;]*[A-Za-z]//g" "$LOG_FILE" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    mv "$tmp" "$LOG_FILE" 2>/dev/null || rm -f "$tmp"
  else
    rm -f "$tmp"
  fi
}

# ---- network probing ------------------------------------------------------
port_open() {  # port_open <ip> <port> [timeout-seconds] ; 0 when something is listening
  local ip="$1" port="$2" t="${3:-3}"
  ( timeout "$t" bash -c "echo > /dev/tcp/$ip/$port" ) >/dev/null 2>&1
}

# ---- terminal output helpers ---------------------------------------------
clear_screen() {
  [ "$NO_CLEAR" = 1 ] && return 0
  [ "$TTY_OUT" = 1 ] || return 0
  # 2J clears, 3J drops the scrollback, H homes the cursor. Written to the terminal directly so it
  # still works when stdout is redirected into the debug log.
  printf '\033[2J\033[3J\033[H' > /dev/tty 2>/dev/null || printf '\033[2J\033[3J\033[H'
}

title() { printf '\n%s== %s%s\n' "$C_TITLE" "$*" "$C_OFF"; }
body()  { printf '%s\n' "$*"; }
ok()    { printf '%s  OK%s %s\n' "$C_OK" "$C_OFF" "$*"; }
warn()  { printf '%s  !!%s %s\n' "$C_WARN" "$C_OFF" "$*"; }
bad()   { printf '%s  XX%s %s\n' "$C_BAD" "$C_OFF" "$*"; }
dim()   { printf '%s  %s%s\n' "$C_DIM" "$*" "$C_OFF"; }

pause() {
  printf '\n%s%s%s\n' "$C_DIM" "${1:-Press Enter to continue...}" "$C_OFF"
  if ! read -r _; then INPUT_EOF=1; return 1; fi
  return 0
}

ask_yes() {
  local prompt="$1" reply
  printf '%s [y/N] ' "$prompt"
  if ! read -r reply; then INPUT_EOF=1; log_event 'INPUT' "answer to '$prompt': <eof>"; return 1; fi
  log_event 'INPUT' "answer to '$prompt': ${reply:-<blank>}"
  case "$reply" in [yY]*) return 0 ;; *) return 1 ;; esac
}

# choose "prompt" "item one" "item two" ...
# Arrow keys when attached to a terminal, numbered input otherwise. Every item is numbered either way.
# Puts the choice in MENU_RESULT.
choose() {
  local prompt="$1"; shift
  local items=("$@") n=${#items[@]}
  [ "$n" -gt 0 ] || { MENU_RESULT=''; return 1; }
  local sel=0 k
  MENU_RESULT=''

  if [ "$TTY_IN" = 1 ] && [ "$TTY_OUT" = 1 ]; then
    # Rendered straight to the terminal, so the debug log keeps the tidy [SELECT] lines instead of
    # every arrow-key redraw of the list.
    {
    printf '\n%s%s%s\n' "$C_TITLE" "$prompt" "$C_OFF"
    printf '%s  (up/down arrows or type the number, Enter to pick)%s\n' "$C_DIM" "$C_OFF"
    for ((k=0;k<n;k++)); do printf '\n'; done
    while :; do
      printf '\033[%dA' "$n"
      for ((k=0;k<n;k++)); do
        if [ "$k" -eq "$sel" ]; then
          printf '\033[2K%s%s %d: %s%s\n' "$C_INV" "$C_TITLE" "$((k+1))" "${items[$k]}" "$C_OFF"
        else
          printf '\033[2K%s  %d: %s%s\n' "$C_DIM" "$((k+1))" "${items[$k]}" "$C_OFF"
        fi
      done
      local key rest=''
      if ! read -rsn1 key; then INPUT_EOF=1; break; fi
      case "$key" in
        $'\033')
          read -rsn2 -t 1 rest || true
          case "$rest" in
            '[A') sel=$(( (sel - 1 + n) % n )) ;;
            '[B') sel=$(( (sel + 1) % n )) ;;
          esac ;;
        '') break ;;
        [1-9]) [ "$key" -ge 1 ] && [ "$key" -le "$n" ] && sel=$((key - 1)) ;;
      esac
    done
    MENU_RESULT="${items[$sel]}"
    log_event 'SELECT' "from '$prompt': $((sel+1)) = $MENU_RESULT"
    printf '\033[2K%s  selected: %d: %s%s\n' "$C_OK" "$((sel+1))" "$MENU_RESULT" "$C_OFF"
    } > /dev/tty 2>/dev/null
  else
    printf '\n%s%s%s\n' "$C_TITLE" "$prompt" "$C_OFF"
    for ((k=0;k<n;k++)); do printf '%s  %d: %s%s\n' "$C_DIM" "$((k+1))" "${items[$k]}" "$C_OFF"; done
    local reply=''
    printf 'Select [1]: '
    if ! read -r reply; then INPUT_EOF=1; MENU_RESULT="${items[0]}"; log_event 'SELECT' "from '$prompt': <eof> -> default 1"; return 0; fi
    reply="$(printf '%s' "$reply" | tr -d ' ')"
    case "$reply" in ''|*[!0-9]*) reply=1 ;; esac
    [ "$reply" -ge 1 ] && [ "$reply" -le "$n" ] || reply=1
    MENU_RESULT="${items[$((reply-1))]}"
    log_event 'SELECT' "from '$prompt': $reply = $MENU_RESULT"
    printf '%s  selected: %s: %s%s\n' "$C_OK" "$reply" "$MENU_RESULT" "$C_OFF"
  fi
  return 0
}

adb_sh() {
  log_event 'ADB-REQ' "shell $*"
  local out
  out="$("$ADB" shell "$@" 2>&1 | tr -d '\r' || true)"
  log_event 'ADB-OUT' "$(printf '%s' "$out" | head -c 600)"
  printf '%s' "$out"
}

adb_do() {
  log_event 'ADB-REQ' "shell $*"
  "$ADB" shell "$@" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------- adb
resolve_adb() {
  if command -v adb >/dev/null 2>&1; then command -v adb; return 0; fi
  if [ -x "$HOME/platform-tools/adb" ]; then echo "$HOME/platform-tools/adb"; return 0; fi

  local zip dl="$HOME/.cache/platform-tools-dl"
  case "$(uname -s)" in
    Linux)  zip='platform-tools-latest-linux.zip' ;;
    Darwin) zip='platform-tools-latest-darwin.zip' ;;
    *) printf '%s\n' '  XX Unsupported OS. Install Android platform-tools and put adb on PATH.' >&2; return 1 ;;
  esac
  # Everything below writes to stderr: this function's stdout is captured by the caller,
  # so anything printed to stdout here would be swallowed and the user would see nothing.
  printf '\n%s== Android platform-tools are not installed - downloading them (~15 MB, one time)%s\n' "$C_TITLE" "$C_OFF" >&2
  log_event 'ADB' 'platform-tools not found; downloading'
  mkdir -p "$dl"
  if ! curl -fL --progress-bar "https://dl.google.com/android/repository/$zip" -o "$dl/pt.zip"; then
    printf '%s  XX Download failed - check the internet connection.%s\n' "$C_BAD" "$C_OFF" >&2
    log_event 'ADB' 'platform-tools download FAILED'
    return 1
  fi

  local got=0
  if command -v unzip >/dev/null 2>&1; then
    unzip -qo "$dl/pt.zip" -d "$HOME" >&2 && got=1
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$dl/pt.zip" "$HOME" >&2 && got=1
  elif command -v bsdtar >/dev/null 2>&1; then
    bsdtar -xf "$dl/pt.zip" -C "$HOME" >&2 && got=1
  fi
  if [ "$got" != 1 ]; then
    printf '%s  XX Could not unpack the download - install unzip (or python3) and re-run.%s\n' "$C_BAD" "$C_OFF" >&2
    log_event 'ADB' 'unpack failed (no unzip/python3/bsdtar)'
    return 1
  fi

  chmod +x "$HOME/platform-tools/adb" 2>/dev/null || true
  if [ ! -x "$HOME/platform-tools/adb" ]; then
    printf '%s  XX Extraction did not produce adb.%s\n' "$C_BAD" "$C_OFF" >&2
    log_event 'ADB' 'extraction produced no adb'
    return 1
  fi
  printf '%s  OK%s installed to %s\n' "$C_OK" "$C_OFF" "$HOME/platform-tools" >&2
  echo "$HOME/platform-tools/adb"
}

# Make sure adb is available wherever it is needed - the scan-first path never passes through the
# connect menu, so it cannot rely on that having run resolve_adb.
ensure_adb() {
  if [ -n "$ADB" ] && [ -x "$ADB" ]; then return 0; fi
  ADB="$(resolve_adb)" || return 1
  if [ -z "$ADB" ] || [ ! -x "$ADB" ]; then return 1; fi
  log_event 'ADB' "using $ADB ($("$ADB" version 2>/dev/null | head -n1))"
  ok "adb: $ADB"
  return 0
}

# ---------------------------------------------------------------- scan
local_ip() {
  ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}'
}

scan_network() {
  local base ip found_file
  ip="$(local_ip)"
  [ -n "$ip" ] || ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  [ -n "$ip" ] || return 1
  base="${ip%.*}."
  title "Scanning ${base}1-254 for a device listening on port 5555 (a few seconds)"
  log_event 'SCAN' "sweeping ${base}1-254 on port 5555"
  found_file="$(mktemp)"
  for n in $(seq 1 254); do
    ( port_open "${base}${n}" 5555 0.6 && echo "$base$n" >>"$found_file" ) &
  done
  wait
  SCAN_RESULTS="$(sort -u "$found_file" | tr '\n' ' ')"
  rm -f "$found_file"
  log_event 'SCAN' "found: ${SCAN_RESULTS:-none}"
  return 0
}

stage_scan() {
  if ! scan_network; then
    bad 'Could not work out this computer'"'"'s own network address. Enter the IP by hand.'
    NEXT='menu_ip'; return
  fi
  local found=()
  if [ -n "$SCAN_RESULTS" ]; then
    # shellcheck disable=SC2206
    found=($SCAN_RESULTS)
  fi

  if [ "${#found[@]}" -eq 0 ]; then
    warn 'No Fire TV answering on port 5555. Check ADB debugging is ON and the stick is on this wi-fi.'
    pause 'Press Enter to pick another way to connect...'
    NEXT='menu_connect'; return
  fi

  ok "found ${#found[@]} device(s)"
  local labels=()
  local f
  for f in "${found[@]}"; do labels+=("Select $f from scan result"); done
  labels+=("Rescan the network")
  labels+=("Enter the IP manually")

  choose 'Which one is the Firestick?' "${labels[@]}"
  case "$MENU_RESULT" in
    "Select "*" from scan result")
      IP="${MENU_RESULT#Select }"; IP="${IP% from scan result}"
      # if we still don't know how Projectivy is meant to get there, ask now - don't skip past it
      if [ -z "$INSTALL_MODE" ]; then NEXT='install_after_scan'; else NEXT='connect'; fi ;;
    "Rescan the network") NEXT='scan' ;;
    *) NEXT='menu_ip' ;;
  esac
}

# ---------------------------------------------------------------- stages
stage_welcome() {
  title 'Projectivy Launcher - setup wizard'
  body "This removes the ads from an Amazon Fire TV Stick by making Projectivy Launcher the home screen,
and can optionally stop Amazon's updates from arriving and undoing it again.

It takes about 15 minutes and two trips to the TV. Nothing is deleted.

WHAT YOU NEED
  1. The stick plugged in, on the same wi-fi as this computer.
  2. The remote, to press buttons on the TV when asked.
  3. Permission to unplug the stick's power for 30 seconds later on.
  4. Optional, for the update-blocking step: a free account at nextdns.io (2 minutes to set up)."
  NEXT='mainmenu'
}

stage_mainmenu() {
  choose 'What would you like to do?' \
    'Set up the Firestick launcher' \
    'Undo / restore the Amazon home screen' \
    'Exit Setup'
  case "$MENU_RESULT" in
    'Set up the Firestick launcher') NEXT='prepare' ;;
    'Undo / restore the Amazon home screen') NEXT='undo' ;;
    *) NEXT='exit' ;;
  esac
}

stage_prepare() {
  title 'Step 1 of 6 - get the stick ready'
  body "On the TV, using the remote:

  1. Settings > My Fire TV > About > click the device name 7 times (it says 'you are already a developer').
  2. Back > Developer Options > turn ON 'ADB debugging'.
  3. In Developer Options turn ON 'Apps from Unknown Sources'.
  4. Install the app 'Downloader' (by AFTVnews) from the Fire TV search."
  pause 'Press Enter when that is done...'
  NEXT='menu_install'
}

stage_menu_install() {
  title 'Step 2 of 6 - installing Projectivy'
  body "Pick how Projectivy Launcher should get onto the stick. Either way is fine; the first one needs no
typing on the TV at all."
  choose 'How should Projectivy be installed?' \
    'Install Projectivy for me over ADB (recommended)' \
    'I have already installed it on the TV with Downloader' \
    'Scan the network for a Firestick first'
  case "$MENU_RESULT" in
    'Install Projectivy for me over ADB'*)   INSTALL_MODE='adb';      NEXT='menu_connect' ;;
    'I have already installed it on the TV'*) INSTALL_MODE='existing'; NEXT='menu_connect' ;;
    *)                                       NEXT='scan' ;;   # decision gets asked after the scan
  esac
}

# Same question, asked after a scan when the answer is still unknown.
stage_install_after_scan() {
  choose 'How should Projectivy be installed?' \
    'Install Projectivy for me over ADB (recommended)' \
    'I have already installed it on the TV'
  case "$MENU_RESULT" in
    'Install Projectivy for me over ADB'*) INSTALL_MODE='adb' ;;
    *)                                     INSTALL_MODE='existing' ;;
  esac
  NEXT='connect'
}

# Shown to anyone who intends to install it on the TV by hand.
downloader_codes() {
  body "
If you would rather install it on the TV yourself, open the Downloader app and type one of these codes
into its address bar (or tap the '#' key for a number pad):

    1: 1198422   Projectivy Launcher APK (direct)
    2: 250931    TROYPOINT Toolbox - Projectivy plus other tools in one menu
    3: 730116    FireStickHacks downloads page
    4: 2571389   Simturax app centre

Codes get retired over time. This address always works:

    $PROJ_APK_URL"
}

ensure_adb_stage() {
  if ! ensure_adb; then
    warn 'Could not obtain adb. See the messages above, then run the wizard again.'
    NEXT='exit'; return 1
  fi
  return 0
}

stage_menu_connect() {
  ensure_adb_stage || return

  local labels=('Enter Firestick IP Manually' 'Scan Network for Firestick')
  [ -n "$IP" ] && labels+=("Use the last address: $IP")
  labels+=('Exit Setup')

  choose 'Step 3 of 6 - connect to the stick (the IP is on the TV under My Fire TV > About > Network)' "${labels[@]}"
  case "$MENU_RESULT" in
    'Enter Firestick IP Manually') NEXT='menu_ip' ;;
    'Scan Network for Firestick')  NEXT='scan' ;;
    'Use the last address: '*)     IP="${MENU_RESULT#Use the last address: }"; NEXT='connect' ;;
    *)                             NEXT='exit' ;;
  esac
}

stage_menu_ip() {
  title 'Enter the Firestick IP address'
  dim 'It is on the TV: Settings > My Fire TV > About > Network. Looks like 192.168.1.100'
  printf 'IP address (or leave blank to go back): '
  local reply=''
  if ! read -r reply; then INPUT_EOF=1; NEXT='menu_connect'; return; fi
  reply="$(printf '%s' "$reply" | tr -d ' ')"
  log_event 'INPUT' "IP address entered: ${reply:-<blank>}"
  if [ -z "$reply" ]; then
    NEXT='menu_connect'; return
  fi
  case "$reply" in
    *.*.*.*) IP="$reply"; NEXT='connect' ;;
    *) warn "That does not look like an IP address: $reply"; NEXT='menu_ip' ;;
  esac
}

stage_connect() {
  # defensive: never try to connect to something that isn't an address
  case "$IP" in
    *[!0-9.]*|'') warn "That is not a valid IP address: ${IP:-blank}"
                  NEXT='menu_ip'; return ;;
  esac
  ensure_adb_stage || return

  title "Step 4 of 6 - connecting to ${IP}:5555"
  body "
>>> LOOK AT THE TV NOW. A message will appear asking whether to allow USB debugging.
>>> Press 'Allow' on the remote (tick 'always allow' if offered).
>>> Nothing appearing? Press the Home button once and wait a few seconds.

Waiting for the TV to accept the connection - this is the step that usually needs the remote."
  printf '\n'
  log_event 'CONNECT' "target $IP:5555"

  PORT_OK=1
  if ! port_open "$IP" 5555; then
    PORT_OK=0
    warn "Port 5555 is not answering on $IP - check ADB debugging is ON and the address is right."
  fi
  timeout 12 "$ADB" connect "${IP}:5555" >/dev/null 2>&1 || true

  # if nothing is listening there is no point waiting the full time - the address or ADB debugging is wrong
  local tries=30
  [ "$PORT_OK" = 0 ] && tries=8

  local state='' line i
  for i in $(seq 1 "$tries"); do
    line="$("$ADB" devices | grep -F "${IP}:5555" || true)"
    case "$line" in
      *device) state='device'; break ;;
      *unauthorized) state='unauthorized' ;;
    esac
    printf '.'
    sleep 1
  done
  printf '\n'

  if [ "$state" = 'device' ]; then
    ok "connected to $IP"
    log_event 'CONNECT' "authorised, state=device after ${i}s"
    NEXT='apply'
    return
  fi
  log_event 'CONNECT' "FAILED, last state=${state:-none}"
  warn 'Not connected yet.'
  NEXT='menu_authorise'
}

stage_menu_authorise() {
  choose 'What next?' \
    'Retry the connection (press Allow on the TV first)' \
    'Enter a different IP address' \
    'Scan the network for a Firestick' \
    'Exit Setup'
  case "$MENU_RESULT" in
    'Retry the connection (press Allow on the TV first)') NEXT='connect' ;;
    'Enter a different IP address') IP=''; NEXT='menu_ip' ;;
    'Scan the network for a Firestick') NEXT='scan' ;;
    *) NEXT='exit' ;;
  esac
}

install_projectivy_adb() {
  title 'Downloading Projectivy 4.71 and installing it on the stick'
  if ! curl -fL --progress-bar "$PROJ_APK_URL" -o /tmp/projectivy.apk; then
    bad 'Download failed.'
    log_event 'INSTALL' 'APK download FAILED'
    return 1
  fi
  log_event 'INSTALL' 'APK downloaded, running adb install -r'
  "$ADB" install -r /tmp/projectivy.apk || warn 'Install reported an error - check the TV screen.'
  if printf '%s' "$(adb_sh pm list packages)" | grep -qF "$PROJ_PKG"; then
    ok 'Projectivy installed'
    log_event 'INSTALL' 'package present after install'
    INSTALL_MODE='adb'
    return 0
  fi
  bad 'It did not install. Check the TV for a blocked-install prompt.'
  log_event 'INSTALL' 'package NOT present after install'
  return 1
}

install_projectivy_manual() {
  downloader_codes
  pause 'Press Enter once Projectivy is installed on the TV...'
  if printf '%s' "$(adb_sh pm list packages)" | grep -qF "$PROJ_PKG"; then
    ok 'Projectivy found'
    INSTALL_MODE='existing'
    return 0
  fi
  bad 'Still not seeing Projectivy on the stick.'
  return 1
}

# Ask how to install, when the answer isn't known yet. Sets NEXT.
install_choice_in_apply() {
  choose 'How do you want to install it?' \
    'Install Projectivy for me over ADB now' \
    'I will install it on the TV with Downloader' \
    'Go back'
  case "$MENU_RESULT" in
    'Install Projectivy for me over ADB now')
      install_projectivy_adb || { NEXT='menu_install'; return; } ;;
    'I will install it on the TV with Downloader')
      install_projectivy_manual || { NEXT='menu_install'; return; } ;;
    *) NEXT='menu_install'; return ;;
  esac
  NEXT=''
}

stage_apply() {
  local name os pkgs
  name="$(adb_sh getprop ro.build.version.name)"
  os="$(adb_sh getprop ro.build.version.fireos)"
  title 'Step 5 of 6 - applying the changes'
  dim "Fire OS ${os:-?} (${name:-?})"
  log_event 'ENV' "fire os '${os:-?}' / build '${name:-?}'"

  case "$name $os" in
    *Vega*)
      bad 'This is a Vega OS device. It cannot sideload apps or use a custom launcher - nothing can be done.'
      log_event 'ENV' 'Vega OS - refusing to continue'
      pause
      NEXT='exit'; return ;;
  esac
  case "$os" in
    ''|7*|8*) ;;
    *) warn "Fire OS $os is outside the tested range (7.x / 8.x). The hooks may not take." ;;
  esac

  pkgs="$(adb_sh pm list packages)"
  if ! printf '%s' "$pkgs" | grep -qF "$PROJ_PKG"; then
    case "$INSTALL_MODE" in
      adb)
        # they asked for this earlier - just do it, don't make them answer again
        dim 'Installing Projectivy over ADB, as chosen earlier.'
        install_projectivy_adb || { NEXT='menu_install'; return; } ;;
      existing)
        warn 'There is no Projectivy on this stick, even though it was said to be installed already.'
        install_choice_in_apply
        [ -n "$NEXT" ] && return ;;
      *)
        warn 'Projectivy Launcher is not on the stick.'
        install_choice_in_apply
        [ -n "$NEXT" ] && return ;;
    esac
  else
    ok "found $PROJ_PKG"
  fi

  body ''
  adb_do appops set "$PROJ_PKG" SYSTEM_ALERT_WINDOW allow
  adb_do dumpsys deviceidle whitelist "+$PROJ_PKG"
  adb_do settings put secure enabled_accessibility_services "$PROJ_SVC"

  local on
  on="$(adb_sh settings get secure enabled_accessibility_services)"
  case "$on" in
    *ProjectivyAccessibilityService*) ok 'accessibility service registered' ;;
    *) bad "could not register the accessibility service (got: ${on:-empty})" ;;
  esac

  title 'One step on the TV (cannot be automated, it is a Projectivy setting)'
  body "  1. Open Projectivy Launcher from the TV's apps (or hold the select/OK button on the remote for a
     second to open its settings directly).
  2. Go to Settings > General.
  3. Turn ON 'Override current launcher'.

That toggle lives inside Projectivy's own saved settings, so it cannot be set over ADB - it is the one
step the wizard cannot do for you. It takes about 20 seconds."
  pause 'Press Enter once that switch is on...'
  log_event 'STEP' 'user confirmed the Override current launcher toggle'
  NEXT='coldboot'
}

stage_coldboot() {
  title 'Step 6 of 6 - the reboot test'
  body "Everything is applied. Now the real test - the settings must survive a power cycle.

  1. Unplug the stick's power (or the TV's, if that is easier).
  2. Wait a full 30 seconds.
  3. Plug it back in and let it start up completely.
  4. When the home screen has loaded, come back here.

Do not skip this - it is where a setup that looks fine usually breaks."
  pause 'Press Enter when the stick has booted again...'
  log_event 'STEP' 'cold-boot test starting'
  NEXT='verify'
}

stage_verify() {
  title 'Checking the result'
  local on focus uptime up_min focus_app app_label
  on="$(adb_sh settings get secure enabled_accessibility_services)"
  focus="$(adb_sh dumpsys window | grep -F 'mCurrentFocus' || true)"
  uptime="$(adb_sh cat /proc/uptime 2>/dev/null | awk '{printf "%d", $1}')"
  up_min=0
  case "$uptime" in ''|*[!0-9]*) ;; *) up_min=$((uptime / 60)) ;; esac

  case "$focus" in
    *com.spocky.projengmenu*) focus_app='projectivy' ;;
    *com.amazon.tv.launcher*) focus_app='amazon' ;;
    '')                       focus_app='unknown' ;;
    *)                        focus_app='other' ;;
  esac
  app_label="$(printf '%s' "$focus" | sed -n 's/.*u0 \([^ }]*\).*/\1/p')"

  dim "accessibility : ${on:-empty}"
  dim "on screen     : ${app_label:-unknown}"
  [ "$up_min" -gt 0 ] && dim "stick running : ${up_min} minutes"
  log_event 'VERIFY' "accessibility='${on}' focus-app='${focus_app}' (${app_label:-?}) uptime=${up_min}m"

  # The hook itself: if this was wiped, that is a genuine failure and a job for the fallback.
  if ! printf '%s' "$on" | grep -q ProjectivyAccessibilityService; then
    bad 'the accessibility hook was reset on boot'
    NEXT='fallback'; return
  fi

  if [ "$focus_app" = 'projectivy' ] && [ "$up_min" -lt 30 ]; then
    ok 'PASS - the stick rebooted and came back to Projectivy'
    NEXT='dns'; return
  fi

  # Anything else needs explaining rather than declaring. Two ways this check is meaningless:
  # the stick was never actually power-cycled, or it is sitting in some other app so we cannot see
  # what the home screen would be. Neither is evidence of a broken setup.
  if [ "$up_min" -ge 30 ]; then
    bad "the stick has been running for ${up_min} minutes, so it has not actually been power-cycled"
    body "
The reboot is the whole point of this step - an Amazon update would be applied while it boots. Unplug the
stick's power, wait a full 30 seconds, plug it back in, let it finish starting up, then check again."
  elif [ "$focus_app" = 'other' ]; then
    warn "the stick is sitting in another app (${app_label:-unknown}), so this cannot tell us anything yet"
    body "
Press the HOME button on the remote so the launcher comes to the front, then check again."
  else
    bad 'the stick came back to Amazon home instead of Projectivy'
    NEXT='fallback'; return
  fi

  choose 'What next?' \
    'Check again (I have done that now)' \
    'It still goes to Amazon - install the Home on Fire fallback' \
    'Exit Setup'
  case "$MENU_RESULT" in
    'Check again'*)            NEXT='verify' ;;
    'It still goes to Amazon'*) NEXT='fallback' ;;
    *)                         NEXT='exit' ;;
  esac
}

stage_fallback() {
  title 'The fallback - Home on Fire'
  body "The check did not pass, which happens on newer Fire OS builds. 'Home on Fire' redirects the Home
button instead of overriding the launcher, and works where the override does not."
  choose 'Install Home on Fire?' 'Yes, install it now' 'No, go back and check again' 'Exit Setup'
  case "$MENU_RESULT" in
    'Yes, install it now') ;;
    'No, go back and check again') NEXT='verify'; return ;;
    *) NEXT='exit'; return ;;
  esac

  title 'Downloading Home on Fire'
  if ! curl -fL --progress-bar "$HOF_APK_URL" -o /tmp/home-on-fire.apk; then
    bad 'Download failed.'; NEXT='fallback'; return
  fi
  "$ADB" install -r /tmp/home-on-fire.apk || warn 'Install reported an error - check the TV screen.'
  adb_do pm grant "$HOF_PKG" android.permission.WRITE_SECURE_SETTINGS
  if adb_sh dumpsys package "$HOF_PKG" | grep -q 'WRITE_SECURE_SETTINGS: granted=true'; then
    ok 'WRITE_SECURE_SETTINGS granted'
  else
    warn 'permission grant not confirmed - the accessibility switch in the app may refuse'
  fi
  adb_do am start -n "$HOF_PKG/.MainActivity"
  log_event 'HOF' 'home on fire installed, permission granted, app opened on the TV'

  title 'Finish this on the TV'
  body "  1. Turn the 'Accessibility service' switch ON.
  2. Choose target app > Projectivy Launcher.
  3. Turn on 'Launch on boot' / 'launch when device wakes up'.

Then in Projectivy: Settings > General > 'Override current launcher' = OFF.
Only one of the two should be active - they fight each other if both are on."
  pause 'Press Enter once that is done...'
  NEXT='verify'
}

stage_dns() {
  title 'Optional - stop Amazon pushing updates over it'
  body "Amazon can reset all of this with an automatic update. Blocking it means pointing the stick at a DNS
profile - optional, and recommended.

FIRST, THE WARNING: if any streaming app (Netflix, Plex, iPlayer) misbehaves after this step, undo the
DNS setting before anything else - it is the most likely cause and it is one command to reverse."
  choose 'Which DNS profile?' \
    'NextDNS profile (recommended - the only one that blocks Amazon updates)' \
    'Cloudflare (fast and private, no account, blocks nothing)' \
    'AdGuard (blocks ads and trackers, no account, does not block updates)' \
    'Skip the DNS step'
  case "$MENU_RESULT" in
    'NextDNS profile'*) NEXT='dns_nextdns' ;;
    'Cloudflare'*)      NEXT='dns_cloudflare' ;;
    'AdGuard'*)         NEXT='dns_adguard' ;;
    *)                  dim 'Skipped. Set it later with: setup-firestick.sh -i <ip> -d <profile>.dns.nextdns.io'
                        NEXT='done' ;;
  esac
}

stage_dns_nextdns() {
  title 'Set up the NextDNS profile'
  body "On a phone or computer:

  1. Go to my.nextdns.io and create a free profile (name it after this TV).
  2. Open the profile > Denylist tab > add each of these:

$(for h in "${OTA_HOSTS[@]}"; do echo "         $h"; done)

  3. Setup tab > copy the DNS-over-TLS address. It looks like: abcd1234.dns.nextdns.io

  Why all seven: the stick asks softwareupdates.amazon.com for updates, but the download itself comes from
  the cloudfront/akamai addresses. Blocking only the first one is the usual mistake."
  printf '\nPaste the DNS-over-TLS address (or leave blank to skip): '
  local reply=''
  if ! read -r reply; then INPUT_EOF=1; NEXT='done'; return; fi
  reply="$(printf '%s' "$reply" | tr -d ' ')"
  log_event 'INPUT' "DNS-over-TLS hostname entered: ${reply:-<blank>}"
  case "$reply" in
    '') NEXT='done' ;;
    *.*) apply_dns "$reply" blocking || true; NEXT='dnsdone' ;;
    *) warn 'That does not look like a DNS-over-TLS hostname (e.g. abcd1234.dns.nextdns.io).'
       NEXT='dns_nextdns' ;;
  esac
}

stage_dns_cloudflare() {
  apply_dns "$CLOUDFLARE_DOT" noblock || true
  warn 'Cloudflare blocks NOTHING - Amazon updates will still reach this stick.'
  NEXT='dnsdone'
}

stage_dns_adguard() {
  apply_dns "$ADGUARD_DOT" noblock || true
  warn 'AdGuard blocks ads and trackers but NOT Amazon updates. Use NextDNS for that.'
  NEXT='dnsdone'
}

apply_dns() {
  local host="$1" expect="${2:-blocking}"
  title "Setting DNS to $host"
  log_event 'DNS' "applying $host (expect=${expect})"
  adb_do settings put global private_dns_mode hostname
  adb_do settings put global private_dns_specifier "$host"
  dim "private_dns_mode      : $(adb_sh settings get global private_dns_mode)"
  dim "private_dns_specifier : $(adb_sh settings get global private_dns_specifier)"
  if [ "$(adb_sh settings get global private_dns_mode)" != 'hostname' ]; then
    bad 'the stick did not accept the DNS setting'
    log_event 'DNS' 'FAILED - mode did not stick'
    return 1
  fi
  ok 'DNS profile applied'

  title 'Testing whether the update address is blocked (advisory)'
  local ping
  ping="$(adb_sh ping -c 1 -w 3 softwareupdates.amazon.com)"
  case "$ping" in
    *"0.0.0.0"*|*"unknown host"*|*"bad address"*|*"Name or service"*|*"No address associated"*)
      ok 'softwareupdates.amazon.com is blocked'
      log_event 'DNS' 'verified blocked' ;;
    *"bytes from"*)
      if [ "$expect" = noblock ]; then
        dim 'Amazon update addresses still resolve - expected for this option, it blocks nothing.'
      else
        warn 'it STILL resolves - this profile does not block it. Check the denylist in NextDNS.'
        log_event 'DNS' 'NOT blocked - denylist problem'
      fi ;;
    *)
      warn "could not test automatically. Output: ${ping:-none}" ;;
  esac
  dim "Reverse any time with: setup-firestick.sh -i $IP -O"
}

stage_dnsdone() {
  title 'DNS is set'
  body "To confirm on the TV: Settings > My Fire TV > check for updates. It should fail with a connection
error - that is the desired result.

If a streaming app misbehaves from here on, reverse the DNS setting first and retest before touching
anything else about the launcher."
  pause 'Press Enter to continue...'
  NEXT='done'
}

stage_done() {
  title 'Finished'
  body "Verified: the stick boots to Projectivy and the Home button returns to it.

KEEP THIS IN MIND: Amazon's updates can sometimes clear the launcher settings and the stick will go back
to its ad-filled home screen. If that happens, just run this wizard again - the apps are still installed,
so it is a 30-second job, not a reinstall."
  choose 'Anything else?' \
    'Close (all done)' \
    'Undo / restore the Amazon home screen and clear DNS'
  case "$MENU_RESULT" in
    'Undo / restore'*) NEXT='undo' ;;
    *) NEXT='exit' ;;
  esac
}

stage_undo() {
  if ! ensure_adb; then
    bad 'Could not obtain adb. See the messages above.'
    NEXT='exit'; return
  fi
  if [ -z "$IP" ]; then
    printf 'Stick IP address: '
    if ! read -r IP; then INPUT_EOF=1; NEXT='exit'; return; fi
    log_event 'INPUT' "IP address entered for undo: ${IP:-<blank>}"
    [ -n "$IP" ] || { warn 'No address given.'; NEXT='exit'; return; }
  fi
  title "Restoring the Amazon home screen on $IP"
  timeout 20 "$ADB" connect "${IP}:5555" >/dev/null 2>&1 || true
  adb_do settings put secure enabled_accessibility_services '""'
  adb_do appops set "$PROJ_PKG" SYSTEM_ALERT_WINDOW default
  adb_do dumpsys deviceidle whitelist "-$PROJ_PKG"
  adb_do am start -n com.amazon.tv.launcher/.ui.HomeActivity_vNext
  adb_do settings put global private_dns_mode off
  adb_do settings delete global private_dns_specifier
  adb_do settings delete global dns_servers
  ok 'Amazon home screen restored and DNS cleared. Projectivy is still installed; run the wizard again any time.'
  log_event 'UNDO' 'hooks cleared, DNS cleared, Amazon launcher started'
  pause 'Press Enter to close...'
  NEXT='exit'
}

# ---------------------------------------------------------------- main
ADB=''
IP=''
INSTALL_MODE=''          # '' = not asked yet, 'adb' = install for them, 'existing' = already on the TV
STAGE='welcome'
NEXT=''
INPUT_EOF=0
MENU_RESULT=''
SCAN_RESULTS=''

if [ "$DEBUG" = 1 ]; then
  start_logging "$@"
  printf '%sDebug mode. Full log: %s%s\n' "$C_TITLE" "$LOG_FILE" "$C_OFF"
  sleep 1
fi

[ -n "$STAGE_OVERRIDE" ] && STAGE="$STAGE_OVERRIDE"
log_event 'START' "stage=$STAGE debug=$DEBUG no_clear=$NO_CLEAR"

while :; do
  NEXT=''
  clear_screen
  log_event 'STAGE' "$STAGE"

  case "$STAGE" in
    welcome)            stage_welcome ;;
    mainmenu)           stage_mainmenu ;;
    prepare)            stage_prepare ;;
    menu_install)       stage_menu_install ;;
    install_after_scan) stage_install_after_scan ;;
    menu_connect)       stage_menu_connect ;;
    menu_ip)            stage_menu_ip ;;
    scan)               stage_scan ;;
    connect)            stage_connect ;;
    menu_authorise)     stage_menu_authorise ;;
    apply)              stage_apply ;;
    coldboot)           stage_coldboot ;;
    verify)             stage_verify ;;
    fallback)           stage_fallback ;;
    dns)                stage_dns ;;
    dns_nextdns)        stage_dns_nextdns ;;
    dns_cloudflare)     stage_dns_cloudflare ;;
    dns_adguard)        stage_dns_adguard ;;
    dnsdone)            stage_dnsdone ;;
    done)               stage_done ;;
    undo)               stage_undo ;;
    exit|'')            break ;;
    *)                  bad "unknown stage $STAGE"; break ;;
  esac

  # Every stage names the next one. If it didn't, repeat it rather than falling out of the wizard.
  if [ -z "$NEXT" ]; then NEXT="$STAGE"; fi
  # ...but once input has run out (piped input, or Ctrl-D at a prompt) every later read would fail too,
  # so stop cleanly instead of looping between menus forever.
  if [ "$INPUT_EOF" = 1 ]; then
    printf '\n%sInput ended - stopping. Nothing further was changed.%s\n' "$C_WARN" "$C_OFF"
    log_event 'END' 'input exhausted'
    break
  fi
  STAGE="$NEXT"
done

log_event 'END' "finished (last stage: $STAGE)"
if [ "$DEBUG" = 1 ]; then
  printf '\n%sDone.%s  Log written to: %s\n' "$C_DIM" "$C_OFF" "$LOG_FILE"
  sleep 0.5              # let tee flush the tail of the process substitution before we exit
  strip_ansi_from_log
else
  printf '\n%sDone.%s\n' "$C_DIM" "$C_OFF"
fi