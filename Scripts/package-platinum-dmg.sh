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
layout_python=${PLATINUM_DMG_PYTHON:-"$repository_root/.build/dmg-tools/bin/python"}
if [[ ! -x "$layout_python" ]]; then
    [[ -z "${PLATINUM_DMG_PYTHON:-}" ]] || platinum_fail 'PLATINUM_DMG_PYTHON is not executable'
    python3 -m venv "$repository_root/.build/dmg-tools"
fi
if ! "$layout_python" -c 'import ds_store, mac_alias' 2>/dev/null; then
    "$layout_python" -m pip install --quiet -r "$script_directory/requirements-dmg.txt"
fi

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
detach_install_volume() {
    local attempt
    for attempt in {1..10}; do
        if hdiutil detach "$mount_point" -quiet; then
            mount_point=
            return 0
        fi
        sleep 1
    done
    return 1
}
cleanup() {
    if [[ -n "$mount_point" && -d "$mount_point" ]]; then
        detach_install_volume 2>/dev/null || {
            printf 'Preserving mounted build volume: %s\n' "$mount_point" >&2
            return
        }
    fi
    [[ ! -d "$work_directory" ]] || rm -rf -- "$work_directory"
}
trap cleanup EXIT

xcrun clang -Wno-deprecated-declarations -framework CoreServices \
    "$script_directory/dmg-background-alias.c" -o "$work_directory/background-alias"

staging_directory="$work_directory/staging"
platinum_stage_dmg "$app_bundle" "$staging_directory" \
    || platinum_fail 'failed to stage DMG contents'
[[ -L "$staging_directory/Applications" ]] \
    || platinum_fail 'Applications symlink is missing from staging'
[[ "$(readlink "$staging_directory/Applications")" = /Applications ]] \
    || platinum_fail 'Applications symlink has the wrong destination'
mkdir -p "$staging_directory/.background"
ditto "$repository_root/Resources/DMG/InstallBackground.tiff" \
    "$staging_directory/.background/InstallBackground.tiff"

mkdir -p "$output_directory"
output_directory=$(cd -P "$output_directory" && pwd)
dmg_name="Illiquid-$version-macOS.dmg"
dmg_path="$output_directory/$dmg_name"
checksum_path="$dmg_path.sha256"
layout_mountpoint="/Volumes/Install Illiquid"
[[ ! -e "$layout_mountpoint" ]] || platinum_fail 'eject the mounted Install Illiquid volume before packaging'
rm -f -- "$dmg_path" "$checksum_path"
hdiutil create \
    -volname "Install Illiquid" \
    -srcfolder "$staging_directory" \
    -fs HFS+ \
    -format UDRW \
    -ov \
    "$work_directory/install-window.dmg" >/dev/null

layout_plist="$work_directory/layout-attach.plist"
hdiutil attach -nobrowse -mountpoint "$layout_mountpoint" -plist \
    "$work_directory/install-window.dmg" >"$layout_plist"
mount_point="$layout_mountpoint"
"$layout_python" "$script_directory/configure-dmg-layout.py" \
    "$mount_point" "$work_directory/background-alias"
[[ -s "$mount_point/.DS_Store" ]] || platinum_fail 'install window layout was not generated'
sync
detach_install_volume || platinum_fail 'could not detach install layout volume'
hdiutil convert "$work_directory/install-window.dmg" -format UDZO \
    -o "$dmg_path" >/dev/null

attach_plist="$work_directory/attach.plist"
hdiutil attach -nobrowse -readonly -plist "$dmg_path" >"$attach_plist"
mount_point=$(
    "$plist" -c 'Print :system-entities' "$attach_plist" \
        | sed -n 's/^[[:space:]]*mount-point = //p' | tail -1
)
[[ -n "$mount_point" && -d "$mount_point" ]] || platinum_fail 'DMG did not mount'
[[ -d "$mount_point/Illiquid.app" ]] || platinum_fail 'mounted DMG lacks Illiquid.app'
[[ -L "$mount_point/Applications" ]] || platinum_fail 'mounted DMG lacks Applications symlink'
[[ -s "$mount_point/.DS_Store" ]] || platinum_fail 'mounted DMG lacks install window layout'
[[ -s "$mount_point/.background/InstallBackground.tiff" ]] \
    || platinum_fail 'mounted DMG lacks install window background'
"$layout_python" "$script_directory/configure-dmg-layout.py" \
    "$mount_point" "$work_directory/background-alias" --verify
osascript "$script_directory/configure-dmg-window.applescript" "$mount_point" --verify

install_root="$work_directory/Applications"
mkdir -p "$install_root"
ditto "$mount_point/Illiquid.app" "$install_root/Illiquid.app"
detach_install_volume || platinum_fail 'could not detach verification volume'
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
