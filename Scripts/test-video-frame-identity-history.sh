#!/usr/bin/env bash
# Compile the actual scalar history and its tests without native renderers.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/illiquid-frame-identity.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/Sources/IlliquidNativePlayback" "$WORK/Tests/IlliquidNativePlaybackTests"
cp "$ROOT/Sources/IlliquidNativePlayback/Presentation/VideoFrameIdentityHistory.swift" \
    "$WORK/Sources/IlliquidNativePlayback/"
cp "$ROOT/Tests/IlliquidNativePlaybackTests/VideoFrameIdentityHistoryTests.swift" \
    "$WORK/Tests/IlliquidNativePlaybackTests/"
cat > "$WORK/Package.swift" <<'PACKAGE'
// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "VideoFrameIdentityHistoryQualification",
    targets: [
        .target(name: "IlliquidNativePlayback"),
        .testTarget(name: "IlliquidNativePlaybackTests", dependencies: ["IlliquidNativePlayback"]),
    ]
)
PACKAGE
swift test --package-path "$WORK" --no-parallel "$@"
