#!/usr/bin/env bash
# One-shot setup for Projectivy Launcher as the home screen on an Amazon Fire TV Stick (Fire OS 7/8),
# with optional DNS-level blocking of Amazon's update servers.
#
# Uses ONLY methods that still work after Amazon patched the system-user exploit in Oct 2025.
# Never tries to disable com.amazon.tv.launcher - protected package, and it takes Fire OS Settings with it.
#
#   ./setup-firestick.sh -i 192.168.1.100
#   ./setup-firestick.sh -i 192.168.1.100 -p -f -w                  # full setup + Home on Fire + warm test
#   ./setup-firestick.sh -i 192.168.1.100 -d abcd1234.dns.nextdns.io  # ...and block OTA via NextDNS
#   ./setup-firestick.sh -i 192.168.1.100 -u                        # revert everything
#   ./setup-firestick.sh -l                                         # print the domains to denylist
#
# Interactive wizard for non-technical users: ./Install-Projectivy.sh  (or double-click the .desktop)
#
#   -i, --ip <addr>       stick IP (Settings -> My Fire TV -> About -> Network); ADB debugging must be ON
#   -p, --projectivy      download + install Projectivy 4.71 (otherwise it must already be on the stick)
#   -f, --home-on-fire    also install + configure Home on Fire (newer Fire OS 8 Home-button redirector)
#   -w, --warm            wake the device and press Home afterwards to eyeball the result
#   -u, --uninstall       revert: clear the hooks and the DNS settings, back to Amazon's launcher
#   -d, --dns-dot <host>  set a DNS-over-TLS hostname, e.g. abcd1234.dns.nextdns.io (blocks OTA if the
#                         NextDNS profile has the domains below on its denylist)
#   -a, --dns-adguard     set AdGuard DNS (ads and trackers, no account - does NOT block Amazon updates)
#   -c, --dns-cloudflare  set Cloudflare DNS (fast and private, no account - blocks nothing at all)
#   -O, --dns-off         remove any DNS setting and go back to the network default
#   -l, --ota-list        print the domains to put on a resolver denylist, then exit
#   -D, --debug           also write a full log (every command and its output) to ./logs/
#   -h, --help            this text

set -uo pipefail

ORIG_ARGS="$*"          # the arg-parsing loop below shifts them away; keep a copy for the debug log

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

IP=''; DO_PROJ=0; DO_HOF=0; DO_WARM=0; DO_UNDO=0; DNS_DOT=''; DNS_AG=0; DNS_CF=0; DNS_OFF=0; OTA_LIST=0; DEBUG=0
LOG_FILE=''

usage() { sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -i|--ip)         IP="${2:-}"; shift 2 ;;
    -p|--projectivy) DO_PROJ=1; shift ;;
    -f|--home-on-fire) DO_HOF=1; shift ;;
    -w|--warm)       DO_WARM=1; shift ;;
    -u|--uninstall)  DO_UNDO=1; shift ;;
    -d|--dns-dot)    DNS_DOT="${2:-}"; shift 2 ;;
    -a|--dns-adguard) DNS_AG=1; shift ;;
    -c|--dns-cloudflare) DNS_CF=1; shift ;;
    -O|--dns-off)    DNS_OFF=1; shift ;;
    -l|--ota-list)   OTA_LIST=1; shift ;;
    -D|--debug)      DEBUG=1; shift ;;
    -h|--help)       usage 0 ;;
    *) usage 2 ;;
  esac
done

step() { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
good() { printf ' OK %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*"; }
die()  { printf '  X %s\n' "$*" >&2; [ -n "$LOG_FILE" ] && printf '  X %s\n' "$*" >> "$LOG_FILE"; exit 1; }

log_event() {
  [ "$DEBUG" = 1 ] || return 0
  [ -n "$LOG_FILE" ] || return 0
  printf '%s [%-9s] %s\n' "$(date '+%H:%M:%S')" "$1" "$2" >> "$LOG_FILE" 2>/dev/null || true
}

start_logging() {
  local dir; dir="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/logs"
  mkdir -p "$dir" 2>/dev/null || dir="$HOME/.local/state/setup-firestick/logs"
  mkdir -p "$dir" 2>/dev/null || dir="${TMPDIR:-/tmp}"
  LOG_FILE="$dir/setup-firestick-$(date '+%Y%m%d-%H%M%S').log"
  {
    printf '=== setup-firestick.sh debug log ===\n'
    printf 'started : %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
    printf 'host    : %s\n' "$(uname -srm)"
    printf 'user    : %s@%s\n' "$(id -un 2>/dev/null || echo '?')" "$(hostname 2>/dev/null || echo '?')"
    printf 'args    : %s\n' "$ORIG_ARGS"
    printf '===================================\n'
  } >> "$LOG_FILE" 2>/dev/null || true
  exec > >(tee -a "$LOG_FILE") 2>&1
  printf 'Debug mode. Full log: %s\n' "$LOG_FILE"
}

[ "$DEBUG" = 1 ] && start_logging "$@"

if [ "$OTA_LIST" = 1 ]; then
  for h in "${OTA_HOSTS[@]}"; do echo "$h"; done
  exit 0
fi

[ -n "$IP" ] || usage 2

# --- adb ---------------------------------------------------------------
resolve_adb() {
  if command -v adb >/dev/null 2>&1; then command -v adb; return 0; fi
  local dir="$HOME/platform-tools/adb"
  [ -x "$dir" ] && { echo "$dir"; return 0; }

  local zip dl="$HOME/.cache/platform-tools-dl"
  case "$(uname -s)" in
    Linux)  zip='platform-tools-latest-linux.zip' ;;
    Darwin) zip='platform-tools-latest-darwin.zip' ;;
    *) printf '  X unsupported OS %s - install Android platform-tools and put adb on PATH\n' "$(uname -s)" >&2; return 1 ;;
  esac
  # stderr: this function's stdout is captured by the caller
  printf '\n==> Android platform-tools not found - downloading\n' >&2
  mkdir -p "$dl"
  if ! curl -fL --progress-bar "https://dl.google.com/android/repository/$zip" -o "$dl/pt.zip"; then
    printf '  X download failed\n' >&2; return 1
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
    printf '  X could not unpack the download - install unzip (or python3) and re-run\n' >&2; return 1
  fi

  chmod +x "$HOME/platform-tools/adb" 2>/dev/null || true
  if [ ! -x "$HOME/platform-tools/adb" ]; then
    printf '  X extraction did not produce adb\n' >&2; return 1
  fi
  printf ' OK installed to %s\n' "$HOME/platform-tools" >&2
  echo "$HOME/platform-tools/adb"
}

ADB="$(resolve_adb)"
if [ -z "$ADB" ] || [ ! -x "$ADB" ]; then
  die 'could not obtain adb - see the messages above'
fi
good "adb: $ADB"

# adb returns 0 even for many failures, so verify by output rather than exit code.
adb_sh() { log_event 'ADB-REQ' "shell $*"; "$ADB" shell "$@" 2>&1 | tr -d '\r' || true; }
adb_do() { log_event 'ADB-REQ' "shell $*"; "$ADB" shell "$@" >/dev/null 2>&1 || true; }

# --- DNS ---------------------------------------------------------------
set_dns_dot() {
  local host="$1"
  step "Pointing the stick at DNS-over-TLS host $host"
  adb_do settings put global private_dns_mode hostname
  adb_do settings put global private_dns_specifier "$host"
  local mode spec
  mode="$(adb_sh settings get global private_dns_mode | tr -d '\r')"
  spec="$(adb_sh settings get global private_dns_specifier | tr -d '\r')"
  info "private_dns_mode      : ${mode:-empty}"
  info "private_dns_specifier : ${spec:-empty}"
  if [ "$mode" = 'hostname' ] && [ "$spec" = "$host" ]; then
    good 'DNS profile applied'
  else
    warn 'The stick did not accept the DNS setting.'
    return 1
  fi

  step 'Checking whether the update address still resolves (advisory)'
  local ping
  ping="$(adb_sh ping -c 1 -w 3 softwareupdates.amazon.com | tr -d '\r')"
  case "$ping" in
    *"unknown host"*|*"bad address"*|*"Name or service"*|*"No address associated"*|*"0.0.0.0"*)
      good 'softwareupdates.amazon.com does not resolve - updates are blocked' ;;
    *"bytes from"*)
      warn 'softwareupdates.amazon.com STILL resolves - this profile does not block it. Check the denylist.' ;;
    *)
      warn "Could not test automatically. Output: ${ping:-none}" ;;
  esac
}

clear_dns() {
  step 'Removing the DNS settings'
  adb_do settings put global private_dns_mode off
  adb_do settings delete global private_dns_specifier
  adb_do settings delete global dns_servers
  info "private_dns_mode : $(adb_sh settings get global private_dns_mode | tr -d '\r')"
  good 'DNS back to the network default'
}

# --- connect -----------------------------------------------------------
step "Connecting to $IP:5555"
PORT_OK=1
if ! (timeout 3 bash -c "echo > /dev/tcp/$IP/5555") >/dev/null 2>&1; then
  PORT_OK=0
  warn "Port 5555 is not answering on $IP."
  warn 'On the stick: Settings -> My Fire TV -> Developer Options -> ADB debugging = ON; re-check the IP.'
fi

timeout 20 "$ADB" connect "$IP:5555" >/dev/null 2>&1 || true

log_event 'CONNECT' "target $IP:5555 (port answering: $PORT_OK)"

step 'Waiting for authorisation (accept the prompt on the TV if one appears)'
state=''
tries=30
[ "$PORT_OK" = 0 ] && tries=8
for _ in $(seq 1 "$tries"); do
  line="$("$ADB" devices | grep -F "$IP:5555" || true)"
  case "$line" in
    *device)       state='device'; break ;;
    *unauthorized) state='unauthorized' ;;
  esac
  printf '.'
  sleep 2
done
printf '\n'
[ "$state" = 'device' ] || die "no authorised ADB session (last state: ${state:-none}). 'failed to authenticate' on the first connect is normal - re-run."

# --- environment guard -------------------------------------------------
step 'Checking Fire OS version'
os_name="$(adb_sh getprop ro.build.version.name | tr -d '\r')"
fireos="$(adb_sh getprop ro.build.version.fireos | tr -d '\r')"
info "Fire OS ${fireos:-?} (${os_name:-?})"
case "$os_name $fireos" in
  *Vega*) die 'Vega OS device - sideloading and custom launchers are impossible. Nothing to do here.' ;;
esac
case "$fireos" in
  ''|7*|8*) ;;
  *) warn "Fire OS $fireos is outside the tested range (7.x / 8.x). Continuing - hooks may not take." ;;
esac

# --- DNS-only and revert paths -----------------------------------------
if [ "$DNS_OFF" = 1 ]; then clear_dns; exit 0; fi

if [ -n "$DNS_DOT" ] || [ "$DNS_AG" = 1 ] || [ "$DNS_CF" = 1 ]; then
  if [ -n "$DNS_DOT" ]; then
    set_dns_dot "$DNS_DOT" || true
  elif [ "$DNS_CF" = 1 ]; then
    set_dns_dot "$CLOUDFLARE_DOT" || true
    warn 'Cloudflare is applied, but it blocks NOTHING - Amazon updates will still reach this stick.'
    warn 'Use -d <profile>.dns.nextdns.io if the goal is to stop updates.'
  else
    set_dns_dot "$ADGUARD_DOT" || true
  fi
  step 'Domains for your resolver denylist (required for the NextDNS option to actually block updates)'
  for h in "${OTA_HOSTS[@]}"; do info "$h"; done
  exit 0
fi

if [ "$DO_UNDO" = 1 ]; then
  step 'Reverting to the Amazon launcher'
  adb_do settings put secure enabled_accessibility_services '""'
  adb_do appops set "$PROJ_PKG" SYSTEM_ALERT_WINDOW default
  adb_do dumpsys deviceidle whitelist "-$PROJ_PKG"
  adb_do am start -n com.amazon.tv.launcher/.ui.HomeActivity_vNext
  clear_dns
  good 'Hooks cleared and Amazon launcher started. Apps left installed.'
  exit 0
fi

# --- Projectivy present? ----------------------------------------------
step 'Checking for Projectivy Launcher'
if ! adb_sh pm list packages | grep -qF "$PROJ_PKG"; then
  if [ "$DO_PROJ" = 1 ]; then
    step 'Downloading Projectivy 4.71'
    curl -fL --progress-bar "$PROJ_APK_URL" -o /tmp/projectivy.apk
    "$ADB" install -r /tmp/projectivy.apk
    good 'Projectivy installed'
  else
    warn 'Projectivy is not installed. Install it on the stick via the Downloader app:'
    info "$PROJ_APK_URL"
    info 'Short codes for Downloader: 1198422 (Projectivy APK), 250931 (TROYPOINT Toolbox), 730116 (FireStickHacks)'
    info 'Or re-run with -p and it will download + install it over ADB.'
    exit 1
  fi
else
  good "found $PROJ_PKG"
fi

# --- block 1 ----------------------------------------------------------
step 'Applying Projectivy permissions + accessibility service'
adb_do appops set "$PROJ_PKG" SYSTEM_ALERT_WINDOW allow
adb_do dumpsys deviceidle whitelist "+$PROJ_PKG"
adb_do settings put secure enabled_accessibility_services "$PROJ_SVC"

enabled="$(adb_sh settings get secure enabled_accessibility_services | tr -d '\r')"
case "$enabled" in
  *ProjectivyAccessibilityService*) good 'accessibility service registered' ;;
  *) warn "accessibility service did not register (settings returned: ${enabled:-empty})" ;;
esac
printf '\n'
info 'On the TV: Projectivy -> Settings -> General -> Override current launcher = ON'

# --- block 2 ----------------------------------------------------------
if [ "$DO_HOF" = 1 ]; then
  step 'Installing Home on Fire (Home-button redirector for newer Fire OS 8 builds)'
  curl -fL --progress-bar "$HOF_APK_URL" -o /tmp/home-on-fire.apk
  "$ADB" install -r /tmp/home-on-fire.apk
  adb_do pm grant "$HOF_PKG" android.permission.WRITE_SECURE_SETTINGS
  if adb_sh dumpsys package "$HOF_PKG" | grep -q 'WRITE_SECURE_SETTINGS: granted=true'; then
    good 'WRITE_SECURE_SETTINGS granted'
  else
    warn 'WRITE_SECURE_SETTINGS grant not confirmed - the in-app accessibility toggle may fail.'
  fi
  adb_do am start -n "$HOF_PKG/.MainActivity"
  printf '\n'
  info 'On the TV, in Home on Fire:'
  info '  1. Accessibility service    = ON'
  info '  2. Choose target app...     = Projectivy Launcher'
  info '  3. Launch on boot / on wake = ON'
  info '  4. Then Projectivy -> Settings -> General -> Override current launcher = OFF'
  info '     (the two hooks conflict - only one should be active)'
fi

if [ "$DO_WARM" = 1 ]; then
  step 'Waking the device and pressing Home'
  adb_do input keyevent KEYCODE_WAKEUP
  sleep 2
  adb_do input keyevent KEYCODE_HOME
  sleep 3
  adb_sh dumpsys window | grep -F 'mCurrentFocus' || true
  warn 'com.spocky.projengmenu = win. com.amazon.tv.launcher = hook did not take (try -f).'
fi

# --- verify -----------------------------------------------------------
step 'Verification'
enabled="$(adb_sh settings get secure enabled_accessibility_services | tr -d '\r')"
info "enabled_accessibility_services : ${enabled:-empty}"
info 'Now unplug the stick for 30 seconds and power back up - the cold-boot path is the real test.'
info 'After it boots:'
info "  $ADB shell settings get secure enabled_accessibility_services"
info "  $ADB shell dumpsys window | grep mCurrentFocus"
printf '\n'
info 'Recovery if it goes wrong:'
info "  $ADB shell settings put secure enabled_accessibility_services '\"\"'"
info "  $ADB shell am start -n com.amazon.tv.launcher/.ui.HomeActivity_vNext"
printf '\n'
info 'To stop Amazon pushing an update that reverts this:'
info "  $0 -i $IP -d <profile>.dns.nextdns.io     # NextDNS profile with the denylist below"
info "  $0 -i $IP -c                              # Cloudflare: fast/private, blocks nothing"
info "  $0 -i $IP -a                              # AdGuard: ads only, does not stop updates"
info 'Domains for the denylist:'
for h in "${OTA_HOSTS[@]}"; do info "  $h"; done
printf '\n'
info 'IF A STREAMING APP MISBEHAVES after this: remove the DNS setting first, before blaming anything else:'
info "  $0 -i $IP -O"
printf '\n'
info "IF THE STICK EVER RETURNS TO AMAZON'S HOME SCREEN: just re-run this script. An update that got"
info 'through can clear the launcher settings - the apps are still installed, so it is a 30-second job.'

[ "$DEBUG" = 1 ] && printf '\nUsing debug mode - log: %s\n' "$LOG_FILE"