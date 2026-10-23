#!/usr/bin/env bash
# Compile the actual filesystem-event policy and repository tests, without
# AppKit/FSEvents or the native player dependency graph. Not a full app test.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/illiquid-source-filesystem.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Sources/IlliquidApp" "$work/Tests/IlliquidAppTests"
cp "$root/Sources/IlliquidApp/UI/SourceFilesystemInvalidation.swift" "$work/Sources/IlliquidApp/"
for file in SourceFilesystemMonitorTests SourceFilesystemRootRegressionTests SourceFilesystemPlanningTests; do
    cp "$root/Tests/IlliquidAppTests/$file.swift" "$work/Tests/IlliquidAppTests/"
done
cat > "$work/Package.swift" <<'SWIFT'
// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "SourceFilesystemRegressions", targets: [
    .target(name: "IlliquidApp"),
    .testTarget(name: "IlliquidAppTests", dependencies: ["IlliquidApp"])
])
SWIFT
swift test --package-path "$work" "$@"
