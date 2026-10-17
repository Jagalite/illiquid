#!/usr/bin/env bash
# Exercise the actual deterministic playback core without native macOS SDKs.
# This does not qualify native rendering, hardware decoding, or visible playback.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/illiquid-recovery.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Sources/IlliquidCore" "$work/Sources/IlliquidPlaybackCore" \
    "$work/Tests/IlliquidPlaybackCoreTests"
cp "$root/Sources/IlliquidCore/Player/MediaTrack.swift" "$work/Sources/IlliquidCore/"
cp "$root/Sources/IlliquidPlaybackCore/"*.swift "$work/Sources/IlliquidPlaybackCore/"
cp "$root/Tests/IlliquidPlaybackCoreTests/"*.swift "$work/Tests/IlliquidPlaybackCoreTests/"
cat > "$work/Package.swift" <<'SWIFT'
// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "IlliquidRendererRecoveryRegressions", targets: [
    .target(name: "IlliquidCore"),
    .target(name: "IlliquidPlaybackCore", dependencies: ["IlliquidCore"]),
    .testTarget(name: "IlliquidPlaybackCoreTests", dependencies: ["IlliquidPlaybackCore"])
])
SWIFT
swift test --package-path "$work" --no-parallel "$@"
