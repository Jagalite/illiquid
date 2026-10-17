#!/usr/bin/env bash
# Exercise the production ordering helper and repository regressions in an
# isolated package. Native scanner integration is covered separately on macOS.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/illiquid-source-presence.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Sources/IlliquidApp" "$work/Tests/IlliquidAppTests"
cp "$root/Sources/IlliquidApp/UI/SourceMediaPresenceRecomputation.swift" "$work/Sources/IlliquidApp/"
cp "$root/Tests/IlliquidAppTests/SourceMediaPresenceRecomputationTests.swift" "$work/Tests/IlliquidAppTests/"
cat > "$work/Package.swift" <<'SWIFT'
// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "SourcePresenceRegressions", targets: [
    .target(name: "IlliquidApp"),
    .testTarget(name: "IlliquidAppTests", dependencies: ["IlliquidApp"])
])
SWIFT
swift test --package-path "$work" "$@"
