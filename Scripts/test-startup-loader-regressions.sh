#!/usr/bin/env bash
# Exercise the production startup loader and its coalescing/lifetime tests
# without resolving the native macOS application graph. This is not an app test.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/illiquid-startup-regressions.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Sources/IlliquidApp" "$work/Tests/IlliquidAppTests"
cp "$root/Sources/IlliquidApp/App/ReadOnlyStartupLoader.swift" "$work/Sources/IlliquidApp/"
cp "$root/Tests/IlliquidAppTests/ReadOnlyStartupLoaderTests.swift" "$work/Tests/IlliquidAppTests/"
cat > "$work/Package.swift" <<'SWIFT'
// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "IlliquidStartupLoaderRegressions", platforms: [.macOS("26.0")], targets: [
    .target(name: "IlliquidApp"),
    .testTarget(name: "IlliquidAppTests", dependencies: ["IlliquidApp"])
])
SWIFT
swift test --package-path "$work" "$@"
