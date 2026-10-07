#!/usr/bin/env bash

set -euo pipefail

script_directory=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/illiquid-packaging.sh
source "$script_directory/../lib/illiquid-packaging.sh"
source "$script_directory/../lib/native-sdk-environment.sh"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

illiquid_dependency_reference_is_allowed '@rpath/libavcodec.62.dylib' \
    || fail 'bundled @rpath dependency should be accepted'
illiquid_dependency_reference_is_allowed '/System/Library/Frameworks/AppKit.framework/AppKit' \
    || fail 'system framework should be accepted'
! illiquid_dependency_reference_is_allowed '/opt/homebrew/lib/libass.9.dylib' \
    || fail 'Homebrew dependency should escape the bundle audit'
! illiquid_dependency_reference_is_allowed '/private/tmp/user/project/liblocal.dylib' \
    || fail 'source-checkout dependency should escape the bundle audit'

! illiquid_dependency_reference_is_allowed '/System/Library/Frameworks/OpenGL.framework/Versions/A/OpenGL' \
    || fail 'OpenGL must fail even though it is a system framework'
! illiquid_dependency_reference_is_allowed '@rpath/libmpv.2.dylib' \
    || fail 'bundling a legacy backend must not bypass the audit'

illiquid_architectures_cover 'arm64' 'arm64 x86_64' \
    || fail 'a universal dependency should satisfy arm64'
! illiquid_architectures_cover 'arm64 x86_64' 'arm64' \
    || fail 'an arm64-only dependency should not satisfy universal packaging'

[[ "$(illiquid_signing_identity unsigned ignored)" = '' ]] \
    || fail 'unsigned mode should not select an identity'
[[ "$(illiquid_signing_identity adhoc ignored)" = '-' ]] \
    || fail 'ad hoc mode should select the ad hoc identity'
[[ "$(illiquid_signing_identity developer-id 'Developer ID Application: Test')" \
    = 'Developer ID Application: Test' ]] \
    || fail 'Developer ID mode should use the supplied identity'
! illiquid_signing_identity developer-id '' >/dev/null \
    || fail 'Developer ID mode should require an identity'

temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/illiquid-staging-test.XXXXXX")
trap 'rm -rf -- "$temporary_directory"' EXIT
mkdir -p "$temporary_directory/source/Illiquid.app"
(
    mkdir -p "$temporary_directory/pinned keg/lib" "$temporary_directory/newer/lib"
    touch "$temporary_directory/pinned keg/lib/libexample.1.dylib"
    touch "$temporary_directory/newer/lib/libexample.1.dylib"
    export ILLIQUID_NATIVE_LIBRARY_PATH="$temporary_directory/pinned keg/lib"
    [[ "$(illiquid_pinned_native_library "$temporary_directory/newer/lib/libexample.1.dylib")" \
        = "$temporary_directory/pinned keg/lib/libexample.1.dylib" ]] \
        || fail 'reviewed SDK must take precedence over a moved Homebrew opt link'
    ! illiquid_pinned_native_library '@rpath/missing.dylib' >/dev/null \
        || fail 'missing SDK member must not invent a library'
    unset ILLIQUID_NATIVE_LIBRARY_PATH
    ! illiquid_pinned_native_library '@rpath/libexample.1.dylib' >/dev/null \
        || fail 'explicit toolchain must not inherit automatic SDK selection'
)
illiquid_stage_dmg \
    "$temporary_directory/source/Illiquid.app" \
    "$temporary_directory/staging" \
    || fail 'DMG staging should accept Illiquid.app'
[[ -d "$temporary_directory/staging/Illiquid.app" ]] \
    || fail 'DMG staging should copy Illiquid.app'
[[ -L "$temporary_directory/staging/Applications" ]] \
    || fail 'DMG staging should add the Applications symlink'
[[ "$(readlink "$temporary_directory/staging/Applications")" = /Applications ]] \
    || fail 'Applications symlink should target /Applications'

# Exercise dependency failures without depending on the host's installed SDK.
(
    probe_case=valid
    pkg-config() {
        [[ "$probe_case" != missing ]] || return 1
        if [[ "$1" == --variable=libdir ]]; then
            [[ "$probe_case" != empty-directory ]] || return 0
            printf '/sdk with spaces/lib\n'
        fi
    }
    otool() {
        [[ "$1" == -L && "$2" == '/sdk with spaces/lib/libavfilter.dylib' ]] || return 1
        [[ "$probe_case" != unreadable ]] || return 1
        [[ "$probe_case" != empty-inspection ]] || return 0
        printf 'libavfilter.dylib:\n\t/usr/lib/libSystem.B.dylib\n'
        if [[ "$probe_case" == legacy ]]; then
            printf '\t/System/Library/Frameworks/OpenGL.framework/OpenGL\n'
        fi
    }
    illiquid_verify_ffmpeg_linkage || fail 'valid filter dependencies should pass'
    for probe_case in missing empty-directory unreadable empty-inspection legacy; do
        if illiquid_verify_ffmpeg_linkage 2>/dev/null; then
            fail "FFmpeg preflight accepted $probe_case"
        fi
    done
)

printf 'Illiquid packaging helper tests passed\n'

# Universal frameworks print an image header for each architecture. None of
# those headers is a load command or an external dependency.
(
    otool() {
        cat <<'OTOOL'
Sparkle (architecture x86_64):
	@rpath/Sparkle.framework/Versions/B/Sparkle (compatibility version 1.6.0, current version 2.10.0)
Sparkle (architecture arm64):
	@rpath/Sparkle.framework/Versions/B/Sparkle (compatibility version 1.6.0, current version 2.10.0)
OTOOL
    }
    parsed=$(illiquid_dependencies_for Sparkle)
    [[ "$parsed" = $'@rpath/Sparkle.framework/Versions/B/Sparkle\n@rpath/Sparkle.framework/Versions/B/Sparkle' ]] \
        || fail 'universal architecture headers must not be parsed as dependencies'
)
