#!/usr/bin/env bash
# Pull the unknown package and work out what it is.
set -u
SER="${SER:-192.168.1.101:5555}"
A="adb -s $SER"
PKG=com.xalahub.appstarter

apk=$($A shell pm path $PKG 2>/dev/null | head -1 | sed 's/package://' | tr -d '\r')
echo "== pulling $apk =="
$A pull "$apk" /tmp/xalahub.apk 2>&1 | tail -1

echo
echo "== manifest facts from dumpsys =="
$A shell dumpsys package $PKG 2>/dev/null | sed -n '/Receiver Resolver Table/,/^$/p' | head -14 | tr -d '\r' | sed 's/^/  /'
echo "  services:"
$A shell dumpsys package $PKG 2>/dev/null | sed -n '/Service Resolver Table/,/^$/p' | head -10 | tr -d '\r' | sed 's/^/  /'
echo "  install permissions granted:"
$A shell dumpsys package $PKG 2>/dev/null | sed -n '/install permissions:/,/runtime permissions:/p' | grep -E 'granted=true' | head -12 | tr -d '\r' | sed 's/^/    /'

echo
echo "== strings that look like network endpoints or vendors =="
python3 - <<'PY'
import re, zipfile
try:
    z = zipfile.ZipFile('/tmp/xalahub.apk')
except Exception as e:
    print("  cannot open the apk:", e); raise SystemExit
names = z.namelist()
print("  entries:", len(names), " libs:", [n for n in names if n.startswith('lib/')][:4])
blob = b''
for n in names:
    if n in ('AndroidManifest.xml', 'resources.arsc') or n.endswith('.dex'):
        try: blob += z.read(n)
        except Exception: pass
urls = sorted(set(re.findall(rb'https?://[A-Za-z0-9\.\-/_%]+', blob)))[:20]
print("  urls found:", len(urls))
for u in urls:
    print("   ", u.decode('utf-8', 'replace')[:110])
strs = sorted(set(re.findall(rb'[A-Za-z][A-Za-z0-9 _\.\-]{5,40}', blob)))
interesting = [s.decode('utf-8','replace') for s in strs if re.search(rb'(?i)starter|launch|xala|fire|tv|ads|proxy|vpn|update|install', s)][:25]
print("  words of interest:")
for s in interesting:
    print("   ", s)
PY
