#!/usr/bin/env bash
# Is the Sony on the network at all, and is anything about its ADB listening?
set -u
IP="${1:-192.168.1.100}"

echo "== ping =="
ping -c 2 -W 2 "$IP" 2>&1 | tail -3 | sed 's/^/  /'

echo
echo "== arp (is that address even in the table?) =="
ip neigh show "$IP" 2>/dev/null | sed 's/^/  /' || arp -n 2>/dev/null | grep "$IP" | sed 's/^/  /' || echo "  no entry"

echo
echo "== any ports open on it =="
for p in 80 443 5555 8001 8002 50001 1900 80; do
  if timeout 1 bash -c "echo > /dev/tcp/$IP/$p" 2>/dev/null; then echo "  $p OPEN"; fi
done
echo "  (nothing listed = no TCP listener answered)"

echo
echo "== anything else on the subnet listening on 5555 =="
for i in $(seq 1 254); do
  ( timeout 1 bash -c "echo > /dev/tcp/192.168.1.$i/5555" 2>/dev/null && echo "  192.168.1.$i" ) &
done > /tmp/s3.txt 2>/dev/null
wait
[ -s /tmp/s3.txt ] && sort -u /tmp/s3.txt || echo "  none"

echo
echo "== the firestick, for contrast =="
adb devices | tail -3 | sed 's/^/  /'
