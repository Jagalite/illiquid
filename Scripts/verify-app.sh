#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: verify-app.sh [--require-signature] APP_PATH

Checks bundle structure, plist validity, Mach-O architectures, loader paths,
bundled dependency resolution, and (when present) the code signature. It fails
if a Mach-O image retains a non-system absolute dependency or rpath, or if the
bundle contains a removed libmpv/OpenGL dependency.
USAGE
}

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

dependencies_for() {
    otool -L "$1" | sed -n '/^[[:space:]]/p' | sed -E \
        's/^[[:space:]]*//; s/[[:space:]]+\(compatibility version.*$//'
}

rpaths_for() {
    otool -l "$1" | awk '
        $1 == "cmd" && $2 == "LC_RPATH" { expecting_path = 1; next }
        expecting_path && $1 == "path" { print $2; expecting_path = 0 }
    '
}

is_system_reference() {
    case "$1" in
        /usr/lib/*|/System/Library/*|/Library/Apple/System/*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

is_os_swift_runtime() {
    case "$1" in
        libswift*.dylib|libclang_rt.*.dylib)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

require_signature=false
app_bundle=

while (($# > 0)); do
    case "$1" in
        --require-signature)
            require_signature=true
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

[[ -n "$app_bundle" && -d "$app_bundle" ]] || fail 'an existing .app path is required'
[[ "$app_bundle" = *.app ]] || fail "not an app bundle: $app_bundle"

command -v otool >/dev/null 2>&1 || fail 'otool is required'
command -v lipo >/dev/null 2>&1 || fail 'lipo is required'
command -v codesign >/dev/null 2>&1 || fail 'codesign is required'

info_plist="$app_bundle/Contents/Info.plist"
[[ -f "$info_plist" ]] || fail 'Contents/Info.plist is missing'
plutil -lint "$info_plist" >/dev/null

executable_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info_plist")
bundle_identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")
executable="$app_bundle/Contents/MacOS/$executable_name"
frameworks="$app_bundle/Contents/Frameworks"

[[ -x "$executable" ]] || fail "main executable is missing or not executable: $executable"
[[ -d "$frameworks" ]] || fail 'Contents/Frameworks is missing'

images=("$executable")
while IFS= read -r -d '' image; do
    images+=("$image")
done < <(find "$frameworks" -type f \( -name '*.dylib' -o -perm -111 \) -print0)

if find "$app_bundle" -iname '*mpv*' -print -quit | grep -q .; then
    fail 'bundle contains a removed mpv artifact'
fi

((${#images[@]} > 1)) || fail 'no bundled dynamic libraries were found'

executable_architectures=$(lipo -archs "$executable")
errors=0

for image in "${images[@]}"; do
    image_architectures=$(lipo -archs "$image")
    for architecture in $executable_architectures; do
        case " $image_architectures " in
            *" $architecture "*)
                ;;
            *)
                printf 'error: %s lacks executable architecture %s (has: %s)\n' \
                    "$image" "$architecture" "$image_architectures" >&2
                errors=$((errors + 1))
                ;;
        esac
    done

    while IFS= read -r dependency; do
        [[ -n "$dependency" ]] || continue
        case "$dependency" in
            *libmpv*|*OpenGL*)
                printf 'error: forbidden legacy dependency in %s: %s\n' \
                    "$image" "$dependency" >&2
                errors=$((errors + 1))
                ;;
        esac
        case "$dependency" in
            /*)
                if ! is_system_reference "$dependency"; then
                    printf 'error: external absolute dependency in %s: %s\n' \
                        "$image" "$dependency" >&2
                    errors=$((errors + 1))
                fi
                ;;
            @rpath/*)
                dependency_base=$(basename "$dependency")
                if [[ ! -f "$frameworks/${dependency#@rpath/}" ]] && \
                    ! is_os_swift_runtime "$dependency_base"; then
                    printf 'error: unresolved bundled @rpath dependency in %s: %s\n' \
                        "$image" "$dependency" >&2
                    errors=$((errors + 1))
                fi
                ;;
            @loader_path/*)
                candidate="$(dirname "$image")/${dependency#@loader_path/}"
                if [[ ! -f "$candidate" ]]; then
                    printf 'error: unresolved @loader_path dependency in %s: %s\n' \
                        "$image" "$dependency" >&2
                    errors=$((errors + 1))
                fi
                ;;
            @executable_path/*)
                candidate="$(dirname "$executable")/${dependency#@executable_path/}"
                if [[ ! -f "$candidate" ]]; then
                    printf 'error: unresolved @executable_path dependency in %s: %s\n' \
                        "$image" "$dependency" >&2
                    errors=$((errors + 1))
                fi
                ;;
            *)
                printf 'error: unsupported dependency reference in %s: %s\n' \
                    "$image" "$dependency" >&2
                errors=$((errors + 1))
                ;;
        esac
    done < <(dependencies_for "$image")

    while IFS= read -r rpath; do
        case "$rpath" in
            /*)
                if ! is_system_reference "$rpath/placeholder"; then
                    printf 'error: external absolute rpath in %s: %s\n' \
                        "$image" "$rpath" >&2
                    errors=$((errors + 1))
                fi
                ;;
        esac
    done < <(rpaths_for "$image")
done

if ((errors > 0)); then
    fail "$errors bundle dependency check(s) failed"
fi

if codesign -dv "$app_bundle" >/dev/null 2>&1; then
    codesign --verify --deep --strict --verbose=2 "$app_bundle"
    signature_status='valid'
elif [[ "$require_signature" = true ]]; then
    fail 'the application is unsigned'
else
    signature_status='not present'
fi

printf 'Verified %s (%s)\n' "$app_bundle" "$bundle_identifier"
printf 'Architectures: %s\n' "$executable_architectures"
printf 'Mach-O images: %d\n' "${#images[@]}"
printf 'Code signature: %s\n' "$signature_status"
