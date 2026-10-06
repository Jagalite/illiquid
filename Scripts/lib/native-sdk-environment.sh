#!/usr/bin/env bash

# Respect explicit toolchain selection. Otherwise prefer the reviewed FFmpeg
# variant when installed, without changing Homebrew opt links or global settings.
illiquid_select_native_sdk() {
    local repository_root=$1
    [[ -z "${PKG_CONFIG_PATH:-}" ]] || return 0
    local keg
    keg=$(python3 - "$repository_root/BuildInputs/native-sdk.json" <<'PY'
import json,sys
from pathlib import PurePosixPath
keg=PurePosixPath(json.load(open(sys.argv[1]))['kegs']['ffmpeg'])
if len(keg.parts)!=3 or keg.parts[:2]!=('Cellar','ffmpeg') or '..' in keg.parts:
    raise SystemExit('Invalid pinned FFmpeg prefix')
print('/opt/homebrew/'+str(keg))
PY
) || return 1
    if [[ -d "$keg/lib/pkgconfig" ]]; then
        export PKG_CONFIG_PATH="$keg/lib/pkgconfig"
        export PATH="$keg/bin:$PATH"
    fi
}

# Fail closed: a missing filter library or failed inspection cannot establish
# that the SDK is free of the removed OpenGL dependency.
illiquid_verify_ffmpeg_linkage() {
    local library_directory dependencies
    pkg-config --exists libavfilter || {
        printf 'FFmpeg deinterlacing filter libraries are required\n' >&2
        return 1
    }
    library_directory=$(pkg-config --variable=libdir libavfilter) || return 1
    [[ -n "$library_directory" ]] || {
        printf 'FFmpeg filter library directory is missing\n' >&2
        return 1
    }
    dependencies=$(otool -L "$library_directory/libavfilter.dylib") || {
        printf 'Could not inspect FFmpeg filter dependencies\n' >&2
        return 1
    }
    [[ -n "$dependencies" ]] || return 1
    case "$dependencies" in
        *OpenGL*)
            printf 'FFmpeg links OpenGL; use the pinned variant in BuildInputs/README.md\n' >&2
            return 1
            ;;
    esac
}
