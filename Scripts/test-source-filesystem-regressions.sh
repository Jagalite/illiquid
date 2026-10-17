#!/usr/bin/env bash
# Compile the real Foundation-only planner and its repository tests unchanged.
# This does not build the macOS app or simulate the native FSEvents stream.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/illiquid-source-filesystem.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Sources/IlliquidApp" "$work/Tests/IlliquidAppTests"
cp "$root/Sources/IlliquidApp/UI/SourceFilesystemInvalidationPlanner.swift" \
    "$work/Sources/IlliquidApp/"
for file in SourceFilesystemMonitorTests SourceFilesystemRecoveryTests; do
    cp "$root/Tests/IlliquidAppTests/$file.swift" "$work/Tests/IlliquidAppTests/"
done
cat > "$work/Package.swift" <<'SWIFT'
// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "IlliquidSourceFilesystemRegressions", targets: [
    .target(name: "IlliquidApp"),
    .testTarget(name: "IlliquidAppTests", dependencies: ["IlliquidApp"])
])
SWIFT
swift test --package-path "$work" "$@"
