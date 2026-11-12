#!/usr/bin/env bash
# Find every device answering on 5555 right now and identify it.
set -u
A=adb

echo "== sweep 192.168.50.0/24 on 5555 =="
for i in $(seq 1 254); do
  ( timeout 1 bash -c "echo > /dev/tcp/192.168.50.$i/5555" 2>/dev/null && echo "192.168.50.$i" ) &
done > /tmp/scan2.txt 2>/dev/null
wait
sort -u /tmp/scan2.txt -o /tmp/scan2.sorted 2>/dev/null
echo "  responders: $(wc -l < /tmp/scan2.sorted)"
sed 's/^/    /' /tmp/scan2.sorted

echo
echo "== identify each =="
while read -r ip; do
  [ -n "$ip" ] || continue
  $A connect "$ip:5555" >/dev/null 2>&1
  sleep 1
  st=$($A devices | awk -v d="$ip:5555" '$1==d {print $2}')
  model=$($A -s "$ip:5555" shell getprop ro.product.model 2>/dev/null | tr -d '\r')
  maker=$($A -s "$ip:5555" shell getprop ro.product.manufacturer 2>/dev/null | tr -d '\r')
  rel=$($A -s "$ip:5555" shell getprop ro.build.version.release 2>/dev/null | tr -d '\r')
  echo "  $ip  state=${st:-unknown}  ${maker:-?} ${model:-?}  ${rel:+Android $rel}"
done < /tmp/scan2.sorted
