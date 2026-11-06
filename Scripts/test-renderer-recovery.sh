#!/usr/bin/env bash
# Exercise the actual production playback model without native macOS SDKs.
# This does not qualify native rendering, hardware decoding, or visible playback.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/illiquid-recovery.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Sources/IlliquidCore" "$work/Sources/IlliquidPlaybackModel" \
    "$work/Tests/IlliquidPlaybackModelTests"
cp "$root/Sources/IlliquidCore/Player/MediaTrack.swift" "$work/Sources/IlliquidCore/"
cp "$root/Sources/IlliquidPlaybackModel/"*.swift "$work/Sources/IlliquidPlaybackModel/"
cp "$root/Tests/IlliquidPlaybackModelTests/RendererRecoveryRegressionTests.swift" \
    "$root/Tests/IlliquidPlaybackModelTests/ModelTestSupport.swift" \
    "$work/Tests/IlliquidPlaybackModelTests/"
revision=$(sed -n '/Jagalite\/statelessness.git/{n;s/.*revision: "\([0-9a-f]*\)".*/\1/p;}' "$root/Package.swift")
[[ -n "$revision" ]] || { echo "Statelessness revision not found in Package.swift" >&2; exit 1; }
cat > "$work/Package.swift" <<SWIFT
// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "IlliquidRendererRecoveryRegressions", platforms: [.macOS("26.0")],
  dependencies: [.package(url: "https://github.com/Jagalite/statelessness.git", revision: "$revision")],
  targets: [
    .target(name: "IlliquidCore"),
    .target(name: "IlliquidPlaybackModel", dependencies: [
        "IlliquidCore", .product(name: "Statelessness", package: "statelessness")]),
    .testTarget(name: "IlliquidPlaybackModelTests", dependencies: [
        "IlliquidPlaybackModel", .product(name: "Statelessness", package: "statelessness")])
])
SWIFT
swift test --package-path "$work" --no-parallel "$@"
