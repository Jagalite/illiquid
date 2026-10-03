#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: sign-and-notarize.sh [options] APP_PATH

Sign nested dylibs and the application from the inside out. With a Developer ID
identity and notarytool keychain profile, also submit, wait, staple, and validate.

Options:
  --identity NAME       codesign identity. Required; use '-' for local ad-hoc.
  --entitlements PATH   App entitlements plist (default: Resources/Superplayr.entitlements).
  --keychain PATH       Optional keychain passed to codesign.
  --notary-profile NAME notarytool keychain profile created with store-credentials.
  --archive PATH        Notarization zip output (default: sibling of the app).
  --skip-notarize       Sign only; required with an ad-hoc identity.
  -h, --help            Show this help.

Examples:
  sign-and-notarize.sh --identity - --skip-notarize dist/Superplayr.app
  sign-and-notarize.sh --identity 'Developer ID Application: Example (TEAMID)' \
    --notary-profile superplayr-notary dist/Superplayr.app
USAGE
}

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

identity=
entitlements=
keychain=
notary_profile=
archive=
skip_notarize=false
app_bundle=

while (($# > 0)); do
    case "$1" in
        --identity)
            (($# >= 2)) || fail '--identity requires a value'
            identity=$2
            shift 2
            ;;
        --entitlements)
            (($# >= 2)) || fail '--entitlements requires a path'
            entitlements=$2
            shift 2
            ;;
        --keychain)
            (($# >= 2)) || fail '--keychain requires a path'
            keychain=$2
            shift 2
            ;;
        --notary-profile)
            (($# >= 2)) || fail '--notary-profile requires a name'
            notary_profile=$2
            shift 2
            ;;
        --archive)
            (($# >= 2)) || fail '--archive requires a path'
            archive=$2
            shift 2
            ;;
        --skip-notarize)
            skip_notarize=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --*)
            fail "unknown option: $1"
            ;;
        *)
            [[ -z "$app_bundle" ]] || fail 'only one application path may be supplied'
            app_bundle=$1
            shift
            ;;
    esac
done

[[ -n "$identity" ]] || fail '--identity is required'
[[ -n "$app_bundle" && -d "$app_bundle" ]] || fail 'an existing .app path is required'
[[ "$app_bundle" = *.app ]] || fail "not an app bundle: $app_bundle"

script_directory=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -P "$script_directory/.." && pwd)
entitlements=${entitlements:-$repository_root/Resources/Superplayr.entitlements}
archive=${archive:-${app_bundle%.app}-notarization.zip}

[[ -f "$entitlements" ]] || fail "entitlements file does not exist: $entitlements"
plutil -lint "$entitlements" >/dev/null
command -v codesign >/dev/null 2>&1 || fail 'codesign is required'

if [[ "$identity" = '-' ]]; then
    [[ "$skip_notarize" = true ]] || fail 'ad-hoc signatures cannot be notarized; pass --skip-notarize'
    codesign_arguments=(--force --sign "$identity" --timestamp=none)
else
    codesign_arguments=(--force --sign "$identity" --timestamp --options runtime)
fi

if [[ -n "$keychain" ]]; then
    [[ -f "$keychain" ]] || fail "keychain does not exist: $keychain"
    codesign_arguments+=(--keychain "$keychain")
fi

frameworks="$app_bundle/Contents/Frameworks"
if [[ -d "$frameworks" ]]; then
    while IFS= read -r -d '' nested_code; do
        codesign \
            "${codesign_arguments[@]}" \
            "$nested_code"
    done < <(find "$frameworks" -depth -type f ! -name '*.cstemp' \
        \( -name '*.dylib' -o -perm -111 \) -print0)
fi

codesign \
    "${codesign_arguments[@]}" \
    --entitlements "$entitlements" \
    "$app_bundle"

codesign --verify --deep --strict --verbose=2 "$app_bundle"
codesign -dvv "$app_bundle"

if [[ "$skip_notarize" = true ]]; then
    printf 'Signed application: %s\n' "$app_bundle"
    exit 0
fi

[[ -n "$notary_profile" ]] || fail '--notary-profile is required unless --skip-notarize is used'
command -v xcrun >/dev/null 2>&1 || fail 'xcrun is required'
command -v ditto >/dev/null 2>&1 || fail 'ditto is required'

case "$archive" in
    *.zip)
        ;;
    *)
        fail '--archive must end in .zip'
        ;;
esac

archive_parent=$(dirname "$archive")
mkdir -p "$archive_parent"
if [[ -e "$archive" ]]; then
    rm -f -- "$archive"
fi
ditto -c -k --keepParent "$app_bundle" "$archive"

xcrun notarytool submit \
    "$archive" \
    --keychain-profile "$notary_profile" \
    --wait
xcrun stapler staple "$app_bundle"
xcrun stapler validate "$app_bundle"
spctl --assess --type execute --verbose=4 "$app_bundle"

printf 'Signed and notarized application: %s\n' "$app_bundle"
printf 'Submission archive: %s\n' "$archive"
