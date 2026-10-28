#!/usr/bin/env bash
# Work out what the AFTVnews Downloader code 326373 actually points at, without installing anything.
set -u
code="${1:-326373}"
page="/tmp/aftv-$code.html"
curl -sSL "https://aftv.news/$code" -o "$page" || exit 1
echo "== page title =="
grep -oiE '<title>[^<]*' "$page" | head -1

echo "== links on the redirect page =="
python3 - "$page" <<'PY'
import re, sys, html
data = open(sys.argv[1], encoding='utf-8', errors='replace').read()
# the shortener shows the destination and usually a direct link
for m in re.finditer(r'href="([^"]+)"', data):
    u = html.unescape(m.group(1))
    if any(k in u.lower() for k in ('.apk', 'github.com', 'drive.google', 'dropbox', 'mediafire', 'firetv', 'launch')):
        print(" ", u)
for m in re.finditer(r'https?://[^\s"\'<>]+\.apk', data):
    print(" APK:", m.group(0))
PY

echo "== does it reach an APK? =="
grep -oiE 'https?://[^"'"'"' <>]+\.apk' "$page" | head -3
echo "(nothing above means the page is a landing page, not a direct APK)"
