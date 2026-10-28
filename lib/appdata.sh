#!/usr/bin/env bash
# lib/appdata.sh - put files into an app's own folder on Android 11+, where adb may not write
# /sdcard/Android/data/<pkg>.
#
# An `adb restore` archive can carry them in: Android clears the app's data and unpacks the files
# as the app itself, after a confirmation dialog on the TV. That dialog is answered here by finding
# the button with uiautomator and tapping it, with key events as a fallback.
#
# Adapted from the dumbtv project (github.com/humblemuzzu/dumbtv, MIT). Their script is the reason
# this works at all on Fire OS 8; the retry and verification logic is theirs, the wiring is ours.
#
# Callers must have: ADB, SDK_INT, adb_sh, adb_do, log_event, ok/warn/dim.

# appdata_archive OUT PKG VERSION_CODE SDK SIGNER_HEX SRC SUBDIR
#   SIGNER_HEX is the app's signing certificate in hex DER; Android refuses a restore otherwise.
appdata_archive() {
  local out="$1" pkg="$2" code="$3" sdk="$4" signer="$5" src="$6" sub="$7"
  local stage; stage="$(dirname "$out")/appdata-stage"
  rm -rf "$stage"; mkdir -p "$stage/apps/$pkg/ef"
  cp -R "$src" "$stage/apps/$pkg/ef/$sub" || return 1
  # Format version, package, versionCode, platform sdk, installer, has-APK, signatures.
  printf '1\n%s\n%s\n%s\n\n0\n1\n%s\n' "$pkg" "$code" "$sdk" "$signer" > "$stage/apps/$pkg/_manifest"
  # Android's reader understands plain ustar only, and wants the manifest first.
  ( cd "$stage" && COPYFILE_DISABLE=1 tar --format=ustar -cf body.tar "apps/$pkg/_manifest" "apps/$pkg/ef/$sub" ) || return 1
  { printf 'ANDROID BACKUP\n5\n0\nnone\n'; cat "$stage/body.tar"; } > "$out"
  rm -rf "$stage"
  [ -s "$out" ]
}

# ---- reading the TV's screen ----------------------------------------------

appdata_confirmation_shown() {
  local focus
  focus=$(adb_sh dumpsys window | grep 'mCurrentFocus=')
  case "$focus" in *BackupRestoreConfirmation*) return 0 ;; *) return 1 ;; esac
}

appdata_tap_allow() {
  local ui re='resource-id="com\.android\.backupconfirm:id/button_allow"[^>]*bounds="\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]"'
  ui=$(adb_sh sh -c 'uiautomator dump /sdcard/dumbtv-ui.xml >/dev/null 2>&1; cat /sdcard/dumbtv-ui.xml; rm -f /sdcard/dumbtv-ui.xml')
  [[ $ui =~ $re ]] || return 1
  adb_do input tap $(( (BASH_REMATCH[1] + BASH_REMATCH[3]) / 2 )) $(( (BASH_REMATCH[2] + BASH_REMATCH[4]) / 2 ))
}

appdata_allow_focused() {
  local top
  top=$(adb_sh dumpsys activity top | grep 'app:id/button_allow')
  [[ $top =~ \ [A-Z.]{9}\ .F ]]
}

appdata_restore_count() {
  adb_sh logcat -d -s BackupManagerService 2>/dev/null | grep -cE "$1"
}

# restore_app_data ARCHIVE -> 0 when Android reports the restore actually completed
restore_app_data() {
  local ab="$1" pid i done0 took0 fail0 asked=0
  local IPSEL=''
  [ -n "${IP:-}" ] && IPSEL="-s ${IP}:5555"
  done0=$(appdata_restore_count 'adb restore processing complete')
  took0=$(appdata_restore_count 'taking data')
  fail0=$(appdata_restore_count 'ErrnoException|timed out waiting for user confirmation')

  # A dialog left over from an earlier, timed-out request would take the taps meant for this one.
  adb_do am force-stop com.android.backupconfirm
  "$ADB" ${IPSEL:+$IPSEL} restore "$ab" >/dev/null 2>&1 </dev/null &
  pid=$!

  for i in $(seq 1 40); do
    appdata_confirmation_shown && break
    kill -0 "$pid" 2>/dev/null || { warn 'The restore ended before the TV showed its confirmation.'; return 1; }
    sleep 0.5
  done

  for i in 1 2 3 4 5; do
    sleep 1.5
    appdata_tap_allow && sleep 2
    appdata_confirmation_shown || break
  done

  if appdata_confirmation_shown; then
    for i in 1 2 3 4; do
      appdata_allow_focused && break
      adb_do input keyevent KEYCODE_TAB
      sleep 0.7
    done
    appdata_allow_focused && adb_do input keyevent KEYCODE_DPAD_CENTER
    sleep 2
  fi
  if appdata_confirmation_shown; then
    asked=1
    dim 'On the TV: choose RESTORE MY DATA (it times out after a minute).'
  fi

  for i in $(seq 1 90); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
  kill "$pid" 2>/dev/null || true
  # The TV can still be unpacking after adb has finished sending.
  for i in $(seq 1 30); do
    [ "$(appdata_restore_count 'adb restore processing complete')" -gt "$done0" ] && break
    sleep 1
  done

  [ "$(appdata_restore_count 'adb restore processing complete')" -gt "$done0" ] || { warn 'Android did not report the restore as complete.'; return 1; }
  [ "$(appdata_restore_count 'taking data')" -gt "$took0" ] || { warn 'Android did not start taking the data.'; return 1; }
  [ "$(appdata_restore_count 'ErrnoException|timed out waiting for user confirmation')" -eq "$fail0" ] || { warn 'Android reported an error during the restore.'; return 1; }
  [ "$asked" = 1 ] && ok 'Restore confirmed on the TV.'
  return 0
}
