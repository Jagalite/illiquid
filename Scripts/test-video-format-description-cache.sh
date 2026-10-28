#!/usr/bin/env bash
# Compile the exact video-format cache and its native CoreMedia regression tests.
# This isolated package has no FFmpeg, app, or downloaded Swift package dependencies.
# Submit this script through Kyoto when that shared queue is available.
set -euo pipefail

if [[ "$(uname -s)" != Darwin ]]; then
    echo 'Video format-description tests require native macOS CoreMedia/CoreVideo.' >&2
    exit 1
fi

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/illiquid-video-format-cache.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Sources/IlliquidNativePlayback" "$work/Tests/IlliquidNativePlaybackTests"

source="$root/Sources/IlliquidNativePlayback/Presentation/VideoFormatDescriptionCache.swift"
tests="$root/Tests/IlliquidNativePlaybackTests/VideoFormatDescriptionCacheTests.swift"
cp "$source" "$work/Sources/IlliquidNativePlayback/"
cp "$tests" "$work/Tests/IlliquidNativePlaybackTests/"
cmp "$source" "$work/Sources/IlliquidNativePlayback/VideoFormatDescriptionCache.swift"
cmp "$tests" "$work/Tests/IlliquidNativePlaybackTests/VideoFormatDescriptionCacheTests.swift"
shasum -a 256 "$source" "$tests"

cat > "$work/Package.swift" <<'SWIFT'
// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "VideoFormatDescriptionCacheRegressions",
    platforms: [.macOS("26.0")],
    targets: [
        .target(
            name: "IlliquidNativePlayback",
            linkerSettings: [
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
            ]
        ),
        .testTarget(
            name: "IlliquidNativePlaybackTests",
            dependencies: ["IlliquidNativePlayback"]
        ),
    ]
)
SWIFT

swift test --package-path "$work" --no-parallel "$@"
