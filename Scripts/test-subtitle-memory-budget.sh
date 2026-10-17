#!/usr/bin/env bash
# Exercise the actual Foundation-only budget source and its regular package
# tests on Linux or macOS without resolving the native playback dependencies.
# This checks memory bookkeeping; it does not run the native player or renderer.
set -euo pipefail

illiquid_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_workspace="$(mktemp -d "${TMPDIR:-/tmp}/illiquid-subtitle-memory-budget.XXXXXX")"
trap 'rm -rf "$test_workspace"' EXIT

mkdir -p "$test_workspace/Sources/IlliquidNativePlayback" \
    "$test_workspace/Tests/IlliquidNativePlaybackTests"
cp "$illiquid_root/Sources/IlliquidNativePlayback/Subtitles/SubtitleMemoryBudget.swift" \
    "$test_workspace/Sources/IlliquidNativePlayback/"
cp "$illiquid_root/Tests/IlliquidNativePlaybackTests/SubtitleMemoryBudgetAccountingTests.swift" \
    "$test_workspace/Tests/IlliquidNativePlaybackTests/"
cat > "$test_workspace/Package.swift" <<'SWIFT'
// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "IlliquidSubtitleMemoryBudgetTests",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "IlliquidNativePlayback"),
        .testTarget(name: "IlliquidNativePlaybackTests", dependencies: ["IlliquidNativePlayback"]),
    ]
)
SWIFT

swift test --package-path "$test_workspace" "$@"
