#!/usr/bin/env bash
# Linux-only experimental dependency configuration, NOT production macOS FFmpeg.
set -euo pipefail
if [[ $# != 2 ]]; then
  echo "usage: $0 <full-illiquid-checkout> <new-build-directory>" >&2
  exit 2
fi
repo=$(cd "$1" && pwd)
work=$2
if [[ -e "$work" ]]; then echo "Refusing existing build directory: $work" >&2; exit 2; fi
mkdir -p "$work"
work=$(cd "$work" && pwd)
tar -xf "$repo/DependencySources/archives/ffmpeg-8.1.2.tar.xz" -C "$work"
cd "$work/ffmpeg-8.1.2"
./configure --prefix="$work/prefix" --disable-everything --disable-programs \
  --disable-doc --disable-network --disable-x86asm --disable-autodetect \
  --disable-avdevice --disable-avfilter --disable-swresample --disable-swscale \
  --enable-avformat --enable-avcodec --enable-avutil --enable-protocol=file \
  --enable-demuxer=mov,matroska,mpegts --enable-parser=h264,hevc,mpegvideo,aac \
  --enable-decoder=h264,hevc,mpeg2video,aac --enable-pthreads
make -j2
make install
printf 'FFmpeg probe prefix: %s\n' "$work/prefix"
