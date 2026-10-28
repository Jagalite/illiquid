#!/usr/bin/env bash
# Exercise the real text converter without resolving macOS playback SDKs.
# Native file decoding, byte limits, and error mapping run in the app test suite.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/illiquid-subtitle-regressions.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Sources/IlliquidNativePlayback" "$work/Tests/IlliquidNativePlaybackTests"
cp "$root/Sources/IlliquidNativePlayback/Subtitles/ExternalTextSubtitleConverter.swift" \
    "$work/Sources/IlliquidNativePlayback/"
cp "$root/Tests/IlliquidNativePlaybackTests/ExternalTextSubtitleConverterTests.swift" \
    "$root/Tests/IlliquidNativePlaybackTests/ExternalSubtitleEscapingTests.swift" \
    "$root/Tests/IlliquidNativePlaybackTests/ExternalSubtitleTimestampTests.swift" \
    "$work/Tests/IlliquidNativePlaybackTests/"
cat > "$work/Package.swift" <<'SWIFT'
// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "IlliquidExternalSubtitleRegressions", targets: [
    .target(name: "IlliquidNativePlayback"),
    .testTarget(name: "IlliquidNativePlaybackTests", dependencies: ["IlliquidNativePlayback"])
])
SWIFT
swift test --package-path "$work" "$@"
