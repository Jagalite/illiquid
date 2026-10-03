#!/usr/bin/env bash

set -euo pipefail

script_directory=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -P "$script_directory/.." && pwd)
# shellcheck source=Scripts/lib/platinum-packaging.sh
source "$script_directory/lib/platinum-packaging.sh"

usage() {
    cat <<'USAGE'
Usage: sign-platinum-app.sh {--adhoc|--developer-id|--unsigned} APP_PATH

Sign nested Mach-O code inside-out, then sign and verify the outer application.
Developer ID mode reads the identity from DEVELOPER_ID_APPLICATION.
USAGE
}

mode=
app_bundle=
while (($# > 0)); do
    case "$1" in
        --unsigned) mode=unsigned; shift ;;
        --adhoc) mode=adhoc; shift ;;
        --developer-id) mode=developer-id; shift ;;
        -h|--help) usage; exit 0 ;;
        --*) platinum_fail "unknown option: $1" ;;
        *)
            [[ -z "$app_bundle" ]] || platinum_fail 'only one application may be supplied'
            app_bundle=$1
            shift
            ;;
    esac
done
[[ -n "$mode" ]] || platinum_fail 'a signing mode is required'
[[ -n "$app_bundle" && -d "$app_bundle" ]] || platinum_fail 'an existing app is required'
[[ "$(basename "$app_bundle")" = Illiquid.app ]] || platinum_fail 'bundle must be Illiquid.app'

identity=$(platinum_signing_identity "$mode" "${DEVELOPER_ID_APPLICATION:-}") \
    || platinum_fail 'DEVELOPER_ID_APPLICATION is required for Developer ID mode'
plist=/usr/libexec/PlistBuddy
info_plist="$app_bundle/Contents/Info.plist"
"$plist" -c 'Delete :PlatinumSigningMode' "$info_plist" 2>/dev/null || true
"$plist" -c "Add :PlatinumSigningMode string $mode" "$info_plist"

if [[ "$mode" = unsigned ]]; then
    while IFS= read -r -d '' image; do
        codesign --remove-signature "$image" 2>/dev/null || true
    done < <(find "$app_bundle/Contents" -depth -type f \
        \( -name '*.dylib' -o -perm -111 \) -print0)
    printf 'Left application unsigned: %s\n' "$app_bundle"
    exit 0
fi

entitlements="$repository_root/Resources/Superplayr.entitlements"
[[ -f "$entitlements" ]] || platinum_fail "entitlements are missing: $entitlements"
plutil -lint "$entitlements" >/dev/null
if [[ "$mode" = adhoc ]]; then
    signing_arguments=(--force --sign "$identity" --timestamp=none)
else
    signing_arguments=(--force --sign "$identity" --timestamp --options runtime)
fi

while IFS= read -r nested_code; do
    codesign "${signing_arguments[@]}" "$nested_code"
done < <(
    find "$app_bundle/Contents/Frameworks" -depth -type f \
        \( -name '*.dylib' -o -perm -111 \) -print | LC_ALL=C sort
)
codesign "${signing_arguments[@]}" --entitlements "$entitlements" "$app_bundle"
codesign --verify --deep --strict --verbose=2 "$app_bundle"

printf 'Signed application (%s): %s\n' "$mode" "$app_bundle"
