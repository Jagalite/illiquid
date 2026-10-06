#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: build-app.sh [options]

Build Superplayr, assemble a native .app, bundle the FFmpeg/libass dependency
closure, rewrite loader paths, verify the bundle, and ad-hoc sign it by default.

Options:
  --configuration NAME   debug or release (default: release)
  --product NAME         executable product (default: Superplayr)
  --app-name NAME        bundle display name (default: Illiquid)
  --bundle-id ID         bundle identifier (default: io.github.jagalite.illiquid)
  --version VERSION      marketing version (default: 0.1.0)
  --build-number NUMBER  bundle build number (default: 1)
  --minimum-macos VER    minimum macOS version (default: 26.0)
  --output DIR           output directory (default: <repo>/dist)
  --skip-build           package an already-built executable
  --no-sign              skip ad-hoc signing
  -h, --help             show this help
USAGE
}

fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
require_value() { (($# >= 2)) || fail "$1 requires a value"; }

configuration=release
product=Superplayr
app_name=Illiquid
bundle_identifier=io.github.jagalite.illiquid
marketing_version=0.1.0
build_number=1
minimum_macos=26.0
output_directory=
skip_build=false
ad_hoc_sign=true

while (($# > 0)); do
    case "$1" in
        --configuration) require_value "$@"; configuration=$2; shift 2 ;;
        --product) require_value "$@"; product=$2; shift 2 ;;
        --app-name) require_value "$@"; app_name=$2; shift 2 ;;
        --bundle-id) require_value "$@"; bundle_identifier=$2; shift 2 ;;
        --version) require_value "$@"; marketing_version=$2; shift 2 ;;
        --build-number) require_value "$@"; build_number=$2; shift 2 ;;
        --minimum-macos) require_value "$@"; minimum_macos=$2; shift 2 ;;
        --output) require_value "$@"; output_directory=$2; shift 2 ;;
        --skip-build) skip_build=true; shift ;;
        --no-sign) ad_hoc_sign=false; shift ;;
        -h|--help) usage; exit 0 ;;
        *) fail "unknown option: $1" ;;
    esac
done

script_directory=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -P "$script_directory/.." && pwd)
source "$script_directory/lib/native-sdk-environment.sh"
illiquid_select_native_sdk "$repository_root"
app_name=${app_name:-$product}
output_directory=${output_directory:-$repository_root/dist}

[[ "$configuration" = debug || "$configuration" = release ]] || fail \
    '--configuration must be debug or release'
[[ "$product" != */* && "$app_name" != */* ]] || fail 'product and app names cannot contain slashes'
command -v swift >/dev/null || fail 'Swift from full Xcode is required'
command -v xcrun >/dev/null || fail 'xcrun from full Xcode is required'
command -v otool >/dev/null || fail 'otool is required'
command -v install_name_tool >/dev/null || fail 'install_name_tool is required'
command -v pkg-config >/dev/null || fail 'pkg-config is required (brew install pkg-config)'
pkg-config --exists libavformat || fail 'FFmpeg development libraries are required (brew install ffmpeg)'
illiquid_verify_ffmpeg_linkage || fail 'FFmpeg dependency preflight failed'
pkg-config --exists libass || fail 'libass development libraries are required (brew install libass)'

export MACOSX_DEPLOYMENT_TARGET=$minimum_macos
swift_build_args=(--package-path "$repository_root")
if [[ "${SUPERPLAYR_SWIFTPM_DISABLE_SANDBOX:-0}" = 1 ]]; then
    swift_build_args+=(--disable-sandbox)
fi
if [[ "$skip_build" = false ]]; then
    swift build "${swift_build_args[@]}" --configuration "$configuration" \
        --product "$product" -Xlinker -headerpad_max_install_names
fi
binary_directory=$(swift build "${swift_build_args[@]}" \
    --configuration "$configuration" --show-bin-path)
source_executable="$binary_directory/$product"
[[ -f "$source_executable" ]] || fail "executable not found: $source_executable"

native_shader_source="$repository_root/Sources/SuperplayrNativePlayback/Resources/NativePlaybackShaders.metal"
native_resource_bundle=$(find "$binary_directory" -maxdepth 1 -type d \
    -name '*SuperplayrNativePlayback.bundle' -print -quit)
[[ -n "$native_resource_bundle" ]] || fail 'native playback resource bundle is missing'
native_shader_air="$binary_directory/NativePlaybackShaders.air"
xcrun -sdk macosx metal -c "$native_shader_source" -o "$native_shader_air"
xcrun -sdk macosx metallib "$native_shader_air" \
    -o "$native_resource_bundle/default.metallib"
rm -f -- "$native_shader_air"
[[ -s "$native_resource_bundle/default.metallib" ]] \
    || fail 'failed to compile the native Metal shader library'

mkdir -p "$output_directory"
output_directory=$(cd -P "$output_directory" && pwd)
app_bundle="$output_directory/$app_name.app"
case "$app_bundle" in "$output_directory"/*.app) ;; *) fail "unsafe bundle path: $app_bundle" ;; esac
[[ ! -e "$app_bundle" ]] || rm -rf -- "$app_bundle"

frameworks="$app_bundle/Contents/Frameworks"
executable="$app_bundle/Contents/MacOS/$product"
mkdir -p "$app_bundle/Contents/MacOS" "$frameworks" "$app_bundle/Contents/Resources"
ditto "$source_executable" "$executable"
chmod 0755 "$executable"
ditto "$repository_root/Resources/Info.plist" "$app_bundle/Contents/Info.plist"
while IFS= read -r -d '' bundle; do
    ditto "$bundle" "$app_bundle/Contents/Resources/$(basename "$bundle")"
done < <(find "$binary_directory" -maxdepth 1 -type d -name '*.bundle' -print0)

plist=/usr/libexec/PlistBuddy
"$plist" -c "Set :CFBundleDisplayName $app_name" "$app_bundle/Contents/Info.plist"
"$plist" -c "Set :CFBundleName $app_name" "$app_bundle/Contents/Info.plist"
"$plist" -c "Set :CFBundleExecutable $product" "$app_bundle/Contents/Info.plist"
"$plist" -c "Set :CFBundleIdentifier $bundle_identifier" "$app_bundle/Contents/Info.plist"
"$plist" -c "Set :CFBundleShortVersionString $marketing_version" "$app_bundle/Contents/Info.plist"
"$plist" -c "Set :CFBundleVersion $build_number" "$app_bundle/Contents/Info.plist"
"$plist" -c "Set :LSMinimumSystemVersion $minimum_macos" "$app_bundle/Contents/Info.plist"
if [[ -f "$repository_root/Resources/AppIcon.icns" ]]; then
    ditto "$repository_root/Resources/AppIcon.icns" "$app_bundle/Contents/Resources/AppIcon.icns"
    "$plist" -c 'Add :CFBundleIconFile string AppIcon' "$app_bundle/Contents/Info.plist" 2>/dev/null || \
        "$plist" -c 'Set :CFBundleIconFile AppIcon' "$app_bundle/Contents/Info.plist"
fi

dependencies_for() {
    otool -L "$1" | sed -n '2,$p' | sed -E \
        's/^[[:space:]]*//; s/[[:space:]]+\(compatibility version.*$//'
}
is_system() { case "$1" in /usr/lib/*|/System/Library/*|/Library/Apple/System/*) return 0 ;; *) return 1 ;; esac; }

search_directories=("$frameworks")
for package in ffmpeg libass; do
    prefix=$(brew --prefix "$package" 2>/dev/null || true)
    [[ -z "$prefix" ]] || search_directories+=("$prefix/lib")
done
search_directories+=(/opt/homebrew/lib /usr/local/lib)

resolve_dependency() {
    local dependency=$1 owner=$2 candidate= name=
    case "$dependency" in
        /*) candidate=$dependency ;;
        @loader_path/*) candidate="$(dirname "$owner")/${dependency#@loader_path/}" ;;
        @executable_path/*) candidate="$(dirname "$executable")/${dependency#@executable_path/}" ;;
        @rpath/*)
            name=${dependency#@rpath/}
            for directory in "${search_directories[@]}"; do
                [[ -f "$directory/$name" ]] && { candidate="$directory/$name"; break; }
            done
            ;;
    esac
    [[ -n "$candidate" && -f "$candidate" ]] || return 1
    cd -P "$(dirname "$candidate")" && printf '%s/%s\n' "$PWD" "$(basename "$candidate")"
}

queue=("$executable")
processed=()
while ((${#queue[@]})); do
    owner=${queue[0]}
    queue=("${queue[@]:1}")
    for seen in "${processed[@]:-}"; do [[ "$seen" = "$owner" ]] && continue 2; done
    processed+=("$owner")
    while IFS= read -r dependency; do
        [[ -n "$dependency" ]] || continue
        is_system "$dependency" && continue
        source_library=$(resolve_dependency "$dependency" "$owner") || \
            fail "could not resolve $dependency referenced by $owner"
        destination="$frameworks/$(basename "$source_library")"
        if [[ ! -f "$destination" ]]; then
            ditto "$source_library" "$destination"
            chmod u+w "$destination"
            install_name_tool -id "@rpath/$(basename "$destination")" "$destination"
            queue+=("$destination")
        fi
        install_name_tool -change "$dependency" "@rpath/$(basename "$destination")" "$owner"
    done < <(dependencies_for "$owner")
done
install_name_tool -add_rpath @executable_path/../Frameworks "$executable" 2>/dev/null || true
plutil -lint "$app_bundle/Contents/Info.plist" >/dev/null

if [[ "$ad_hoc_sign" = true ]]; then
    "$script_directory/sign-and-notarize.sh" --identity - --skip-notarize "$app_bundle"
fi
"$script_directory/verify-app.sh" "$app_bundle"
printf '\nBuilt native application: %s\n' "$app_bundle"
