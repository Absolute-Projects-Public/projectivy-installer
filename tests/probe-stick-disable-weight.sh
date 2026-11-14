#!/usr/bin/env bash
# Disable the safe background weight on the stick, verifying the device still works after each one.
# Read-only for anything ambiguous: firebat and livetv are only INSPECTED here.
set -u
SER="${SER:-192.168.1.101:5555}"
A="adb -s $SER"
LOG=/tmp/stick-disabled-$(date +%Y%m%d-%H%M%S).tsv

mem() { $A shell "grep -E 'MemAvailable|SwapFree' /proc/meminfo" | tr -d '\r' | tr -s ' ' | tr '\n' ' '; }
front() { $A shell dumpsys window 2>/dev/null | grep -m1 mCurrentFocus | sed 's/.*u0 //;s/}.*//'; }
smarttube_ok() {
  $A shell monkey -p org.smarttube.stable -c android.intent.category.LEANBACK_LAUNCHER 1 >/dev/null 2>&1
  sleep 5
  case "$(front)" in *smarttube*) return 0 ;; *) return 1 ;; esac
}
home_ok() {
  $A shell input keyevent KEYCODE_HOME >/dev/null 2>&1
  sleep 5
  case "$(front)" in *tv.dumbtv.home*) return 0 ;; *) return 1 ;; esac
}

echo "== who are the two on our never-disable list? (inspecting, not touching) =="
for p in com.amazon.firebat com.amazon.tv.livetv; do
  echo "  $p"
  echo "    activities: $($A shell "dumpsys package $p 2>/dev/null | sed -n '/Activity Resolver Table/,/^$/p' | grep -cE '^\s+[0-9a-f]{6,}'" | tr -d '\r')"
  echo "    video-looking components:"
  $A shell "dumpsys package $p 2>/dev/null | grep -oiE '[a-z0-9_.]*(prime|video|player|watch|livetv|tuner|input|tvinput)[a-z0-9_.]*' | sort -u | head -8" | tr -d '\r' | sed 's/^/      /'
done

echo
echo "before: $(mem)"

disable_one() {
  p="$1"
  echo "== disabling $p =="
  out=$($A shell "pm disable-user --user 0 $p" 2>&1 | tr -d '\r' | head -1)
  echo "  $out"
  state=$($A shell pm list packages -d 2>/dev/null | grep -c "package:$p" | tr -d '\r')
  if [ "$state" != "1" ]; then
    echo "  NOT disabled (state=$state) - leaving it alone"
    return 1
  fi
  echo "  state: disabled"
  printf '%s\tdisable-user\t%s\n' "$p" "$out" >> "$LOG"
  sleep 3
  echo "  memory now: $(mem)"
  if smarttube_ok; then echo "  verify: SmartTube still launches"; else
    echo "  verify FAILED: SmartTube did not come up - re-enabling $p"
    $A shell "pm enable --user 0 $p" >/dev/null 2>&1; return 1
  fi
  if home_ok; then echo "  verify: HOME still lands on dumbtv home"; else
    echo "  verify FAILED: HOME did not come back - re-enabling $p"
    $A shell "pm enable --user 0 $p" >/dev/null 2>&1; return 1
  fi
}

disable_one com.amazon.diode
echo
disable_one com.amazon.whisperjoin.middleware.v2.np

echo
echo "== after everything =="
echo "  $(mem)"
echo "  top 12 by ram:"
$A shell "ps -A -o RSS,NAME 2>/dev/null | sort -rn | head -12" | tr -d '\r' | sed 's/^/    /'
echo
echo "  undo log: $LOG"
