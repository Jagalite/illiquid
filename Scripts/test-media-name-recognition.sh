#!/usr/bin/env bash
# Run the actual Foundation-only filename recognizer and its package tests
# without resolving the macOS playback dependencies.
set -euo pipefail

illiquid_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_workspace="$(mktemp -d "${TMPDIR:-/tmp}/illiquid-media-name-recognition.XXXXXX")"
trap 'rm -rf "$test_workspace"' EXIT

mkdir -p "$test_workspace/Sources/IlliquidCore" \
    "$test_workspace/Tests/IlliquidCoreTests"
cp "$illiquid_root/Sources/IlliquidCore/MediaLibrary/MediaNameRecognition.swift" \
    "$test_workspace/Sources/IlliquidCore/"
cp "$illiquid_root"/Tests/IlliquidCoreTests/MediaNameRecognition*Tests.swift \
    "$test_workspace/Tests/IlliquidCoreTests/"
cat > "$test_workspace/Package.swift" <<'SWIFT'
// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "IlliquidMediaNameRecognitionTests",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "IlliquidCore"),
        .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"]),
    ]
)
SWIFT

swift test --package-path "$test_workspace" "$@"
