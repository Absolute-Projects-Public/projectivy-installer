#!/usr/bin/env bash
# Firestick part 2: what the OS thinks storage is, what is running, and who is listening.
set -u
SER="${SER:-192.168.1.101:5555}"
A="adb -s $SER"

echo "== the OS's own low-space view (this is what Fire OS reports) =="
$A shell dumpsys devicestoragemonitor 2>/dev/null | tr -d '\r' | head -20 | sed 's/^/  /'
echo "  storage volumes:"
$A shell sm list-volumes all 2>/dev/null | tr -d '\r' | sed 's/^/    /'
echo "  thresholds:"
for k in sys_storage_threshold_max_bytes sys_storage_threshold_percentage sys_storage_full_threshold_bytes; do
  printf '    %-38s %s\n' "$k" "$($A shell settings get global $k 2>/dev/null | tr -d '\r')"
done

echo
echo "== where /data actually goes =="
$A shell "du -sm /data/app /data/data /data/dalvik-cache /data/misc /data/system 2>/dev/null | sort -rn" | tr -d '\r' | sed 's/^/  /'
echo "  -- caches the OS will happily drop --"
$A shell "du -sm /data/data/*/cache 2>/dev/null | sort -rn | head -8" | tr -d '\r' | sed 's/^/  /'

echo
echo "== top processes by memory =="
$A shell "ps -A -o PID,VSZ,RSS,NAME 2>/dev/null | sort -k3 -rn | head -16" | tr -d '\r' | sed 's/^/  /'

echo
echo "== listening sockets =="
for f in /proc/net/tcp /proc/net/tcp6 /proc/net/udp /proc/net/udp6; do
  $A shell "cat $f 2>/dev/null | tail -n +2"
done > /tmp/socks.txt 2>/dev/null
python3 - <<'PY'
def hexport(x):
    return int(x.split(':')[1], 16)
seen = set()
for line in open('/tmp/socks.txt'):
    p = line.split()
    if len(p) < 4:
        continue
    state = p[3]
    if state == '0A':                      # LISTEN only
        local = p[1]
        port = hexport(local)
        if port not in seen:
            seen.add(port)
            print(f"  listening on port {port}")
print("  (none)" if not seen else "")
PY

echo
echo "== vpn / proxy / filter apps installed and running =="
echo "  packages: $($A shell pm list packages 2>/dev/null | grep -iE 'dnsfilter|vpn|proxy|personal|xalahub' | sed 's/package://' | tr -d '\r' | tr '\n' ' ')"
echo "  running:  $($A shell ps -A 2>/dev/null | grep -iE 'dnsfilter|vpn|proxy|xalahub' | awk '{print $9}' | tr '\n' ' ')"
echo "  vpn in connectivity: $($A shell dumpsys connectivity 2>/dev/null | grep -ciE 'vpn')"
$A shell dumpsys connectivity 2>/dev/null | grep -m3 -iE 'vpn|proxy' | tr -d '\r' | sed 's/^/    /'
echo "  device-wide http proxy: $($A shell settings get global http_proxy 2>/dev/null | tr -d '\r')"
echo "  wifi proxy: $($A shell dumpsys wifi 2>/dev/null | grep -m2 -i proxy | tr -d '\r' | tr '\n' ' ')"

echo
echo "== accessibility services (what is hooked into input) =="
$A shell settings get secure enabled_accessibility_services | tr -d '\r' | sed 's/^/  /'
