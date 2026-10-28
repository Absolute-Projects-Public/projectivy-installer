#!/usr/bin/env bash
# SmartTube onto the Bravia using dumbtv's own youtube.sh, then deal with the TV's YouTube app.
set -u
SER="${SER:-192.168.1.100:5555}"
A="adb -s $SER"
ST=org.smarttube.stable
YT_TV=com.google.android.youtube.tv      # Android TV's YouTube; their script only knows the Fire package

echo "== their youtube.sh --force (installs SmartTube, checksum-verified, fixes the home order) =="
cd "$HOME/dumbtv" || exit 1
ADB_SERIAL="$SER" ./scripts/youtube.sh --force 2>&1 | tail -30

echo
echo "== what landed =="
$A shell dumpsys package "$ST" 2>/dev/null | grep -m1 versionName
echo "installed: $($A shell pm path $ST | head -1)"

echo
echo "== the TV's own YouTube =="
echo "before: $($A shell pm list packages -d | grep -c "package:$YT_TV") (1 = disabled)"
$A shell pm disable-user --user 0 "$YT_TV" 2>&1 | tail -1
$A shell pm list packages -d | grep -q "package:$YT_TV" \
  && echo "after: disabled (reversible with: adb shell pm enable $YT_TV)" \
  || echo "after: still enabled - could not disable it"

echo
echo "== does SmartTube launch? =="
$A shell monkey -p "$ST" -c android.intent.category.LEANBACK_LAUNCHER 1 2>&1 | tail -1
sleep 4
$A shell dumpsys window | grep -m1 mCurrentFocus
