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
        # Transitive install names use Homebrew opt links, which may move to a
        # newer keg independently of FFmpeg. Package from the reviewed SDK
        # directories and let the native-input hash lock verify every byte.
        export ILLIQUID_NATIVE_LIBRARY_PATH
        ILLIQUID_NATIVE_LIBRARY_PATH=$(python3 - "$repository_root/BuildInputs/native-sdk.json" <<'PY'
import json,sys
from pathlib import PurePosixPath
directories=[]
for name,value in json.load(open(sys.argv[1]))['kegs'].items():
    path=PurePosixPath(value)
    if len(path.parts)!=3 or path.parts[:2]!=('Cellar',name) or '..' in path.parts:
        raise SystemExit('Invalid pinned native prefix')
    directories.append('/opt/homebrew/'+str(path)+'/lib')
print(':'.join(directories))
PY
) || return 1
    fi
}

# Only the automatically selected SDK (or an explicit directory override) uses
# this lookup. An explicitly selected PKG_CONFIG_PATH keeps its existing behavior.
illiquid_pinned_native_library() {
    local dependency=$1 directory
    local directories=()
    IFS=: read -r -a directories <<< "${ILLIQUID_NATIVE_LIBRARY_PATH:-}"
    for directory in "${directories[@]:-}"; do
        [[ -n "$directory" && -f "$directory/${dependency##*/}" ]] || continue
        printf '%s\n' "$directory/${dependency##*/}"
        return 0
    done
    return 1
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
