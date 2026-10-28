#!/usr/bin/env bash
# Print every visible control (text + tap coordinates) on the current screen.
set -u
S="${SER:-192.168.50.252:5555}"
A="adb -s $S"
$A shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1
$A shell cat /sdcard/ui.xml > /tmp/ui.xml 2>/dev/null
python3 - <<'PY'
import re
xml = open('/tmp/ui.xml', encoding='utf-8', errors='replace').read()
for m in re.finditer(r'<node[^>]*>', xml):
    node = m.group(0)
    t = re.search(r'text="([^"]*)"', node)
    c = re.search(r'class="([^"]*)"', node)
    b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', node)
    if not b:
        continue
    x1, y1, x2, y2 = map(int, b.groups())
    label = (t.group(1) if t else '') or ''
    cls = (c.group(1) if c else '').split('.')[-1]
    if not label and cls in ('View', 'FrameLayout', 'RelativeLayout', 'LinearLayout'):
        continue
    print(f"  {cls:16} {label[:44]:46} tap=({(x1+x2)//2},{(y1+y2)//2})")
PY
