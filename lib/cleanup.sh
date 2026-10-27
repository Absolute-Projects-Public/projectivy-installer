#!/usr/bin/env bash
# lib/cleanup.sh - the "full cleanup" engine.
#
# Sourced by Install-Projectivy.sh (and by the tests). Everything device-facing goes through
# adb_sh (read) and adb_do (write), which the wizard already defines, so the mock adb can drive
# every path without a Fire TV.
#
# What it does, in order: preflight snapshot, disable Amazon's ad/tracking packages, starve the
# protected ones, tighten the ad settings, install the chosen launcher, optionally swap YouTube
# for SmartTube, optionally run an on-device DNS filter, then verify. Every change is written to
# an undo log so restore can reverse it exactly.

# ---- paths and defaults ---------------------------------------------------
DATA_DIR="${APP_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/data"
WIZ_MODE='home'          # home | full
WIZ_PRIME=1
WIZ_ALEXA=1
WIZ_LAUNCHER='projectivy' # projectivy | dumbtv | amazon
WIZ_DNS='device'          # device | nextdns | cloudflare | none
WIZ_REMOVE=''
WIZ_SMARTTUBE=0
CLEAN_DIR=''
UNDO_LOG=''
SDK_INT=0

DNSF_PKG='dnsfilter.android'
DNSF_VERSION='1506103'
DNSF_URL="${DNSF_URL:-https://f-droid.org/repo/dnsfilter.android_${DNSF_VERSION}.apk}"
DNSF_SHA256="${DNSF_SHA256:-3ddd0db322d1ca5fe950ea29dc1788af6e6581bb5f34694085fb4aa2e77b68ad}"

DUMBTV_VERSION='1.5'
DUMBTV_URL="https://github.com/humblemuzzu/dumbtv/releases/download/launcher-v${DUMBTV_VERSION}/dumbtv-home.apk"
DUMBTV_SHA256="${DUMBTV_SHA256:-564797e434f1960cfcb548f31ec84d79b515a8c27d5bf811e1b97972a72eeee8}"
DUMBTV_PKG='tv.dumbtv.home'
DUMBTV_SVC='tv.dumbtv.home/tv.dumbtv.home.Guard'
DUMBTV_HOME='tv.dumbtv.home/.Home'

SMARTTUBE_PKG='org.smarttube.stable'
SMARTTUBE_URL='https://github.com/yuliskov/SmartTube/releases/download/32.56s/SmartTube_stable_32.56_universal.apk'
SMARTTUBE_SHA256="${SMARTTUBE_SHA256:-4a35b90940612e048e4e9cb9e10379f7db1e84f30375994129f10a571ee04ce5}"
SMARTTUBE_VERSION_CODE=2446
YT_PKG='com.amazon.firetv.youtube'

DNSF_CONF_URL='https://raw.githubusercontent.com/IngoZenz/personaldnsfilter/master/app/src/main/assets/dnsfilter.conf'
HAGEZI_URL='https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/native.amazon-onlydomains.txt'

# ---- small helpers --------------------------------------------------------
# appdata_archive / restore_app_data: the only way into an app's folder on Android 11+
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/appdata.sh"

# Fire OS 8 (and some other Android 11 builds) ship with the backup service switched off, so an
# adb restore is refused before it can even ask for confirmation. Cheaper to ask first.
backup_available() {
  local out; out=$(adb_sh bmgr enabled 2>/dev/null)
  case "$out" in
    *"not activated"*|*"not available"*|*"not enabled"*|*"Unknown command"*|*"unknown command"*) return 1 ;;
  esac
  return 0
}

dnsf_signer() { sed 's/#.*//' "$DATA_DIR/personaldnsfilter-signer.txt" | awk 'NF {print; exit}'; }

data_list() {  # data_list <file-in-data/>  -> first field of every non-comment line
  local f="$DATA_DIR/$1"
  [ -f "$f" ] || return 0
  sed 's/#.*//' "$f" | awk 'NF {print $1}'
}

ask_yn() {  # ask_yn <prompt> <default 0|1> ; 0 = yes
  local prompt="$1" def="${2:-1}" reply
  if [ "$def" = 1 ]; then printf '%s [Y/n] ' "$prompt"; else printf '%s [y/N] ' "$prompt"; fi
  if ! read -r reply; then INPUT_EOF=1; log_event 'INPUT' "answer to '$prompt': <eof>"; return 1; fi
  log_event 'INPUT' "answer to '$prompt': ${reply:-<blank>}"
  [ -z "$reply" ] && { [ "$def" = 1 ]; return; }
  case "$reply" in [yY]*) return 0 ;; *) return 1 ;; esac
}

present_pkg() {  # present_pkg <package> -> 0 when installed
  adb_sh pm list packages 2>/dev/null | tr -d '\r' | grep -qx "package:$1"
}

pkg_disabled() {
  adb_sh pm list packages -d 2>/dev/null | tr -d '\r' | grep -qx "package:$1"
}

pkg_version() {
  adb_sh dumpsys package "$1" 2>/dev/null | sed -n 's/.*versionCode=\([0-9]*\).*/\1/p' | head -1
}

uid_of() {
  adb_sh dumpsys package "$1" 2>/dev/null | sed -n 's/.*userId=\([0-9]*\).*/\1/p' | head -1
}

front_activity() {
  adb_sh dumpsys window 2>/dev/null | tr -d '\r' |
    sed -n 's/.*mCurrentFocus=Window{[^ ]* [^ ]* \([^ }]*\).*/\1/p' | head -1
}

reverse_lines() { awk '{a[NR]=$0} END {for (i=NR;i>0;i--) print a[i]}'; }

fetch_verify() {  # fetch_verify <url> <sha256> <dest> ; 1 on failure
  local url="$1" want="$2" dest="$3" got='' src=''
  if [ -n "${CLEANUP_APK_DIR:-}" ]; then                       # tests: no network
    src="$CLEANUP_APK_DIR/$(basename "${url%%\?*}")"
    [ -f "$src" ] || { warn "test fixture missing: $src"; return 1; }
    cp "$src" "$dest" || return 1
  else
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL --retry 3 --max-time 300 -o "$dest" "$url" || { warn "download failed: $url"; return 1; }
    elif command -v wget >/dev/null 2>&1; then
      wget -q -O "$dest" "$url" || { warn "download failed: $url"; return 1; }
    else
      warn 'Neither curl nor wget is available to download the file.'; return 1
    fi
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    got=$(sha256sum "$dest" | awk '{print $1}')
  elif command -v shasum >/dev/null 2>&1; then
    got=$(shasum -a 256 "$dest" | awk '{print $1}')
  else
    warn 'No sha256 tool (sha256sum or shasum) - refusing to install an unverified file.'; return 1
  fi
  if [ "$got" != "$want" ]; then
    bad "Checksum mismatch - the file is not the published build, so it was not installed."
    dim "  expected $want"
    dim "  got      $got"
    return 1
  fi
  return 0
}

# ---- questions ------------------------------------------------------------

wiz_questions() {
  title 'A few questions'
  body "Your answers decide what gets touched. Nothing is removed unless you name it, and every
change can be undone from the main menu afterwards."

  if ask_yn 'Do you watch Prime Video? (yes keeps the servers it needs reachable)' 1; then
    WIZ_PRIME=1; dim 'Prime Video: kept working'
  else
    WIZ_PRIME=0; dim "Prime Video: its servers are blocked, so it will not play"
  fi

  if ask_yn "Keep Alexa and the remote's voice button? (no switches Alexa and the microphone off)" 1; then
    WIZ_ALEXA=1; dim 'Alexa: kept'
  else
    WIZ_ALEXA=0; dim 'Alexa: switched off'
  fi

  choose 'Which home screen?' \
    'Projectivy Launcher (recommended - categories, wallpaper, app hiding)' \
    'dumbtv home (tiny: 54 KB, no internet permission, apps and inputs only)' \
    "Keep Amazon's home screen (remove the ads around it, nothing else)"
  case "$MENU_RESULT" in
    Projectivy*)  WIZ_LAUNCHER='projectivy' ;;
    'dumbtv home'*) WIZ_LAUNCHER='dumbtv' ;;
    *)            WIZ_LAUNCHER='amazon' ;;
  esac
  dim "home screen: $WIZ_LAUNCHER"

  choose 'Block Amazon on the TV itself?' \
    'On-device DNS filter (no account, blocks telemetry and updates)' \
    'NextDNS profile (no app, but you make a free account)' \
    'Cloudflare (fast, private, blocks nothing)' \
    'Nothing - leave DNS alone'
  case "$MENU_RESULT" in
    'On-device'*) WIZ_DNS='device' ;;
    NextDNS*)     WIZ_DNS='nextdns' ;;
    Cloudflare*)  WIZ_DNS='cloudflare' ;;
    *)            WIZ_DNS='none' ;;
  esac
  dim "DNS: $WIZ_DNS"

  if ask_yn 'Replace the YouTube app with SmartTube? (no ads, no Shorts, account untouched)' 0; then
    WIZ_SMARTTUBE=1; dim 'YouTube: will be replaced with SmartTube (stock app disabled, not deleted)'
  else
    WIZ_SMARTTUBE=0; dim 'YouTube: left alone'
  fi

  body "
Apps are only removed when you name them. Say them by name (Netflix, Prime Video, Spotify...) or by
package id. Press Enter for none."
  printf 'Apps to remove: '
  local reply=''
  if ! read -r reply; then INPUT_EOF=1; return 1; fi
  log_event 'INPUT' "apps to remove: ${reply:-<none>}"
  WIZ_REMOVE="$reply"
  NEXT='plan'
}

resolve_apps() {  # resolve_apps "<names or ids>" -> package ids, one per line
  local word out='' pkg
  for word in $1; do
    case "$word" in
      *.*) printf '%s\n' "$word"; continue ;;
    esac
    pkg=$(awk -F'|' -v want="$word" '
      { name=tolower($1); gsub(/^[ \t]+|[ \t]+$/, "", name) }
      index(name, tolower(want)) == 1 { gsub(/[ \t]/, "", $2); print $2; exit }
    ' "$DATA_DIR/apps.txt" 2>/dev/null)
    if [ -n "$pkg" ]; then
      printf '%s\n' "$pkg"
    else
      warn "No package id for '$word' - skipping it. Try the package id instead (pm list packages -3)."
    fi
  done
}

plan_summary() {
  title 'Here is what will change'
  body "Disabled, never deleted: $(data_list packages.txt | wc -l | tr -d ' ') Amazon ad, telemetry and
experiment packages$( [ "$WIZ_ALEXA" = 0 ] && printf ', plus Alexa (%s)' "$(data_list alexa.txt | wc -l | tr -d ' ')")." 
  body "Starved instead (Amazon protects them): $(data_list protected.txt | wc -l | tr -d ' ') packages lose
background running and background data."
  body "Ad tracking and usage reporting: switched off."
  case "$WIZ_LAUNCHER" in
    projectivy) body 'Home screen: Projectivy Launcher.' ;;
    dumbtv)     body 'Home screen: dumbtv home (54 KB, no internet permission).' ;;
    *)          body "Home screen: Amazon's, left in place." ;;
  esac
  case "$WIZ_DNS" in
    device) body 'DNS: on-device filter, no account, blocks about 400 Amazon hosts.' ;;
    nextdns) body 'DNS: your NextDNS profile (you will paste the address).' ;;
    cloudflare) body 'DNS: Cloudflare. Blocks nothing.' ;;
    *) body 'DNS: left alone.' ;;
  esac
  [ "$WIZ_SMARTTUBE" = 1 ] && body 'YouTube: replaced with SmartTube (stock app disabled).'
  [ -n "${WIZ_REMOVE// /}" ] && body "Apps to remove: $WIZ_REMOVE"
  body "
Your apps and everything you watch stay. Undo in the main menu reverses all of it."
  choose 'Go ahead?' 'Yes - start the cleanup' 'No - back to the questions'
  case "$MENU_RESULT" in
    Yes*) NEXT='clean_run' ;;
    *)    NEXT='questions' ;;
  esac
}

# ---- preflight ------------------------------------------------------------

clean_begin() {
  CLEAN_DIR="${LOGDIR:-./logs}/cleanup-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$CLEAN_DIR" 2>/dev/null || CLEAN_DIR="$(mktemp -d)"
  UNDO_LOG="$CLEAN_DIR/undo.tsv"
  : > "$UNDO_LOG"
  title 'Checking the TV before anything changes'
  SDK_INT=$(adb_sh getprop ro.build.version.sdk | tr -dc '0-9')
  [ -n "$SDK_INT" ] || SDK_INT=0
  local model os free_pkgs free_dis model_line
  model=$(adb_sh getprop ro.product.model | tr -d '\r')
  os=$(adb_sh getprop ro.build.version.name | tr -d '\r')
  free_pkgs=$(adb_sh pm list packages 2>/dev/null | wc -l | tr -d ' ')
  free_dis=$(adb_sh pm list packages -d 2>/dev/null | wc -l | tr -d ' ')
  model_line="${model:-unknown device} / ${os:-Fire OS} / SDK ${SDK_INT}"
  ok "$model_line"
  ok "$free_pkgs packages installed, $free_dis already disabled"
  adb_sh settings list secure > "$CLEAN_DIR/settings-secure-before.txt" 2>/dev/null || true
  adb_sh settings list global > "$CLEAN_DIR/settings-global-before.txt" 2>/dev/null || true
  adb_sh pm list packages -d > "$CLEAN_DIR/disabled-before.txt" 2>/dev/null || true
  adb_sh pm list packages > "$CLEAN_DIR/packages-before.txt" 2>/dev/null || true
  printf '%s\n' "$model_line" > "$CLEAN_DIR/device.txt"
  log_event 'CLEAN' "preflight: $model_line, snapshot in $CLEAN_DIR"
  dim "Snapshot kept in $CLEAN_DIR - Undo reads it if the undo log is ever missing."
  NEXT='clean_debloat'
}

# ---- debloat --------------------------------------------------------------

starve_pkg() {  # protected package: no background run, no background data
  local p="$1" uid
  adb_do appops set "$p" RUN_IN_BACKGROUND ignore
  [ "${SDK_INT:-0}" -ge 28 ] && adb_do appops set "$p" RUN_ANY_IN_BACKGROUND ignore
  uid=$(uid_of "$p")
  [ -n "$uid" ] && adb_do cmd netpolicy add restrict-background-blacklist "$uid"
  printf 'pkg\t%s\tstarved\n' "$p" >> "$UNDO_LOG"
}

disable_pkg() {  # -> echoes one of: disabled protected system suspect
  local p="$1" out
  out=$(adb_sh pm disable-user --user 0 "$p" 2>&1 | tail -1)
  case "$out" in
    *"new state: disabled"*)                       printf 'disabled\n' ;;
    *"Cannot disable a protected package"*|*SecurityException*) printf 'protected\n' ;;
    *"Shell cannot change component state"*)
      if adb_sh dumpsys package "$p" | grep -q 'enabled=2'; then printf 'system\n'; else printf 'suspect\n'; fi ;;
    *)                                             printf 'suspect\n' ;;
  esac
}

clean_debloat() {
  title 'Removing the ads and the tracking'
  local list p keep state n_dis=0 n_star=0 n_skip=0 n_susp=0 n_abs=0
  local never keep_pkgs
  never=" $(data_list never-disable.txt | tr '\n' ' ') "
  keep_pkgs=" $(resolve_apps "$WIZ_REMOVE" | tr '\n' ' ') "

  list="$(data_list packages.txt)"
  [ "$WIZ_ALEXA" = 0 ] && list="$list
$(data_list alexa.txt)"
  [ "$WIZ_PRIME" = 1 ] || dim 'Prime Video is being blocked too, as you asked (it will not play).'

  for p in $list; do
    case "$never" in *" $p "*) printf '  %-44s kept (never-disable)\n' "$p"; n_skip=$((n_skip+1)); continue ;; esac
    case "$keep_pkgs" in *" $p "*) printf '  %-44s kept (you asked)\n' "$p"; n_skip=$((n_skip+1)); continue ;; esac
    if ! present_pkg "$p"; then printf '  %-44s not on this TV\n' "$p"; n_abs=$((n_abs+1)); continue; fi
    if pkg_disabled "$p"; then printf '  %-44s already off\n' "$p"; continue; fi
    state=$(disable_pkg "$p")
    case "$state" in
      disabled)  printf '  %-44s off\n' "$p"; n_dis=$((n_dis+1)); printf 'pkg\t%s\tdisabled\n' "$p" >> "$UNDO_LOG" ;;
      protected) printf '  %-44s protected - starved\n' "$p"; n_star=$((n_star+1)); starve_pkg "$p" ;;
      system)    printf '  %-44s already off by the system\n' "$p" ;;
      *)         printf '  %-44s could not change (flagged)\n' "$p"; n_susp=$((n_susp+1))
                 printf 'pkg\t%s\tsuspect\n' "$p" >> "$UNDO_LOG" ;;
    esac
  done

  # protected.txt holds packages Amazon refuses to disable: starve them regardless of the list above
  for p in $(data_list protected.txt); do
    present_pkg "$p" || continue
    case "$never" in *" $p "*) continue ;; esac
    starve_pkg "$p"; n_star=$((n_star+1))
    printf '  %-44s protected - starved\n' "$p"
  done

  # Apps you named: a system app is disabled (restorable), a store app is uninstalled and comes
  # back from the Appstore. Either way it is in the undo log.
  local rem
  rem="$(resolve_apps "$WIZ_REMOVE")"
  if [ -n "$rem" ]; then
    printf '\n  apps you asked to remove:\n'
    for p in $rem; do
      case "$never" in *" $p "*) printf '  %-44s keeps the TV working - not touched\n' "$p"; continue ;; esac
      if ! present_pkg "$p"; then printf '  %-44s not on this TV\n' "$p"; continue; fi
      if adb_sh pm list packages -s 2>/dev/null | tr -d '\r' | grep -qx "package:$p"; then
        state=$(disable_pkg "$p")
        if [ "$state" = disabled ]; then
          printf '  %-44s disabled (system app, restorable)\n' "$p"
          printf 'pkg\t%s\tdisabled\n' "$p" >> "$UNDO_LOG"
        else
          printf '  %-44s cannot be changed on this build\n' "$p"
        fi
      else
        adb_do pm uninstall --user 0 "$p" >/dev/null
        if present_pkg "$p"; then
          printf '  %-44s could not be removed\n' "$p"
        else
          printf '  %-44s removed (Appstore reinstalls it)\n' "$p"
          printf 'pkg\t%s\tuninstalled\n' "$p" >> "$UNDO_LOG"
        fi
      fi
    done
  fi

  ok "$n_dis disabled, $n_star starved, $n_skip kept, $n_abs not present"
  [ "$n_susp" -gt 0 ] && warn "$n_susp package(s) could not be changed on this build - they are listed in the undo log and the debug log."
  log_event 'CLEAN' "debloat: disabled=$n_dis starved=$n_star kept=$n_skip absent=$n_abs suspect=$n_susp"
  NEXT='clean_settings'
}

clean_settings() {
  title 'Turning off ad tracking and usage reporting'
  local ns key value old n=0
  while read -r ns key value; do
    [ -n "$ns" ] || continue
    case "$ns" in \#*) continue ;; esac
    [ -n "$key" ] && [ -n "$value" ] || continue
    old=$(adb_sh settings get "$ns" "$key" | tr -d '\r\n' | tail -c 200)
    printf 'settings\t%s\t%s\t%s\n' "$ns" "$key" "${old:-null}" >> "$UNDO_LOG"
    adb_do settings put "$ns" "$key" "$value"
    n=$((n+1))
  done < <(grep -v '^[[:space:]]*#' "$DATA_DIR/settings.txt" | awk 'NF>=3')
  ok "$n setting(s) tightened"
  NEXT='clean_launcher'
}

# ---- launcher -------------------------------------------------------------

a11y_add() {  # keep every other service, add ours
  local comp="$1" cur
  cur=$(adb_sh settings get secure enabled_accessibility_services | tr -d '\r')
  case "$cur" in
    ''|null) cur="$comp" ;;
    *"$comp"*) : ;;
    *) cur="$cur:$comp" ;;
  esac
  # Clearing first makes the accessibility manager rebind a service whose process died. Without
  # this, writing the same value back is a no-op and the launcher's guard never re-arms.
  adb_do settings put secure enabled_accessibility_services '""'
  sleep 1
  adb_do settings put secure accessibility_enabled 0
  adb_do settings put secure accessibility_enabled 1
  adb_do settings put secure enabled_accessibility_services "$cur"
}

a11y_remove() {  # remove only <component>, leaving every other service the user has
  local comp="$1" cur parts out='' p
  cur=$(adb_sh settings get secure enabled_accessibility_services | tr -d '\r')
  case "$cur" in ''|null) return 0 ;; esac
  IFS=':' read -r -a parts <<< "$cur"
  for p in "${parts[@]}"; do
    [ "$p" = "$comp" ] && continue
    out="${out:+$out:}$p"
  done
  if [ -z "$out" ]; then
    adb_do settings put secure enabled_accessibility_services '""'
  else
    adb_do settings put secure enabled_accessibility_services "$out"
  fi
}

try_set_home() {  # try_set_home <pkg>/<activity> <package>  -> 0 if it actually came to the front
  local comp="$1" pkg="$2" front
  adb_do cmd package set-home-activity "$comp"
  sleep 2
  adb_do input keyevent KEYCODE_HOME
  sleep 3
  front=$(front_activity)
  log_event 'CLEAN' "set-home $comp -> front=$front"
  case "$front" in *"$pkg"*) return 0 ;; *) return 1 ;; esac
}

clean_launcher() {
  case "$WIZ_LAUNCHER" in
    amazon)
      title "Leaving Amazon's home screen in place"
      ok 'Ads are already gone from the rows themselves - no launcher change needed.'
      printf 'launcher\tamazon\n' >> "$UNDO_LOG"; NEXT='clean_smarttube' ; return ;;
    projectivy)
      title 'Installing Projectivy Launcher'
      if present_pkg "$PROJ_PKG"; then
        ok 'Projectivy is already installed'
      else
        if ! install_projectivy_adb; then
          warn 'Projectivy did not install. Install it from Downloader (code 1198422) and run this again.'
          printf 'launcher\tprojectivy\tfailed\n' >> "$UNDO_LOG"; NEXT='clean_smarttube'; return
        fi
      fi
      adb_do appops set "$PROJ_PKG" SYSTEM_ALERT_WINDOW allow
      adb_do dumpsys deviceidle whitelist "+$PROJ_PKG"
      a11y_add "$PROJ_SVC"
      printf 'launcher\tprojectivy\n' >> "$UNDO_LOG"
      # Fire OS 8 answers "Success" to set-home-activity and keeps Amazon's launcher anyway (priority
      # 950), so this probe only passes when Projectivy's own guard is armed. Verified on 8.1.8.5.
      if try_set_home "$PROJ_PKG/.ui.home.MainActivity" "$PROJ_PKG"; then
        ok 'Projectivy is the home screen - no remote presses needed'
      else
        warn "Amazon still owns the Home button on this build."
        dim 'Press it once yourself: Projectivy > Settings > General > Override current launcher = ON'
        dim 'That switch lives in Projectivy own settings, which ADB cannot write.'
        pause 'Press Enter once that switch is on...'
      fi ;;
    dumbtv)
      title 'Installing dumbtv home'
      if present_pkg "$DUMBTV_PKG"; then
        ok 'dumbtv home is already installed'
      else
        local tmp; tmp="$(mktemp -d)"
        if fetch_verify "$DUMBTV_URL" "$DUMBTV_SHA256" "$tmp/$DUMBTV_PKG.apk"; then
          local out; out=$("$ADB" install -r "$tmp/$DUMBTV_PKG.apk" 2>&1 </dev/null | tail -1)
          present_pkg "$DUMBTV_PKG" || { warn "dumbtv home did not install: $out"; NEXT='clean_smarttube'; rm -rf "$tmp"; return; }
          ok 'dumbtv home installed (checksum verified)'
        else
          warn 'Could not download dumbtv home - skipping the launcher step.'
          NEXT='clean_smarttube'; rm -rf "$tmp"; return
        fi
        rm -rf "$tmp"
      fi
      a11y_add "$DUMBTV_SVC"
      printf 'launcher\tdumbtv\n' >> "$UNDO_LOG"
      if try_set_home "$DUMBTV_HOME" "$DUMBTV_PKG"; then
        ok 'dumbtv home is the home screen'
      else
        warn 'Amazon still owns the Home button on this build.'
        dim 'dumbtv home needs its accessibility guard bound. Open it once from the apps row.'
        pause 'Press Enter once dumbtv home has opened on the TV...'
      fi ;;
  esac
  NEXT='clean_smarttube'
}

# ---- SmartTube ------------------------------------------------------------

clean_smarttube() {
  [ "$WIZ_SMARTTUBE" = 1 ] || { NEXT='clean_dns'; return; }
  title 'Replacing YouTube with SmartTube'
  body "SmartTube is the open-source TV YouTube client with no ad code. Your account and subscriptions
are untouched; only the app on this TV changes. The stock app is disabled, not deleted, so Undo
brings it straight back."
  local tmp out code attempt
  tmp="$(mktemp -d)"
  if ! fetch_verify "$SMARTTUBE_URL" "$SMARTTUBE_SHA256" "$tmp/$SMARTTUBE_PKG.apk"; then
    warn 'SmartTube download failed - YouTube left as it is.'
    rm -rf "$tmp"; NEXT='clean_dns'; return
  fi
  code=0
  for attempt in 1 2; do
    out=$("$ADB" install -r "$tmp/$SMARTTUBE_PKG.apk" 2>&1 </dev/null | tail -1)
    sleep 1
    code=$(pkg_version "$SMARTTUBE_PKG"); code="${code:-0}"
    [ "$code" -ge "$SMARTTUBE_VERSION_CODE" ] && break
    [ "$attempt" = 1 ] && dim 'Not installed yet - the wifi can drop after the push; trying once more.'
  done
  rm -rf "$tmp"
  if [ "$code" -lt "$SMARTTUBE_VERSION_CODE" ]; then
    warn "SmartTube did not install ($out). YouTube left alone."
    NEXT='clean_dns'; return
  fi
  ok "SmartTube installed (versionCode $code)"
  printf 'app\tsmarttube\tinstalled\n' >> "$UNDO_LOG"
  if present_pkg "$YT_PKG"; then
    if pkg_disabled "$YT_PKG"; then
      ok 'YouTube was already disabled'
    else
      adb_do pm disable-user --user 0 "$YT_PKG"
      if pkg_disabled "$YT_PKG"; then
        ok 'YouTube app disabled (still installed, Undo re-enables it)'
        printf 'app\tyoutube\tdisabled\n' >> "$UNDO_LOG"
      else
        warn 'Could not disable the YouTube app - both apps will show on the home screen.'
      fi
    fi
  else
    ok 'The YouTube app is not installed on this TV'
  fi
  dim 'Two things worth setting once in SmartTube: Hide shorts everywhere, and the 1080p vp9 video preset.'
  NEXT='clean_dns'
}

# ---- DNS ------------------------------------------------------------------

compose_blocklist() {  # writes to stdout: HaGeZi Amazon feed + our extras, minus Prime/Alexa hosts
  local feed='' tmp=''
  if [ -n "${CLEANUP_BLOCKLIST:-}" ] && [ -f "$CLEANUP_BLOCKLIST" ]; then
    feed="$CLEANUP_BLOCKLIST"
  else
    local tmp; tmp="$(mktemp)"
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL --retry 2 --max-time 120 -o "$tmp" "$HAGEZI_URL" 2>/dev/null || : > "$tmp"
    elif command -v wget >/dev/null 2>&1; then
      wget -q -O "$tmp" "$HAGEZI_URL" 2>/dev/null || : > "$tmp"
    fi
    feed="$tmp"
  fi
  {
    sed 's/#.*//' "$feed" 2>/dev/null | awk 'NF {print tolower($1)}'
    data_list extra-hosts.txt
  } | awk 'NF && !seen[$0]++' | {
    if [ "$WIZ_PRIME" = 1 ]; then
      grep -viE 'aiv-delivery|aiv-cdn|device-messaging-na\.amazon\.com' || true
    else
      cat
    fi
  }
  [ -n "${tmp:-}" ] && rm -f "$tmp"
}

clean_nextdns() {
  title 'Set up the NextDNS profile'
  body "On a phone or computer:

  1. Go to my.nextdns.io and create a free profile (name it after this TV).
  2. Open the profile > Denylist tab > add each of these:

$(for h in "${OTA_HOSTS[@]}"; do echo "         $h"; done)

  3. Setup tab > copy the DNS-over-TLS address. It looks like: abcd1234.dns.nextdns.io"
  printf '\nPaste the DNS-over-TLS address (or leave blank to skip): '
  local reply=''
  if ! read -r reply; then INPUT_EOF=1; NEXT='clean_verify'; return; fi
  reply="$(printf '%s' "$reply" | tr -d ' ')"
  log_event 'INPUT' "NextDNS hostname: ${reply:-<blank>}"
  case "$reply" in
    '') NEXT='clean_verify' ;;
    *.*) apply_dns "$reply" blocking || true
         printf 'dns\tnextdns\t%s\n' "$reply" >> "$UNDO_LOG"
         NEXT='clean_verify' ;;
    *)   warn 'That does not look like a DNS-over-TLS hostname (e.g. abcd1234.dns.nextdns.io).'
         NEXT='clean_nextdns' ;;
  esac
}

clean_dns() {
  case "$WIZ_DNS" in
    none)       NEXT='clean_verify'; return ;;
    cloudflare) apply_dns "$CLOUDFLARE_DOT" noblock || true
                printf 'dns\tcloudflare\t%s\n' "$CLOUDFLARE_DOT" >> "$UNDO_LOG"
                NEXT='clean_verify'; return ;;
    nextdns)    NEXT='clean_nextdns'; return ;;
  esac
  title 'Setting up the on-device DNS filter'
  body "This installs a small open-source filter on the TV itself. No account, no router changes: the TV
stops being able to reach Amazon's telemetry and update servers, and everything else keeps working."
  local tmp; tmp="$(mktemp -d)"
  local have; have=$(pkg_version "$DNSF_PKG")
  if [ "$have" = "$DNSF_VERSION" ]; then
    ok "The filter is already installed (version $DNSF_VERSION)"
  else
    dim "Downloading personalDNSfilter $DNSF_VERSION from F-Droid..."
    if ! fetch_verify "$DNSF_URL" "$DNSF_SHA256" "$tmp/$DNSF_PKG.apk"; then
      warn 'Could not download the filter - DNS left as it was.'
      rm -rf "$tmp"; NEXT='clean_verify'; return
    fi
    local out; out=$("$ADB" install -r "$tmp/$DNSF_PKG.apk" 2>&1 </dev/null | tail -1)
    have=$(pkg_version "$DNSF_PKG")
    if [ "$have" != "$DNSF_VERSION" ]; then
      warn "The filter did not install: $out"
      rm -rf "$tmp"; NEXT='clean_verify'; return
    fi
    ok "Filter installed (version $have)"
  fi
  printf 'dns\tdevice\t%s\n' "$DNSF_VERSION" >> "$UNDO_LOG"

  adb_do dumpsys deviceidle whitelist "+$DNSF_PKG"      # survive Doze
  dim 'Building the blocklist...'
  compose_blocklist > "$tmp/blocklist.txt"
  local n; n=$(wc -l < "$tmp/blocklist.txt" | tr -d ' ')
  if [ "${n:-0}" -lt 10 ]; then
    warn "The blocklist came out too small ($n entries) - not enabling the filter."
    rm -rf "$tmp"; NEXT='clean_verify'; return
  fi
  ok "$n hosts in the list"

  # Fire OS 7 lets adb write the app's folder. Fire OS 8 (Android 11) does not, so the files go in
  # with an `adb restore` archive instead; Android unpacks them as the app after one confirmation.
  local appdir="/sdcard/Android/data/$DNSF_PKG/files/PersonalDNSFilter"
  local mediadir="/sdcard/Android/media/$DNSF_PKG"
  local placed='none'
  local gw; gw=$(adb_sh ip route | sed -n 's/.*via \([0-9][0-9.]*\).*/\1/p' | head -1)
  log_event 'CLEAN' "dns filter: gateway ${gw:-unknown}, sdk $SDK_INT"

  if [ "${SDK_INT:-0}" -ge 30 ] && backup_available; then
    # Build the app's own config from the upstream template, with downloads switched off.
    if curl -fsSL --retry 2 --max-time 60 -o "$tmp/dnsfilter.conf" "$DNSF_CONF_URL" 2>/dev/null; then
      sed -i \
        -e 's|^filterAutoUpdateURL = |#filterAutoUpdateURL = |' \
        -e 's|^previousAutoUpdateURL = .*|previousAutoUpdateURL = |' \
        -e 's|^detectDNS = .*|detectDNS = false|' \
        -e 's|^routeIPs =.*|routeIPs = '"${gw:-}"'|' \
        -e 's|^routeUnderlyingDNS = .*|routeUnderlyingDNS = true|' \
        -e 's|^showInitialInfoPopUp = .*|showInitialInfoPopUp = false|' \
        -e 's|^reloadIntervalDays = .*|reloadIntervalDays = 3650|' \
        -e 's|^filterHostsFile = .*|filterHostsFile = FILTERHOSTS.TXT|' \
        -e 's|^androidAppWhiteList = .*|androidAppWhiteList = <none>|' \
        "$tmp/dnsfilter.conf"
      if grep -q '^filterHostsFile = FILTERHOSTS.TXT' "$tmp/dnsfilter.conf"; then
        local data="$tmp/appdata/PersonalDNSFilter"
        mkdir -p "$data"
        cp "$tmp/dnsfilter.conf" "$data/dnsfilter.conf"
        cp "$tmp/blocklist.txt"  "$data/FILTERHOSTS.TXT"
        printf '%s\n%s\n' "$n" "$(date +%s)000" > "$data/FILTERHOSTS.TXT.DLD_CNT"
        : > "$data/IDX_OUTDATED"
        printf '%s' "$DNSF_VERSION" > "$data/VERSION.TXT"
        if appdata_archive "$tmp/appdata.ab" "$DNSF_PKG" "$DNSF_VERSION" "$SDK_INT" "$(dnsf_signer)" "$data" PersonalDNSFilter; then
          adb_do am force-stop "$DNSF_PKG"
          sleep 2
          if restore_app_data "$tmp/appdata.ab"; then
            placed='restore'
            ok 'Config and blocklist written into the app (no taps needed)'
          else
            warn 'The restore did not complete - falling back to the file-based route.'
          fi
        fi
      else
        warn 'The filter config template changed upstream - using the file-based route.'
      fi
    else
      dim 'Could not fetch the filter config template - using the file-based route.'
    fi
  else
    # Android 9 and 10: the app folder is still writable by adb.
    mkdir -p "$tmp/push"
    cp "$tmp/blocklist.txt" "$tmp/push/FILTERHOSTS.TXT"
    if "$ADB" push "$tmp/push/FILTERHOSTS.TXT" "$appdir/FILTERHOSTS.TXT" >/dev/null 2>&1 </dev/null; then
      placed='app'
    fi
  fi

  if [ "$placed" = 'none' ] || [ "$placed" = 'app' ]; then
    # Always leave the list somewhere adb can write, so the manual route is possible.
    adb_do mkdir -p "$mediadir"
    cp "$tmp/blocklist.txt" "$tmp/blocklist-media.txt"
    if "$ADB" push "$tmp/blocklist-media.txt" "$mediadir/blocklist.txt" >/dev/null 2>&1 </dev/null; then
      [ "$placed" = 'none' ] && placed='media'
    fi
  fi
  log_event 'CLEAN' "dns filter config placed via $placed ($n hosts)"

  adb_do settings put secure always_on_vpn_app "$DNSF_PKG"
  adb_do am start -n "$DNSF_PKG/.DNSProxyActivity"
  ok 'Filter configured to start with the TV'

  if [ "$placed" = 'media' ]; then
    body "
This build will not let a computer write into the app's own folder, and its backup service is
switched off, so the list has to be pointed at once on the TV:

  1. Open personalDNSfilter from the apps row.
  2. Advanced settings > Configure filter update.
  3. Tap the pencil on the first entry and replace the URL with:
     file:///sdcard/Android/media/$DNSF_PKG/blocklist.txt
  4. Untick the other entries, then go back so it reloads.
  5. Accept the VPN prompt if it appears.

If that is more than you want to do, the NextDNS option blocks Amazon's update servers with no
app at all - it is the safer choice on Fire OS 8."
    pause 'Press Enter once that is done (or just to carry on)...'
  fi
  dim 'Verification happens on the next screen.'
  rm -rf "$tmp"
  NEXT='clean_verify'
}

# ---- verify ---------------------------------------------------------------

clean_verify() {
  title 'Checking the result'
  local front blocked okcount=0 failcount=0 host line
  front=$(front_activity)
  case "$WIZ_LAUNCHER" in
    projectivy) case "$front" in *"$PROJ_PKG"*) ok "Home screen: Projectivy ($front)" ;; *) warn "Front app is $front, not Projectivy" ;; esac ;;
    dumbtv)     case "$front" in *"$DUMBTV_PKG"*) ok "Home screen: dumbtv home ($front)" ;; *) warn "Front app is $front, not dumbtv home" ;; esac ;;
    *)          ok "Home screen left as Amazon's" ;;
  esac

  local dis; dis=$(adb_sh pm list packages -d 2>/dev/null | grep -c . || true)
  ok "$dis Amazon packages are disabled"

  if [ "$WIZ_DNS" = device ]; then
    for host in softwareupdates.amazon.com device-metrics-us.amazon.com; do
      line=$(adb_sh ping -c 1 -W 2 "$host" 2>/dev/null | head -1)
      case "$line" in
        *0.0.0.0*|*127.0.0.1*) ok "$host is blocked"; okcount=$((okcount+1)) ;;
        *) warn "$host is NOT blocked yet ($line)"; failcount=$((failcount+1)) ;;
      esac
    done
    line=$(adb_sh ping -c 1 -W 2 m.media-amazon.com 2>/dev/null | head -1)
    case "$line" in
      *0.0.0.0*) warn 'Artwork host is blocked - the home screen will look bare. Undo the DNS step.' ;;
      *) ok 'Everyday Amazon hosts still resolve (app artwork works)' ;;
    esac
    if [ "$failcount" -gt 0 ]; then
      body "
If the filter is not blocking yet: reboot the TV (hold Select+Play for 5 seconds, or unplug it for
30 seconds) and run this wizard again with 'Undo everything' first if it still looks wrong."
    fi
  fi

  if [ "$WIZ_SMARTTUBE" = 1 ]; then
    if present_pkg "$SMARTTUBE_PKG"; then ok "SmartTube installed (versionCode $(pkg_version "$SMARTTUBE_PKG"))"; fi
    if pkg_disabled "$YT_PKG"; then ok 'The stock YouTube app is disabled'; fi
  fi

  body "
Everything changed here is listed in $UNDO_LOG, and Undo in the main menu reverses it."
  NEXT='clean_done'
}

clean_done() {
  title 'Cleanup finished'
  body "Your TV now has no ad rows, no tracking packages running, and no path to Amazon's telemetry."
  choose 'Anything else?' \
    'Close (all done)' \
    'Undo everything now' \
    'Run the checks again'
  case "$MENU_RESULT" in
    'Undo everything'*) NEXT='clean_undo' ;;
    'Run the checks again'*) NEXT='clean_verify' ;;
    *) NEXT='exit' ;;
  esac
}

# ---- undo -----------------------------------------------------------------

clean_undo_packages() {
  local kind a b c try
  while IFS=$'\t' read -r kind a b c; do
    [ -n "${kind:-}" ] || continue
    case "$kind" in
      pkg)
        case "${b:-}" in
          disabled)
            adb_do pm enable --user 0 "$a"
            pkg_disabled "$a" || ok "re-enabled $a" ;;
          starved)
            adb_do appops set "$a" RUN_IN_BACKGROUND allow
            [ "${SDK_INT:-0}" -ge 28 ] && adb_do appops set "$a" RUN_ANY_IN_BACKGROUND allow
            try=$(uid_of "$a")
            [ -n "$try" ] && adb_do cmd netpolicy remove restrict-background-blacklist "$try"
            ok "restored background for $a" ;;
          uninstalled)
            if adb_do cmd package install-existing "$a" >/dev/null 2>&1; then
              ok "reinstalled $a"
            else
              warn "$a has to come back from the Appstore (it was a store app)"
            fi ;;
        esac ;;
      settings)
        if [ "${b:-}" = '' ] || [ "${c:-}" = '' ]; then :; else
          if [ "${c}" = null ]; then adb_do settings delete "$a" "$b"; else adb_do settings put "$a" "$b" "$c"; fi
        fi ;;
      app)
        case "${a}" in
          smarttube) adb_do pm uninstall "$SMARTTUBE_PKG"; ok 'SmartTube removed' ;;
          youtube)   adb_do pm enable --user 0 "$YT_PKG"; ok 'YouTube app re-enabled' ;;
        esac ;;
      dns)
        adb_do settings delete secure always_on_vpn_app
        adb_do pm uninstall "$DNSF_PKG" >/dev/null 2>&1 || true
        ok 'DNS filter removed' ;;
      launcher)
        case "$a" in
          projectivy)
            adb_do appops set "$PROJ_PKG" SYSTEM_ALERT_WINDOW default
            adb_do dumpsys deviceidle whitelist "-$PROJ_PKG"
            adb_do cmd package set-home-activity com.amazon.tv.launcher/.ui.HomeActivity_vNext ;;
          dumbtv)
            adb_do cmd package set-home-activity com.amazon.tv.launcher/.ui.HomeActivity_vNext ;;
        esac ;;
    esac
  done < <(reverse_lines < "$UNDO_LOG" 2>/dev/null)
}

clean_undo() {
  if ! ensure_adb; then bad 'Could not obtain adb. See the messages above.'; NEXT='exit'; return; fi
  if [ -z "${IP:-}" ]; then
    printf 'Stick IP address: '
    if ! read -r IP; then INPUT_EOF=1; NEXT='exit'; return; fi
  fi
  title "Undoing everything on $IP"
  timeout 20 "$ADB" connect "${IP}:5555" >/dev/null 2>&1 || true
  SDK_INT=$(adb_sh getprop ro.build.version.sdk | tr -dc '0-9'); SDK_INT="${SDK_INT:-0}"

  # Every run writes its own log, so undo replays all of them, newest first: a second run must not
  # lose the changes the first one made.
  local logs=() f
  while IFS= read -r f; do logs+=("$f"); done < <(ls -1t "${LOGDIR:-./logs}"/cleanup-*/undo.tsv 2>/dev/null)
  if [ "${#logs[@]}" -gt 0 ]; then
    for f in "${logs[@]}"; do
      [ -s "$f" ] || continue
      dim "Reading $f"
      UNDO_LOG="$f"
      clean_undo_packages
    done
  else
    warn 'No cleanup log found - only clearing the launcher hooks and DNS.'
  fi

  # launcher hooks and DNS: clear whether or not there was a log. Only our own service comes out -
  # wiping the whole list would also disable a screen reader someone might be using.
  a11y_remove "$PROJ_SVC"
  a11y_remove "$DUMBTV_SVC"
  adb_do cmd package set-home-activity com.amazon.tv.launcher/.ui.HomeActivity_vNext
  adb_do am start -n com.amazon.tv.launcher/.ui.HomeActivity_vNext
  adb_do settings delete secure always_on_vpn_app

  ok "Amazon home screen restored. Apps stay installed; anything disabled is enabled again."
  log_event 'UNDO' "cleanup undone from ${UNDO_LOG:-no log}"
  pause 'Press Enter to close...'
  NEXT='exit'
}
