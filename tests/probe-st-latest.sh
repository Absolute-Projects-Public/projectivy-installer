#!/usr/bin/env bash
# What are the newest SmartTube builds, and which are stable vs beta?
set -u
curl -sS "https://api.github.com/repos/yuliskov/SmartTube/releases?per_page=6" -o /tmp/st-rel2.json 2>/dev/null
python3 - <<'PY'
import json
data = json.load(open('/tmp/st-rel2.json'))
for r in data:
    tag = r.get('tag_name'); name = r.get('name'); date = (r.get('published_at') or '')[:10]
    print(f"== {tag}  ({name})  {date}  prerelease={r.get('prerelease')}")
    body = (r.get('body') or '').strip().replace('\r','')
    print('   ' + body[:400].replace('\n', '\n   '))
    for a in r.get('assets', []):
        if 'v7a' in a['name'] or 'universal' in a['name']:
            d = a.get('digest') or 'no digest'
            print(f"   APK {a['name']}  {a['size']} bytes  {d}")
    print()
PY
