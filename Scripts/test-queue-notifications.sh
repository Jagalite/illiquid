#!/usr/bin/env bash
# Compile the actual Foundation-only queue/router and focused package tests
# without FFmpeg, renderers, or the macOS app. Keep each build isolated.
set -euo pipefail

illiquid_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_workspace="$(mktemp -d "${TMPDIR:-/tmp}/illiquid-queue-notifications.XXXXXX")"
trap 'rm -rf "$test_workspace"' EXIT

mkdir -p "$test_workspace/Sources/IlliquidNativePlayback" \
    "$test_workspace/Tests/IlliquidNativePlaybackTests"
cp "${ILLIQUID_PACKET_QUEUE_SOURCE:-$illiquid_root/Sources/IlliquidNativePlayback/Playback/PacketQueue.swift}" \
    "$test_workspace/Sources/IlliquidNativePlayback/PacketQueue.swift"
cp "$illiquid_root/Sources/IlliquidNativePlayback/Playback/FixedRingBuffer.swift" \
    "$test_workspace/Sources/IlliquidNativePlayback/"
cp "$illiquid_root/Tests/IlliquidNativePlaybackTests/QueueNotificationTests.swift" \
    "$illiquid_root/Tests/IlliquidNativePlaybackTests/PacketQueueWakeupTests.swift" \
    "$test_workspace/Tests/IlliquidNativePlaybackTests/"
cat > "$test_workspace/Package.swift" <<'SWIFT'
// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "IlliquidQueueNotificationTests",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "IlliquidNativePlayback"),
        .testTarget(name: "IlliquidNativePlaybackTests", dependencies: ["IlliquidNativePlayback"]),
    ]
)
SWIFT

swift test --package-path "$test_workspace" "$@"
