#!/usr/bin/env bash
# Rebuild the pinned FFmpeg source without the legacy CoreImage/OpenGL filters.
# Uses a separate prefix; never relinks or replaces the host Homebrew installation.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
prefix=${1:?Usage: build-native-ffmpeg.sh ABSOLUTE_NEW_PREFIX [BUILD_DIRECTORY]}
[[ "$prefix" = /* && ! -e "$prefix" ]] || { echo 'Require a new absolute install prefix' >&2; exit 1; }
build=${2:-$(mktemp -d /tmp/illiquid-ffmpeg.XXXXXX)}
mkdir -p "$build"
archive="$root/DependencySources/archives/ffmpeg-8.1.2.tar.xz"
[[ "$(shasum -a 256 "$archive" | cut -d' ' -f1)" = 464beb5e7bf0c311e68b45ae2f04e9cc2af88851abb4082231742a74d97b524c ]] \
    || { echo 'FFmpeg source checksum mismatch' >&2; exit 1; }
[[ ! -e "$build/ffmpeg-8.1.2" ]] || { echo 'Build directory already contains FFmpeg' >&2; exit 1; }
tar -xf "$archive" -C "$build"
cd "$build/ffmpeg-8.1.2"
export MACOSX_DEPLOYMENT_TARGET=26.0
# Match the reviewed dependency set instead of auto-discovering unrelated host
# packages (for example X11) that Homebrew normally hides during formula builds.
export PKG_CONFIG_LIBDIR
PKG_CONFIG_LIBDIR=$(python3 - "$root" <<'PY_CONFIG'
import json,sys
from pathlib import Path
root=Path(sys.argv[1]); manifest=json.loads((root/'BuildInputs/native-sdk.json').read_text())
paths=[str(root/'BuildInputs/system-pkgconfig'),'/opt/homebrew/opt/sdl2/lib/pkgconfig']
for keg in manifest['kegs'].values():
    for suffix in ['lib/pkgconfig','share/pkgconfig']:
        path=Path('/opt/homebrew')/keg/suffix
        if path.is_dir(): paths.append(str(path))
print(':'.join(paths))
PY_CONFIG
)
export PKG_CONFIG_PATH="$PKG_CONFIG_LIBDIR"
./configure --prefix="$prefix" --enable-shared --enable-pthreads --enable-version3 \
    --cc=clang --host-cflags= --host-ldflags= --enable-ffplay --enable-gpl \
    --enable-libsvtav1 --enable-libopus --enable-libx264 --enable-libmp3lame \
    --enable-libdav1d --enable-libvmaf --enable-libvpx --enable-libx265 \
    --enable-openssl --enable-videotoolbox --enable-audiotoolbox --enable-neon \
    --disable-coreimage --extra-cflags=-I/opt/homebrew/opt/lame/include \
    --extra-ldflags=-L/opt/homebrew/opt/lame/lib
make -j "${ILLIQUID_NATIVE_BUILD_JOBS:-4}"
make install
# The removed filters are unused by Illiquid; bwdif deinterlacing must remain.
"$prefix/bin/ffmpeg" -hide_banner -filters > "$build/filters.txt" 2>&1
rg -q ' bwdif ' "$build/filters.txt"
if otool -L "$prefix/lib/libavfilter.dylib" | rg -q 'OpenGL'; then
    echo 'Unexpected OpenGL link remains' >&2; exit 1
fi
printf 'Built FFmpeg in %s; qualify it and refresh native provenance before release.\n' "$prefix"
