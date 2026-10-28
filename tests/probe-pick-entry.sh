#!/usr/bin/env bash
# Scroll the on-screen list until an entry matching NAME appears, then tap it.
set -u
S="${SER:-192.168.1.100:5555}"
A="adb -s $S"
NAME="${1:?usage: pick-entry.sh <name>}"
MAX="${2:-12}"

tap_if_found() {
  $A shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1
  $A shell cat /sdcard/ui.xml > /tmp/ui.xml 2>/dev/null
  local line
  line=$(python3 - "$NAME" <<'PY'
import re, sys
needle = sys.argv[1].lower()
xml = open('/tmp/ui.xml', encoding='utf-8', errors='replace').read()
best = None
for m in re.finditer(r'<node[^>]*>', xml):
    node = m.group(0)
    t = re.search(r'text="([^"]*)"', node)
    b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', node)
    if not (t and b) or not t.group(1):
        continue
    if needle in t.group(1).lower():
        x1, y1, x2, y2 = map(int, b.groups())
        best = (t.group(1), (x1 + x2) // 2, (y1 + y2) // 2)
        break
if best:
    print(f"{best[1]} {best[2]} {best[0]}")
PY
)
  if [ -n "$line" ]; then
    echo "FOUND $line"
    set -- $line
    $A shell input tap "$1" "$2"
    return 0
  fi
  return 1
}

for i in $(seq 1 "$MAX"); do
  if tap_if_found; then exit 0; fi
  echo "  scroll $i: not visible yet"
  $A shell input swipe 960 900 960 300 300
  sleep 2
done
echo "NOT FOUND: $NAME"
exit 1
