#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: run-app.sh [--configuration release|debug] [-- APP_ARGUMENTS...]

Build and run Illiquid directly from source (release by default).
Uses the installed native SDK when available, without assembling an .app.
USAGE
}

configuration=release
while (($# > 0)); do
    case "$1" in
        --configuration)
            (($# >= 2)) || { usage >&2; exit 1; }
            configuration=$2
            shift 2
            ;;
        --) shift; break ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 1 ;;
    esac
done
case "$configuration" in
    release|debug) ;;
    *) printf 'Configuration must be release or debug\n' >&2; exit 1 ;;
esac

script_directory=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -P "$script_directory/.." && pwd)
source "$script_directory/lib/native-sdk-environment.sh"
illiquid_select_native_sdk "$repository_root"

swift_arguments=(--package-path "$repository_root" --configuration "$configuration")
if [[ "${ILLIQUID_SWIFTPM_DISABLE_SANDBOX:-0}" = 1 ]]; then
    swift_arguments+=(--disable-sandbox)
fi
swift build "${swift_arguments[@]}" --product Illiquid
binary_directory=$(swift build "${swift_arguments[@]}" --show-bin-path)

# Apply the paths directly to the executable: macOS may strip DYLD_* variables
# while SwiftPM invokes system tools. Include transitive SDK libraries because
# Homebrew's opt links can advance independently of the installed FFmpeg build.
if [[ -n "${ILLIQUID_NATIVE_LIBRARY_PATH:-}" ]]; then
    exec /usr/bin/env \
        DYLD_LIBRARY_PATH="$ILLIQUID_NATIVE_LIBRARY_PATH${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" \
        "$binary_directory/Illiquid" "$@"
fi
exec "$binary_directory/Illiquid" "$@"
