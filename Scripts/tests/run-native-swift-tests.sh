#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: run-native-swift-tests.sh [--build | --build-only | --skip-build]
                                [--jobs N] [--filter REGEX]...

Build release tests with resolved dependencies, then run Swift Testing.
--build       Build and execute (default).
--build-only  Compile tests without executing them.
--skip-build  Execute existing .build/release tests; never invoke SwiftPM.
--jobs N      Limit SwiftPM build jobs (not valid with --skip-build).
--filter      Swift Testing regular expression; repeat for alternative matches.

Submit builds and execution through Kyoto with --resource "$PWD/.build".
The coordinating parent owns queue submission. Zero executed tests fail.
USAGE
}

fail() { printf 'native-swift-tests: %s\n' "$*" >&2; exit 2; }
mode=build
mode_selected=0
jobs=
runner_arguments=(--testing-library swift-testing --no-parallel)
while (($# > 0)); do
    case "$1" in
        --build|--build-only|--skip-build)
            ((mode_selected == 0)) || fail 'select only one build mode'
            mode=${1#--}
            mode_selected=1
            shift
            ;;
        --filter)
            (($# >= 2)) && [[ -n "$2" && "$2" != --* ]] || fail '--filter requires a nonempty regex'
            runner_arguments+=(--filter "$2")
            shift 2
            ;;
        --jobs)
            (($# >= 2)) || fail '--jobs requires a positive integer'
            [[ "$2" =~ ^[1-9][0-9]*$ ]] || fail '--jobs requires a positive integer'
            jobs=$2
            shift 2
            ;;
        -h|--help) usage; exit 0 ;;
        *) fail "unknown argument: $1" ;;
    esac
done
[[ "$mode" != skip-build || -z "$jobs" ]] || fail '--jobs cannot be used with --skip-build'

script_directory=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -P "$script_directory/../.." && pwd)
cd "$repository_root"
[[ "$(uname -s)" == Darwin ]] || fail 'this runner requires macOS'

# This runner intentionally selects the reviewed SDK, even if the caller has a
# different pkg-config/native-library selection. Preserve other test variables.
source "$repository_root/Scripts/lib/native-sdk-environment.sh"
unset PKG_CONFIG_PATH ILLIQUID_NATIVE_LIBRARY_PATH
illiquid_select_native_sdk "$repository_root" || fail 'could not select the pinned native SDK'
[[ -n "${PKG_CONFIG_PATH:-}" && -d "$PKG_CONFIG_PATH" && -n "${ILLIQUID_NATIVE_LIBRARY_PATH:-}" ]] ||
    fail 'pinned native SDK is missing; see BuildInputs/README.md'
IFS=: read -r -a native_directories <<< "$ILLIQUID_NATIVE_LIBRARY_PATH"
for directory in "${native_directories[@]}"; do
    [[ "$directory" == /* ]] || fail "native library directory must be absolute: $directory"
    if [[ ! -d "$directory" ]]; then
        printf 'native-swift-tests: unavailable transitive pin (dyld install-name fallback): %s\n' "$directory" >&2
    fi
done
for library in libavcodec.dylib libavformat.dylib libavfilter.dylib libavutil.dylib libswresample.dylib libswscale.dylib libass.dylib; do
    illiquid_pinned_native_library "$library" >/dev/null || fail "pinned SDK is missing $library"
done
# The reviewed FFmpeg requires this ABI, even when Homebrew's opt link advances.
illiquid_pinned_native_library libx265.216.dylib >/dev/null ||
    fail 'pinned SDK is missing libx265.216.dylib'
printf 'native-swift-tests: SDK pkg-config=%s\n' "$PKG_CONFIG_PATH"
printf 'native-swift-tests: SDK library search path=%s\n' "$ILLIQUID_NATIVE_LIBRARY_PATH"

binary_directory="$repository_root/.build/release"
if [[ "$mode" == skip-build ]]; then
    printf 'native-swift-tests: build skipped; existing binary freshness is caller-owned\n'
else
    swift_arguments=(--package-path "$repository_root" -c release --force-resolved-versions -Xswiftc -enable-testing)
    [[ -z "$jobs" ]] || swift_arguments+=(--jobs "$jobs")
    if [[ "${ILLIQUID_SWIFTPM_DISABLE_SANDBOX:-0}" = 1 ]]; then
        swift_arguments+=(--disable-sandbox)
    fi
    printf 'native-swift-tests: build starting; tests not run\n'
    if swift build "${swift_arguments[@]}" --build-tests; then
        printf 'native-swift-tests: build passed; tests not run\n'
    else
        status=$?
        printf 'native-swift-tests: build failed (exit %s); tests not run\n' "$status" >&2
        exit "$status"
    fi
    if binary_directory=$(swift build "${swift_arguments[@]}" --show-bin-path); then
        :
    else
        status=$?
        printf 'native-swift-tests: binary path lookup failed (exit %s); tests not run\n' "$status" >&2
        exit "$status"
    fi
fi
[[ -n "$binary_directory" && "$binary_directory" == /* && -d "$binary_directory" ]] ||
    fail "invalid release binary directory: $binary_directory"
binary_directory=$(cd -P "$binary_directory" && pwd)
test_binary="$binary_directory/IlliquidPackageTests.xctest"
if [[ -d "$test_binary" ]]; then
    test_binary="$test_binary/Contents/MacOS/IlliquidPackageTests"
fi
[[ -f "$test_binary" ]] || fail "test binary is missing: $test_binary"
binary_kind=$(/usr/bin/file -b "$test_binary")
printf 'native-swift-tests: binary=%s (%s)\n' "$test_binary" "$binary_kind"
if [[ "$mode" == build-only ]]; then
    printf 'native-swift-tests: build-only complete; tests not run\n'
    exit 0
fi

# Darwin bundles require SwiftPM's standard loader, not exec or XCTest's harness.
# Resolve it before setting DYLD, since xcrun/system launch boundaries strip it.
case "$binary_kind" in
    *Mach-O*bundle*)
        swift_path=$(xcrun --find swift) || fail 'could not locate the selected Swift toolchain'
        toolchain_usr=$(cd -P "$(dirname "$swift_path")/.." && pwd)
        testing_helper="$toolchain_usr/libexec/swift/pm/swiftpm-testing-helper"
        [[ -x "$testing_helper" ]] || fail "Swift Testing bundle loader is missing: $testing_helper"
        test_command=("$testing_helper" --test-bundle-path "$test_binary")
        ;;
    *Mach-O*executable*)
        [[ -x "$test_binary" ]] || fail "test executable is not executable: $test_binary"
        test_command=("$test_binary")
        ;;
    *) fail "unsupported test binary format: $binary_kind" ;;
esac

# Match SwiftPM's macOS test runtime search paths as well as the native SDK.
# The bundle can retain CommandLineTools rpaths while Xcode owns these runtimes.
platform_path=$(xcrun --show-sdk-platform-path) || fail 'could not locate the selected SDK platform'
platform_libraries="$platform_path/Developer/usr/lib"
platform_frameworks="$platform_path/Developer/Library/Frameworks"
[[ -d "$platform_libraries" && -d "$platform_frameworks" ]] || fail 'selected SDK test runtimes are missing'
runtime_library_path="$ILLIQUID_NATIVE_LIBRARY_PATH:$binary_directory:$platform_libraries"
runtime_framework_path="$binary_directory:$platform_frameworks"
if [[ -d "$platform_path/Developer/Library/PrivateFrameworks" ]]; then
    runtime_framework_path+=":$platform_path/Developer/Library/PrivateFrameworks"
fi
printf 'native-swift-tests: runtime library search path=%s\n' "$runtime_library_path"
printf 'native-swift-tests: runtime framework search path=%s\n' "$runtime_framework_path"

# Keep the machine-readable receipt, including failed and zero-match runs.
receipt_directory=$(mktemp -d "${TMPDIR:-/tmp}/illiquid-native-swift-tests.XXXXXX")
report="$receipt_directory/results.xml"
runner_arguments+=(--xunit-output "$report")
printf 'native-swift-tests: receipt=%s\n' "$report"
# Set DYLD on the loader/executable itself, after all system-tool launches.
printf 'native-swift-tests: execution starting'
printf ' %q' "${test_command[@]}" "${runner_arguments[@]}"
printf '\n'
if /usr/bin/env DYLD_LIBRARY_PATH="$runtime_library_path" \
    DYLD_FRAMEWORK_PATH="$runtime_framework_path" \
    "${test_command[@]}" "${runner_arguments[@]}"; then
    :
else
    status=$?
    printf 'native-swift-tests: execution failed (exit %s)\n' "$status" >&2
    exit "$status"
fi

# An exit-zero loader or an empty filter match is not execution evidence.
python3 - "$report" <<'PY'
import sys
import xml.etree.ElementTree as ET

try:
    root = ET.parse(sys.argv[1]).getroot()
    cases = root.findall(".//testcase")
    executed = [case for case in cases if case.find("skipped") is None and "time" in case.attrib]
    failed = root.findall(".//failure") + root.findall(".//error")
    print(f"native-swift-tests: matched={len(cases)} executed={len(executed)} failures={len(failed)}", flush=True)
    if not executed or failed:
        raise ValueError("require at least one completed test and no failures")
except (OSError, ET.ParseError, ValueError) as error:
    print(f"native-swift-tests: execution receipt rejected: {error}", file=sys.stderr)
    sys.exit(2)
PY
printf 'native-swift-tests: execution passed (exit 0; nonzero completed test count verified)\n'
