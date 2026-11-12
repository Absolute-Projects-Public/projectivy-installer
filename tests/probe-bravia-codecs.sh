#!/usr/bin/env bash
# What codecs can this TV decode in hardware, and what is SmartTube doing right now.
set -u
SER="${SER:-192.168.1.100:5555}"
A="adb -s $SER"

adb connect "$SER" >/dev/null 2>&1
sleep 2
echo "== devices =="
adb devices | sed -n '2,6p'

echo
echo "== hardware decoders declared by the set =="
for f in /vendor/etc/media_codecs*.xml /system/etc/media_codecs*.xml \
         /vendor/etc/media_codecs_performance*.xml; do
  $A shell "cat $f 2>/dev/null"
done > /tmp/codecs.xml 2>/dev/null
echo "  bytes read: $(wc -c < /tmp/codecs.xml)"
for c in av01 vp9 vp8 hevc avc mpeg4; do
  n=$(grep -oE "name=\"[^\"]*${c}[^\"]*\"" /tmp/codecs.xml 2>/dev/null | sort -u | wc -l)
  printf '  %-6s decoder entries: %s\n' "$c" "$n"
done
echo "  names:"
grep -oE 'name="[^"]*"' /tmp/codecs.xml 2>/dev/null | sort -u | head -18 | sed 's/^/    /'

echo
echo "== SmartTube =="
$A shell dumpsys package org.smarttube.stable 2>/dev/null | grep -m1 versionName
echo "  running: $($A shell ps -A 2>/dev/null | grep -c smarttube)"

echo
echo "== on screen now =="
$A shell dumpsys window 2>/dev/null | grep -m1 mCurrentFocus

echo
echo "== any codec errors in the last while =="
$A shell logcat -d -t 400 2>/dev/null | grep -iE 'MediaCodec|av01|vp9|omx|c2\.|decoder' | tail -8
