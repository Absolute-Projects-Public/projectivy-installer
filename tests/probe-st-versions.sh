#!/usr/bin/env bash
# Confirm the Firestick's SmartTube build, and get the release dates around it.
set -u
SER="${SER:-192.168.1.101:5555}"
A="adb -s $SER"

echo "== firestick SmartTube now =="
$A shell dumpsys package org.smarttube.stable 2>/dev/null | grep -m1 versionName | tr -d '\r' | tr -s ' '
$A shell dumpsys package org.smarttube.stable 2>/dev/null | grep -m1 versionCode | tr -d '\r' | tr -s ' '

echo
echo "== SmartTube release timeline (is the #5550 fix already in 32.56?) =="
curl -sS "https://api.github.com/repos/yuliskov/SmartTube/releases?per_page=100" -o /tmp/st-releases.json 2>/dev/null
python3 - <<'PY'
import json
try:
    data = json.load(open('/tmp/st-releases.json'))
except Exception as e:
    print("  could not read the release list:", e); raise SystemExit
rows = [(r.get('tag_name'), (r.get('published_at') or '')[:10], (r.get('body') or '')[:70].replace('\n',' ')) for r in data]
for tag, date, body in rows[:14]:
    print(f"  {tag:12} {date}  {body}")
tags = [t for t, _, _ in rows]
dates = {t: d for t, d, _ in rows}
for want in ('32.71s', '32.68s', '32.56s', '31.08s'):
    print(f"  {want:8} -> {dates.get(want, 'not in the last 100 releases')}")
PY
