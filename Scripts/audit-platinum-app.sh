#!/usr/bin/env bash

set -euo pipefail

script_directory=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/platinum-packaging.sh
source "$script_directory/lib/platinum-packaging.sh"

usage() {
    cat <<'USAGE'
Usage: audit-platinum-app.sh [--require-signature] [--archs "arm64 ..."] APP_PATH

Validate Illiquid bundle metadata, required resources, Mach-O architectures,
dependency containment, runtime paths, and the code signature when requested.
USAGE
}

require_signature=false
required_architectures=${PLATINUM_ARCHS:-}
app_bundle=
while (($# > 0)); do
    case "$1" in
        --require-signature) require_signature=true; shift ;;
        --archs)
            (($# >= 2)) || platinum_fail '--archs requires a value'
            required_architectures=$2
            shift 2
            ;;
        -h|--help) usage; exit 0 ;;
        --*) platinum_fail "unknown option: $1" ;;
        *)
            [[ -z "$app_bundle" ]] || platinum_fail 'only one application may be supplied'
            app_bundle=$1
            shift
            ;;
    esac
done

[[ -n "$app_bundle" && -d "$app_bundle" ]] || platinum_fail 'an existing app is required'
[[ "$(basename "$app_bundle")" = Illiquid.app ]] || platinum_fail 'bundle must be named Illiquid.app'
for command_name in otool lipo codesign plutil; do
    command -v "$command_name" >/dev/null 2>&1 || platinum_fail "$command_name is required"
done

info_plist="$app_bundle/Contents/Info.plist"
[[ -f "$info_plist" ]] || platinum_fail 'Contents/Info.plist is missing'
plutil -lint "$info_plist" >/dev/null
plist=/usr/libexec/PlistBuddy
[[ "$("$plist" -c 'Print :CFBundleName' "$info_plist")" = Illiquid ]] \
    || platinum_fail 'CFBundleName is not Illiquid'
[[ "$("$plist" -c 'Print :CFBundleDisplayName' "$info_plist")" = Illiquid ]] \
    || platinum_fail 'CFBundleDisplayName is not Illiquid'
[[ "$("$plist" -c 'Print :CFBundleExecutable' "$info_plist")" = Illiquid ]] \
    || platinum_fail 'CFBundleExecutable is not Illiquid'
"$plist" -c 'Print :CFBundleIdentifier' "$info_plist" >/dev/null
"$plist" -c 'Print :CFBundleShortVersionString' "$info_plist" >/dev/null
"$plist" -c 'Print :CFBundleVersion' "$info_plist" >/dev/null
"$plist" -c 'Print :LSMinimumSystemVersion' "$info_plist" >/dev/null
"$plist" -c 'Print :CFBundleDocumentTypes:0:LSItemContentTypes' "$info_plist" >/dev/null
"$plist" -c 'Print :UTImportedTypeDeclarations' "$info_plist" >/dev/null

executable="$app_bundle/Contents/MacOS/Illiquid"
frameworks="$app_bundle/Contents/Frameworks"
resources="$app_bundle/Contents/Resources"
[[ -x "$executable" ]] || platinum_fail 'Contents/MacOS/Illiquid is missing or not executable'
[[ -d "$frameworks" ]] || platinum_fail 'Contents/Frameworks is missing'
[[ -f "$resources/AppIcon.icns" ]] || platinum_fail 'AppIcon.icns is missing'
for license_document in LICENSE LICENSING.md THIRD_PARTY_NOTICES.md Licenses/dependency-inventory.json Licenses/original-assets.json; do
    [[ -s "$resources/$license_document" ]] || platinum_fail "license resource is missing: $license_document"
done
[[ -d "$resources/Licenses/ThirdParty" ]] || platinum_fail 'third-party notices directory is missing'
# Presence checks do not establish source availability or legal completeness.
find "$resources" -maxdepth 1 -type d -name '*.bundle' -print -quit | grep -q . \
    || platinum_fail 'SwiftPM resource bundle is missing'

images=("$executable")
while IFS= read -r -d '' image; do
    images+=("$image")
done < <(find "$frameworks" -type f \( -name '*.dylib' -o -perm -111 \) -print0)
((${#images[@]} > 1)) || platinum_fail 'no runtime libraries were embedded'

if [[ -z "$required_architectures" ]]; then
    required_architectures=$(lipo -archs "$executable")
fi
errors=0
for image in "${images[@]}"; do
    actual_architectures=$(lipo -archs "$image")
    if ! platinum_architectures_cover "$required_architectures" "$actual_architectures"; then
        printf 'error: %s has architectures "%s"; required "%s"\n' \
            "$image" "$actual_architectures" "$required_architectures" >&2
        errors=$((errors + 1))
    fi

    while IFS= read -r dependency; do
        [[ -n "$dependency" ]] || continue
        if ! platinum_dependency_reference_is_allowed "$dependency"; then
            printf 'error: dependency escapes bundle in %s: %s\n' "$image" "$dependency" >&2
            errors=$((errors + 1))
            continue
        fi
        case "$dependency" in
            @rpath/*)
                [[ -f "$frameworks/${dependency#@rpath/}" ]] || {
                    printf 'error: unresolved dependency in %s: %s\n' "$image" "$dependency" >&2
                    errors=$((errors + 1))
                }
                ;;
            @loader_path/*)
                [[ -f "$(dirname "$image")/${dependency#@loader_path/}" ]] || {
                    printf 'error: unresolved dependency in %s: %s\n' "$image" "$dependency" >&2
                    errors=$((errors + 1))
                }
                ;;
            @executable_path/*)
                [[ -f "$(dirname "$executable")/${dependency#@executable_path/}" ]] || {
                    printf 'error: unresolved dependency in %s: %s\n' "$image" "$dependency" >&2
                    errors=$((errors + 1))
                }
                ;;
        esac
    done < <(platinum_dependencies_for "$image")

    while IFS= read -r rpath; do
        case "$rpath" in
            /opt/homebrew/*|/usr/local/*|"$PWD"/*)
                printf 'error: external runtime path in %s: %s\n' "$image" "$rpath" >&2
                errors=$((errors + 1))
                ;;
        esac
    done < <(platinum_rpaths_for "$image")
done
((errors == 0)) || platinum_fail "$errors bundle audit check(s) failed"

signature_status=unsigned
if codesign -dv "$app_bundle" >/dev/null 2>&1; then
    codesign --verify --deep --strict --verbose=2 "$app_bundle"
    signature_status=valid
elif [[ "$require_signature" = true ]]; then
    platinum_fail 'bundle is unsigned'
fi

printf 'Verified Illiquid.app\n'
printf 'Architectures: %s\n' "$required_architectures"
printf 'Mach-O images: %d\n' "${#images[@]}"
printf 'Code signature: %s\n' "$signature_status"
