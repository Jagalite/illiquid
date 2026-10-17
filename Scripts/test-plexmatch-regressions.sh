#!/usr/bin/env bash
# Compile the real metadata sources without the native playback dependency graph.
# macOS also exercises real filesystem sidecar reads; Linux runs pure mapping tests.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/illiquid-plexmatch.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Sources/IlliquidCore" "$work/Tests/IlliquidCoreTests"
sources=(MediaNameRecognition MediaMetadataHints PlexMatchHints)
tests=(PlexMatchHintsRegressionTests)
if [[ "$(uname -s)" == Darwin ]]; then
    sources+=(NFOMetadataHints MediaSidecarReader)
    tests+=(MediaSidecarTests PlexMatchReaderRegressionTests)
fi
for file in "${sources[@]}"; do
    cp "$root/Sources/IlliquidCore/MediaLibrary/$file.swift" "$work/Sources/IlliquidCore/"
done
for file in "${tests[@]}"; do
    cp "$root/Tests/IlliquidCoreTests/$file.swift" "$work/Tests/IlliquidCoreTests/"
done
cat > "$work/Package.swift" <<'SWIFT'
// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "IlliquidPlexMatchRegressions", targets: [
    .target(name: "IlliquidCore"),
    .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"])
])
SWIFT
swift test --package-path "$work" "$@"
