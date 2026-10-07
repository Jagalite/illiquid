#!/usr/bin/env bash

set -euo pipefail

script_directory=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -P "$script_directory/.." && pwd)

usage() {
    cat <<'USAGE'
Usage: build-local-dmg.sh [--unsigned|--adhoc|--developer-id]

Run focused tests, assemble and audit Illiquid.app, sign it in the selected
local mode, package the DMG, perform the installed-copy smoke test, and emit
the SHA-256 checksum. The default mode is ad hoc.
USAGE
}

mode=adhoc
while (($# > 0)); do
    case "$1" in
        --unsigned) mode=unsigned; shift ;;
        --adhoc) mode=adhoc; shift ;;
        --developer-id) mode=developer-id; shift ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'error: unknown option: %s\n' "$1" >&2; exit 1 ;;
    esac
done

cd "$repository_root"
"$script_directory/tests/illiquid-packaging-tests.sh"
python3 "$script_directory/tests/update-feed-tests.py"
swift test --force-resolved-versions -c release --filter \
    'AppUpdateControllerTests|DefaultVideoPlayerTests|ProductMetadataTests|LaunchOpenQueueTests|illiquidRetainsLegacy|PlayerInterfaceScaleTests|TimelineThumbnailHoverPolicyTests|TimelineThumbnailHoverRecoveryTests'

created_build_root=false
if [[ -z "${ILLIQUID_BUILD_ROOT:-}" ]]; then
    ILLIQUID_BUILD_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/illiquid-local-dmg-build.XXXXXX")
    export ILLIQUID_BUILD_ROOT
    created_build_root=true
fi
cleanup() {
    if [[ "$created_build_root" = true && -d "$ILLIQUID_BUILD_ROOT" ]]; then
        rm -rf -- "$ILLIQUID_BUILD_ROOT"
    fi
}
trap cleanup EXIT

"$script_directory/build-illiquid-app.sh" "--$mode"
if [[ "$mode" = developer-id && -n "${ILLIQUID_NOTARY_PROFILE:-}" ]]; then
    "$script_directory/notarize-artifact.sh" "$repository_root/dist/Illiquid.app"
fi
"$script_directory/package-illiquid-dmg.sh"
if [[ "$mode" = developer-id && -n "${ILLIQUID_NOTARY_PROFILE:-}" ]]; then
    version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$repository_root/dist/Illiquid.app/Contents/Info.plist")
    dmg="$repository_root/dist/Illiquid-$version-macOS.dmg"
    signing_arguments=(--force --sign "$DEVELOPER_ID_APPLICATION" --timestamp)
    [[ -z "${ILLIQUID_SIGNING_KEYCHAIN:-}" ]] || signing_arguments+=(--keychain "$ILLIQUID_SIGNING_KEYCHAIN")
    codesign "${signing_arguments[@]}" "$dmg"
    "$script_directory/notarize-artifact.sh" "$dmg"
    # Stapling changes the DMG bytes; checksums must describe the final artifact.
    (cd "$repository_root/dist" && shasum -a 256 "Illiquid-$version-macOS.dmg" > "Illiquid-$version-macOS.dmg.sha256")
fi

if [[ "$mode" = adhoc ]]; then
    printf '\nNOTICE: This ad hoc signed DMG is an unnotarized test prerelease.\n'
    printf 'Tagged GitHub releases require Developer ID signing and notarization. macOS may block this ad hoc build.\n'
elif [[ "$mode" = unsigned ]]; then
    printf '\nWARNING: This unsigned DMG is for controlled local testing only.\n'
fi
