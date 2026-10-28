#!/usr/bin/env bash
# Read the on-screen list Home on Fire shows and find an entry by name, with tap coordinates.
set -u
S="${SER:-192.168.50.252:5555}"
A="adb -s $S"
NEEDLE="${1:-dumbtv}"

$A shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1
$A shell cat /sdcard/ui.xml > /tmp/ui.xml 2>/dev/null
echo "nodes: $(grep -o '<node' /tmp/ui.xml | wc -l)"
python3 - "$NEEDLE" <<'PY'
import re, sys
needle = sys.argv[1].lower()
xml = open('/tmp/ui.xml', encoding='utf-8', errors='replace').read()
for m in re.finditer(r'<node[^>]*>', xml):
    node = m.group(0)
    t = re.search(r'text="([^"]*)"', node)
    b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', node)
    if not (t and b) or not t.group(1):
        continue
    if needle in t.group(1).lower():
        x1, y1, x2, y2 = map(int, b.groups())
        print(f"FOUND  {t.group(1)!r}  centre=({(x1+x2)//2},{(y1+y2)//2})  bounds={b.group(0)}")
PY
