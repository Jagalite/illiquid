#!/usr/bin/env bash

set -euo pipefail

script_directory=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -P "$script_directory/.." && pwd)
# shellcheck source=scripts/lib/platinum-packaging.sh
source "$script_directory/lib/platinum-packaging.sh"

usage() {
    cat <<'USAGE'
Usage: build-platinum-app.sh [--output DIR] [--unsigned|--adhoc|--developer-id]

Build Release in an isolated SwiftPM scratch directory, assemble a self-contained
Illiquid.app, rewrite runtime library paths, and audit the result.

Environment:
  PLATINUM_VERSION, PLATINUM_BUILD_NUMBER, PLATINUM_BUNDLE_ID
  PLATINUM_ARCHS, PLATINUM_MINIMUM_MACOS, PLATINUM_COPYRIGHT
  PLATINUM_BUILD_ROOT, PLATINUM_SIGNING_MODE, DEVELOPER_ID_APPLICATION
USAGE
}

output_directory="$repository_root/dist"
signing_mode=${PLATINUM_SIGNING_MODE:-adhoc}
while (($# > 0)); do
    case "$1" in
        --output)
            (($# >= 2)) || platinum_fail '--output requires a directory'
            output_directory=$2
            shift 2
            ;;
        --unsigned) signing_mode=unsigned; shift ;;
        --adhoc) signing_mode=adhoc; shift ;;
        --developer-id) signing_mode=developer-id; shift ;;
        -h|--help) usage; exit 0 ;;
        --*) platinum_fail "unknown option: $1" ;;
        *) platinum_fail "unexpected argument: $1" ;;
    esac
done
platinum_signing_identity "$signing_mode" "${DEVELOPER_ID_APPLICATION:-}" >/dev/null \
    || platinum_fail 'invalid signing mode or missing DEVELOPER_ID_APPLICATION'

for command_name in swift xcrun otool lipo install_name_tool pkg-config sips iconutil ditto codesign python3 ffmpeg; do
    command -v "$command_name" >/dev/null 2>&1 || platinum_fail "$command_name is required"
done
pkg-config --exists libavformat || platinum_fail 'FFmpeg development libraries are required'
pkg-config --exists libavfilter || platinum_fail 'FFmpeg deinterlacing filter libraries are required'
pkg-config --exists libass || platinum_fail 'libass development libraries are required'

metadata="$repository_root/Resources/Info.plist"
plist=/usr/libexec/PlistBuddy
default_version=$("$plist" -c 'Print :CFBundleShortVersionString' "$metadata")
default_build=$("$plist" -c 'Print :CFBundleVersion' "$metadata")
default_bundle_id=$("$plist" -c 'Print :CFBundleIdentifier' "$metadata")
default_minimum_macos=$("$plist" -c 'Print :LSMinimumSystemVersion' "$metadata")
default_copyright=$("$plist" -c 'Print :NSHumanReadableCopyright' "$metadata")
default_architectures=$("$plist" -c 'Print :PlatinumBuildArchitectures' "$metadata" \
    | awk '/^[[:space:]]*[[:alnum:]_]+[[:space:]]*$/ {
        gsub(/[[:space:]]/, ""); print
      }' \
    | paste -sd' ' -)

version=${PLATINUM_VERSION:-$default_version}
build_number=${PLATINUM_BUILD_NUMBER:-$default_build}
bundle_identifier=${PLATINUM_BUNDLE_ID:-$default_bundle_id}
minimum_macos=${PLATINUM_MINIMUM_MACOS:-$default_minimum_macos}
copyright=${PLATINUM_COPYRIGHT:-$default_copyright}
architectures=${PLATINUM_ARCHS:-$default_architectures}
[[ -n "$architectures" ]] || platinum_fail 'PLATINUM_ARCHS cannot be empty'

created_build_root=false
if [[ -n "${PLATINUM_BUILD_ROOT:-}" ]]; then
    build_root=$PLATINUM_BUILD_ROOT
    mkdir -p "$build_root"
    build_root=$(cd -P "$build_root" && pwd)
else
    build_root=$(mktemp -d "${TMPDIR:-/tmp}/platinum-app-build.XXXXXX")
    created_build_root=true
fi
cleanup() {
    if [[ "$created_build_root" = true && -d "$build_root" ]]; then
        rm -rf -- "$build_root"
    fi
}
trap cleanup EXIT

export MACOSX_DEPLOYMENT_TARGET=$minimum_macos
swift_arguments=(
    --package-path "$repository_root"
    --scratch-path "$build_root/swiftpm"
    --configuration release
    --force-resolved-versions
)
for architecture in $architectures; do
    swift_arguments+=(--arch "$architecture")
done
swift build "${swift_arguments[@]}" --product Superplayr \
    -Xlinker -headerpad_max_install_names \
    -Xswiftc -file-prefix-map -Xswiftc "$repository_root=." \
    -Xswiftc -debug-prefix-map -Xswiftc "$repository_root=." \
    -Xswiftc -debug-prefix-map -Xswiftc "$build_root=build" \
    -Xcc "-ffile-prefix-map=$repository_root=."
binary_directory=$(swift build "${swift_arguments[@]}" --show-bin-path)
source_executable="$binary_directory/Superplayr"
[[ -x "$source_executable" ]] || platinum_fail "executable is missing: $source_executable"

native_shader_source="$repository_root/Sources/SuperplayrNativePlayback/Resources/NativePlaybackShaders.metal"
native_resource_bundle=$(find "$binary_directory" -maxdepth 1 -type d \
    -name '*SuperplayrNativePlayback.bundle' -print -quit)
[[ -n "$native_resource_bundle" ]] \
    || platinum_fail 'native playback resource bundle is missing'
native_shader_air="$build_root/NativePlaybackShaders.air"
xcrun -sdk macosx metal -c "$native_shader_source" -o "$native_shader_air"
xcrun -sdk macosx metallib "$native_shader_air" \
    -o "$native_resource_bundle/default.metallib"
[[ -s "$native_resource_bundle/default.metallib" ]] \
    || platinum_fail 'failed to compile the native Metal shader library'

mkdir -p "$output_directory"
output_directory=$(cd -P "$output_directory" && pwd)
app_bundle="$output_directory/Illiquid.app"
case "$app_bundle" in "$output_directory/Illiquid.app") ;; *) platinum_fail 'unsafe output path' ;; esac
[[ ! -e "$app_bundle" ]] || rm -rf -- "$app_bundle"
frameworks="$app_bundle/Contents/Frameworks"
resources="$app_bundle/Contents/Resources"
executable="$app_bundle/Contents/MacOS/Illiquid"
mkdir -p "$app_bundle/Contents/MacOS" "$frameworks" "$resources"
# Include project terms and the collected dependency notices before signing.
for license_document in LICENSE LICENSING.md THIRD_PARTY_NOTICES.md; do
    [[ -s "$repository_root/$license_document" ]] || platinum_fail "missing $license_document"
    ditto "$repository_root/$license_document" "$resources/$license_document"
done
ditto "$repository_root/Licenses" "$resources/Licenses"
ditto "$source_executable" "$executable"
chmod 0755 "$executable"
ditto "$metadata" "$app_bundle/Contents/Info.plist"

while IFS= read -r -d '' resource_bundle; do
    ditto "$resource_bundle" "$resources/$(basename "$resource_bundle")"
done < <(find "$binary_directory" -maxdepth 1 -type d -name '*.bundle' -print0)
find "$resources" -maxdepth 1 -type d -name '*.bundle' -print -quit | grep -q . \
    || platinum_fail 'SwiftPM did not produce the required resource bundle'

"$plist" -c 'Set :CFBundleName Illiquid' "$app_bundle/Contents/Info.plist"
"$plist" -c 'Set :CFBundleDisplayName Illiquid' "$app_bundle/Contents/Info.plist"
"$plist" -c 'Set :CFBundleExecutable Illiquid' "$app_bundle/Contents/Info.plist"
"$plist" -c "Set :CFBundleIdentifier $bundle_identifier" "$app_bundle/Contents/Info.plist"
"$plist" -c "Set :CFBundleShortVersionString $version" "$app_bundle/Contents/Info.plist"
"$plist" -c "Set :CFBundleVersion $build_number" "$app_bundle/Contents/Info.plist"
"$plist" -c "Set :LSMinimumSystemVersion $minimum_macos" "$app_bundle/Contents/Info.plist"
"$plist" -c "Set :NSHumanReadableCopyright $copyright" "$app_bundle/Contents/Info.plist"
git_revision=$(git -C "$repository_root" rev-parse --short=12 HEAD 2>/dev/null || true)
if [[ -n "$git_revision" ]]; then
    "$plist" -c 'Delete :PlatinumGitCommit' "$app_bundle/Contents/Info.plist" 2>/dev/null || true
    "$plist" -c "Add :PlatinumGitCommit string $git_revision" "$app_bundle/Contents/Info.plist"
fi

icon_work="$build_root/Illiquid.iconset"
mkdir -p "$icon_work"
master_icon="$build_root/Illiquid-1024.png"
sips -s format png "$repository_root/Resources/IlliquidIcon.svg" \
    --out "$master_icon" >/dev/null
for specification in \
    '16 icon_16x16.png' \
    '32 icon_16x16@2x.png' \
    '32 icon_32x32.png' \
    '64 icon_32x32@2x.png' \
    '128 icon_128x128.png' \
    '256 icon_128x128@2x.png' \
    '256 icon_256x256.png' \
    '512 icon_256x256@2x.png' \
    '512 icon_512x512.png' \
    '1024 icon_512x512@2x.png'
do
    size=${specification%% *}
    filename=${specification#* }
    sips -z "$size" "$size" "$master_icon" --out "$icon_work/$filename" >/dev/null
done
iconutil -c icns "$icon_work" -o "$resources/AppIcon.icns"
[[ -s "$resources/AppIcon.icns" ]] || platinum_fail 'failed to create AppIcon.icns'

search_directories=()
for package in libavformat libavfilter libass; do
    library_directory=$(pkg-config --variable=libdir "$package")
    [[ -d "$library_directory" ]] && search_directories+=("$library_directory")
done
search_directories+=(/opt/homebrew/lib /usr/local/lib)

resolve_dependency() {
    local dependency=$1
    local owner=$2
    local candidate=
    case "$dependency" in
        /*) candidate=$dependency ;;
        @loader_path/*) candidate="$(dirname "$owner")/${dependency#@loader_path/}" ;;
        @executable_path/*) candidate="$(dirname "$source_executable")/${dependency#@executable_path/}" ;;
        @rpath/*)
            local name=${dependency#@rpath/}
            local directory
            for directory in "${search_directories[@]}"; do
                if [[ -f "$directory/$name" ]]; then
                    candidate="$directory/$name"
                    break
                fi
            done
            ;;
    esac
    [[ -n "$candidate" && -f "$candidate" ]] || return 1
    python3 -c 'import pathlib, sys; print(pathlib.Path(sys.argv[1]).resolve(strict=True))' "$candidate"
}

queue=("$source_executable")
processed=()
input_libraries=()
provenance_arguments=()
while ((${#queue[@]} > 0)); do
    original_owner=${queue[0]}
    queue=("${queue[@]:1}")
    if [[ "$original_owner" = "$source_executable" ]]; then
        owner=$executable
    else
        owner="$frameworks/$(basename "$original_owner")"
    fi
    for seen in "${processed[@]:-}"; do
        [[ "$seen" = "$owner" ]] && continue 2
    done
    processed+=("$owner")

    while IFS= read -r dependency; do
        [[ -n "$dependency" ]] || continue
        platinum_is_system_dependency "$dependency" && continue
        source_library=$(resolve_dependency "$dependency" "$original_owner") \
            || platinum_fail "could not resolve $dependency referenced by $original_owner"
        # otool -L includes a dylib's own install name; its ID was rewritten
        # separately. Always resolve dependencies from original, unmodified inputs.
        [[ "$source_library" -ef "$original_owner" ]] && continue
        destination="$frameworks/$(basename "$source_library")"
        for prior_input in "${input_libraries[@]:-}"; do
            [[ -n "$prior_input" ]] || continue
            if [[ "$(basename "$prior_input")" = "$(basename "$source_library")" ]]; then
                cmp -s "$prior_input" "$source_library" \
                    || platinum_fail "conflicting library basename: $source_library and $prior_input"
            fi
        done
        if [[ ! -f "$destination" ]]; then
            ditto "$source_library" "$destination"
            chmod u+w "$destination"
            install_name_tool -id "@rpath/$(basename "$destination")" "$destination"
            queue+=("$source_library")
            input_libraries+=("$source_library")
            provenance_arguments+=(--input-library "$source_library")
        fi
        install_name_tool -change "$dependency" "@rpath/$(basename "$destination")" "$owner"
    done < <(platinum_dependencies_for "$original_owner")

    while IFS= read -r rpath; do
        case "$rpath" in
            /opt/homebrew/*|/usr/local/*|"$repository_root"/*)
                install_name_tool -delete_rpath "$rpath" "$owner"
                ;;
        esac
    done < <(platinum_rpaths_for "$owner")
done
install_name_tool -add_rpath '@executable_path/../Frameworks' "$executable" 2>/dev/null || true
for image in "${processed[@]}"; do
    codesign --remove-signature "$image" 2>/dev/null || true
done

python3 "$script_directory/record-native-dependencies.py" \
    --bundle "$app_bundle" --output "$resources/NativeDependencyProvenance.json" \
    "${provenance_arguments[@]}" \
    --verify-lock "$script_directory/native-dependencies.lock.json"
"$script_directory/sign-platinum-app.sh" "--$signing_mode" "$app_bundle"
audit_arguments=(--archs "$architectures")
[[ "$signing_mode" = unsigned ]] || audit_arguments+=(--require-signature)
"$script_directory/audit-platinum-app.sh" "${audit_arguments[@]}" "$app_bundle"
printf '\nBuilt application (%s): %s\n' "$signing_mode" "$app_bundle"
