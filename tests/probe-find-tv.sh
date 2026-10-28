#!/usr/bin/env bash
# Find Android TVs advertising ADB on the local network and say what each one is.
set -u
A=adb

echo "== network interfaces =="
ip -4 -o addr show scope global 2>/dev/null | awk '{print "  " $2, $4}' || true

echo "== are there replies on 5555? =="
found=""
for base in $(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' \
              | grep -vE '^(10\.2\.|172\.1[6-9]\.|172\.2[0-9]\.|172\.3[01]\.)' \
              | while read -r c; do echo "${c%.*}" | cut -d/ -f1; done | sort -u); do
  for i in $(seq 1 254); do
    ( timeout 1 bash -c "echo > /dev/tcp/$base.$i/5555" 2>/dev/null && echo "$base.$i" ) &
  done
done > /tmp/scan.txt 2>/dev/null
wait
sort -u /tmp/scan.txt > /tmp/scan.sorted 2>/dev/null
echo "  $(wc -l < /tmp/scan.sorted) responder(s)"
cat /tmp/scan.sorted | sed 's/^/    /'

echo "== what is each one? =="
while read -r ip; do
  [ -n "$ip" ] || continue
  "$A" connect "$ip:5555" >/dev/null 2>&1
  sleep 1
  model=$("$A" -s "$ip:5555" shell getprop ro.product.model 2>/dev/null | tr -d '\r')
  maker=$("$A" -s "$ip:5555" shell getprop ro.product.manufacturer 2>/dev/null | tr -d '\r')
  rel=$("$A" -s "$ip:5555" shell getprop ro.build.version.release 2>/dev/null | tr -d '\r')
  sdk=$("$A" -s "$ip:5555" shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r')
  fireos=$("$A" -s "$ip:5555" shell getprop ro.build.version.name 2>/dev/null | tr -d '\r')
  [ -n "$model$maker" ] || { echo "  $ip  (connected but no answer - needs the on-screen Allow)"; continue; }
  echo "  $ip  $maker $model  Android $rel (SDK $sdk)  ${fireos:+Fire OS: $fireos}"
done < /tmp/scan.sorted
