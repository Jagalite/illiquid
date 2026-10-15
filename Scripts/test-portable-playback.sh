#!/usr/bin/env bash
# Build the actual deterministic sources and tests without the Apple/native graph.
# Uses the toolchain's Testing module; macOS CI also checks the pinned app graph.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/illiquid-portable.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Sources" "$work/Tests"
for target in IlliquidCore IlliquidPlaybackCore IlliquidPlaybackStateSpace; do
    cp -R "$root/Sources/$target" "$work/Sources/"
    cp -R "$root/Tests/${target}Tests" "$work/Tests/"
done
# Catalog sidecar scanning uses Darwin file-descriptor APIs, outside this harness.
rm -rf "$work/Sources/IlliquidCore/MediaLibrary"
rm "$work/Tests/IlliquidCoreTests/MediaSidecarTests.swift" \
   "$work/Tests/IlliquidCoreTests/MediaNameRecognitionTests.swift"
# UI observation stays in the native target; it is not playback policy.
rm "$work/Sources/IlliquidCore/Player/PlaybackState.swift" \
   "$work/Sources/IlliquidCore/Player/PlaybackViewStore.swift" \
   "$work/Tests/IlliquidCoreTests/PlaybackStateTests.swift"
cat > "$work/Package.swift" <<'SWIFT'
// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "IlliquidPortablePlayback", platforms: [.macOS("26.0")], targets: [
    .target(name: "IlliquidCore"),
    .target(name: "IlliquidPlaybackCore", dependencies: ["IlliquidCore"]),
    .target(name: "IlliquidPlaybackStateSpace", dependencies: ["IlliquidPlaybackCore"]),
    .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"]),
    .testTarget(name: "IlliquidPlaybackCoreTests", dependencies: ["IlliquidPlaybackCore"]),
    .testTarget(name: "IlliquidPlaybackStateSpaceTests", dependencies: ["IlliquidPlaybackStateSpace"])
])
SWIFT
swift test --package-path "$work" --no-parallel "$@"
