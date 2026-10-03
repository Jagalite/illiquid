#!/bin/zsh
set -euo pipefail

# Opt-in performance fixtures, separate from the ordinary regression inventory.
fixture_dir="${1:-${PWD}/TestFixtures/SeekPerformance}"
mkdir -p "$fixture_dir"
ffmpeg_bin="${FFMPEG_BIN:-$(command -v ffmpeg)}"
[[ -n "$ffmpeg_bin" ]] || { print -u2 'ffmpeg is required'; exit 1; }

# 40 seconds, ten-second closed GOPs, bounded encoder parallelism. Retain
# existing fixtures between runs; this script never rewrites user media.
if [[ ! -f "$fixture_dir/h264-1080p-gop10.mp4" ]]; then
    "$ffmpeg_bin" -hide_banner -loglevel error -n \
        -f lavfi -i 'testsrc2=size=1920x1080:rate=30' \
        -f lavfi -i 'sine=frequency=440:sample_rate=48000' -t 40 \
        -c:v libx264 -preset veryfast -threads 4 -crf 28 \
        -g 300 -keyint_min 300 -sc_threshold 0 -pix_fmt yuv420p \
        -c:a aac -b:a 96k "$fixture_dir/h264-1080p-gop10.mp4"
fi
if [[ ! -f "$fixture_dir/hevc-1080p10-gop10.mkv" ]]; then
    "$ffmpeg_bin" -hide_banner -loglevel error -n \
        -f lavfi -i 'testsrc2=size=1920x1080:rate=30' \
        -f lavfi -i 'sine=frequency=440:sample_rate=48000' -t 40 \
        -c:v libx265 -preset ultrafast -crf 30 -pix_fmt yuv420p10le \
        -x265-params 'log-level=error:pools=4:frame-threads=2:keyint=300:min-keyint=300:scenecut=0:open-gop=0' \
        -c:a aac -b:a 96k "$fixture_dir/hevc-1080p10-gop10.mkv"
fi
if [[ ! -f "$fixture_dir/h264-4k-gop10.mp4" ]]; then
    "$ffmpeg_bin" -hide_banner -loglevel error -n \
        -f lavfi -i 'testsrc2=size=3840x2160:rate=30' -t 20 \
        -c:v libx264 -preset veryfast -threads 4 -crf 30 \
        -g 300 -keyint_min 300 -sc_threshold 0 -pix_fmt yuv420p -an \
        "$fixture_dir/h264-4k-gop10.mp4"
fi
print "Seek fixtures: $fixture_dir"
