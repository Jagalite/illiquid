#!/usr/bin/env bash
# Small deterministic, local-only fixtures for product/native regressions.
set -euo pipefail
out=${1:?Usage: generate-product-fixtures.sh OUTPUT_DIRECTORY}
mkdir -p "$out"
cat > "$out/captions.srt" <<'SRT'
1
00:00:01,000 --> 00:00:03,000
Hello, 世界.

2
00:00:04,500 --> 00:00:05,750
Next sentence.
SRT
ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'testsrc2=size=96x64:rate=30' \
  -i "$out/captions.srt" -t 6 -map 0:v -map 1:s -c:v libx264 -preset ultrafast \
  -g 60 -pix_fmt yuv420p -c:s srt "$out/captions.mkv"
ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'testsrc2=size=320x180:rate=30' \
  -f lavfi -i 'sine=frequency=440:sample_rate=48000' -t 8 \
  -c:v libx264 -preset ultrafast -g 60 -pix_fmt yuv420p -c:a aac "$out/h264-aac.mp4"
