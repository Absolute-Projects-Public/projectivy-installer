#!/usr/bin/env bash
# Reconnect to the TVs and say plainly what each half is doing.
set -u
echo "== port 5555 reachable? =="
for ip in 192.168.1.100 192.168.1.101; do
  if timeout 2 bash -c "echo > /dev/tcp/$ip/5555" 2>/dev/null; then echo "  $ip  OPEN"; else echo "  $ip  no answer"; fi
done

echo
echo "== adb connect =="
for ip in 192.168.1.100 192.168.1.101; do
  printf '  %s: ' "$ip"
  adb connect "$ip:5555" 2>&1 | tail -1
done
sleep 2
echo
echo "== adb devices =="
adb devices -l | tail -5

echo
echo "== the Bravia, if it is there =="
adb -s 192.168.1.100:5555 shell getprop ro.product.model 2>&1 | tail -1
