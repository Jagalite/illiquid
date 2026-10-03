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
"$script_directory/tests/platinum-packaging-tests.sh"
swift test -c release --filter \
    'ProductMetadataTests|LaunchOpenQueueTests|platinumRetainsLegacy'

created_build_root=false
if [[ -z "${PLATINUM_BUILD_ROOT:-}" ]]; then
    PLATINUM_BUILD_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/platinum-local-dmg-build.XXXXXX")
    export PLATINUM_BUILD_ROOT
    created_build_root=true
fi
cleanup() {
    if [[ "$created_build_root" = true && -d "$PLATINUM_BUILD_ROOT" ]]; then
        rm -rf -- "$PLATINUM_BUILD_ROOT"
    fi
}
trap cleanup EXIT

"$script_directory/build-platinum-app.sh" "--$mode"
"$script_directory/package-platinum-dmg.sh"

if [[ "$mode" = adhoc ]]; then
    printf '\nWARNING: This ad hoc signed DMG is for local development/testing.\n'
    printf 'It is not ready for normal public internet distribution.\n'
elif [[ "$mode" = unsigned ]]; then
    printf '\nWARNING: This unsigned DMG is for controlled local testing only.\n'
fi
