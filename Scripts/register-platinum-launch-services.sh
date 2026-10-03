#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: register-platinum-launch-services.sh APP_PATH [VIDEO_PATH]

Register one installed Illiquid.app with Launch Services without resetting the
global database. When a video is supplied, open it with that exact app copy.
USAGE
}

[[ $# -ge 1 && $# -le 2 ]] || { usage >&2; exit 1; }
app_bundle=$1
video=${2:-}
[[ -d "$app_bundle" ]] || { printf 'error: app not found: %s\n' "$app_bundle" >&2; exit 1; }
info_plist="$app_bundle/Contents/Info.plist"
plist=/usr/libexec/PlistBuddy
[[ "$("$plist" -c 'Print :CFBundleName' "$info_plist")" = Illiquid ]]
[[ "$("$plist" -c 'Print :CFBundleExecutable' "$info_plist")" = Illiquid ]]
"$plist" -c 'Print :CFBundleIdentifier' "$info_plist"
"$plist" -c 'Print :CFBundleDocumentTypes:0:LSItemContentTypes' "$info_plist" >/dev/null

lsregister=$(
    find /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework \
        -name lsregister -type f -print -quit
)
[[ -x "$lsregister" ]] || { printf 'error: lsregister was not found\n' >&2; exit 1; }
"$lsregister" -f "$app_bundle"
printf 'Registered with Launch Services: %s\n' "$app_bundle"

if [[ -n "$video" ]]; then
    [[ -f "$video" ]] || { printf 'error: video not found: %s\n' "$video" >&2; exit 1; }
    open -a "$app_bundle" "$video"
    printf 'Opened with Illiquid: %s\n' "$video"
fi
