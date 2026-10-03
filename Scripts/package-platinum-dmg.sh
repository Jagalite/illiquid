#!/usr/bin/env bash

set -euo pipefail

script_directory=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -P "$script_directory/.." && pwd)
# shellcheck source=Scripts/lib/platinum-packaging.sh
source "$script_directory/lib/platinum-packaging.sh"

usage() {
    cat <<'USAGE'
Usage: package-platinum-dmg.sh [--app PATH] [--output DIR]

Create, mount, verify, copy, and launch-test a compressed read-only Illiquid DMG,
then write its SHA-256 checksum.
USAGE
}

app_bundle="$repository_root/dist/Illiquid.app"
output_directory="$repository_root/dist"
while (($# > 0)); do
    case "$1" in
        --app)
            (($# >= 2)) || platinum_fail '--app requires a path'
            app_bundle=$2
            shift 2
            ;;
        --output)
            (($# >= 2)) || platinum_fail '--output requires a directory'
            output_directory=$2
            shift 2
            ;;
        -h|--help) usage; exit 0 ;;
        --*) platinum_fail "unknown option: $1" ;;
        *) platinum_fail "unexpected argument: $1" ;;
    esac
done
[[ -d "$app_bundle" ]] || platinum_fail "application not found: $app_bundle"

plist=/usr/libexec/PlistBuddy
info_plist="$app_bundle/Contents/Info.plist"
version=$("$plist" -c 'Print :CFBundleShortVersionString' "$info_plist")
signing_mode=$("$plist" -c 'Print :PlatinumSigningMode' "$info_plist")
architectures=$(lipo -archs "$app_bundle/Contents/MacOS/Illiquid")
audit_arguments=(--archs "$architectures")
[[ "$signing_mode" = unsigned ]] || audit_arguments+=(--require-signature)
"$script_directory/audit-platinum-app.sh" "${audit_arguments[@]}" "$app_bundle"

work_directory=$(mktemp -d "${TMPDIR:-/tmp}/platinum-dmg.XXXXXX")
mount_point=
cleanup() {
    if [[ -n "$mount_point" && -d "$mount_point" ]]; then
        hdiutil detach "$mount_point" -quiet 2>/dev/null || true
    fi
    [[ ! -d "$work_directory" ]] || rm -rf -- "$work_directory"
}
trap cleanup EXIT

staging_directory="$work_directory/staging"
platinum_stage_dmg "$app_bundle" "$staging_directory" \
    || platinum_fail 'failed to stage DMG contents'
[[ -L "$staging_directory/Applications" ]] \
    || platinum_fail 'Applications symlink is missing from staging'
[[ "$(readlink "$staging_directory/Applications")" = /Applications ]] \
    || platinum_fail 'Applications symlink has the wrong destination'

mkdir -p "$output_directory"
output_directory=$(cd -P "$output_directory" && pwd)
dmg_name="Illiquid-$version-macOS.dmg"
dmg_path="$output_directory/$dmg_name"
checksum_path="$dmg_path.sha256"
rm -f -- "$dmg_path" "$checksum_path"
hdiutil create \
    -volname Illiquid \
    -srcfolder "$staging_directory" \
    -format UDZO \
    -ov \
    "$dmg_path" >/dev/null

attach_plist="$work_directory/attach.plist"
hdiutil attach -nobrowse -readonly -plist "$dmg_path" >"$attach_plist"
mount_point=$(
    "$plist" -c 'Print :system-entities' "$attach_plist" \
        | sed -n 's/^[[:space:]]*mount-point = //p' | tail -1
)
[[ -n "$mount_point" && -d "$mount_point" ]] || platinum_fail 'DMG did not mount'
[[ -d "$mount_point/Illiquid.app" ]] || platinum_fail 'mounted DMG lacks Illiquid.app'
[[ -L "$mount_point/Applications" ]] || platinum_fail 'mounted DMG lacks Applications symlink'

install_root="$work_directory/Applications"
mkdir -p "$install_root"
ditto "$mount_point/Illiquid.app" "$install_root/Illiquid.app"
hdiutil detach "$mount_point" -quiet
mount_point=
"$script_directory/audit-platinum-app.sh" "${audit_arguments[@]}" \
    "$install_root/Illiquid.app"

smoke_profile="$work_directory/profile"
smoke_video=${PLATINUM_SMOKE_VIDEO:-}
if [[ -z "$smoke_video" && -x "$(command -v ffmpeg || true)" ]]; then
    smoke_video="$work_directory/Illiquid-Smoke.mp4"
    ffmpeg -hide_banner -loglevel error -y \
        -f lavfi -i 'color=c=0x8390a4:s=640x360:r=24' \
        -f lavfi -i 'sine=frequency=440:sample_rate=48000' \
        -t 4 -c:v libx264 -pix_fmt yuv420p -c:a aac "$smoke_video"
fi
if [[ -n "$smoke_video" ]]; then
    [[ -f "$smoke_video" ]] || platinum_fail "smoke video not found: $smoke_video"
    platinum_launch_smoke "$install_root/Illiquid.app" "$smoke_profile" "$smoke_video" \
        || platinum_fail 'installed application media-open smoke test failed'
else
    platinum_launch_smoke "$install_root/Illiquid.app" "$smoke_profile" \
        || platinum_fail 'installed application launch smoke test failed'
fi
platinum_launch_smoke "$install_root/Illiquid.app" "$smoke_profile" \
    || platinum_fail 'installed application relaunch smoke test failed'

(
    cd "$output_directory"
    shasum -a 256 "$dmg_name" >"$dmg_name.sha256"
)
[[ -s "$checksum_path" ]] || platinum_fail 'checksum was not generated'

printf 'Packaged DMG (%s, %s): %s\n' "$signing_mode" "$architectures" "$dmg_path"
printf 'SHA-256: %s\n' "$checksum_path"
