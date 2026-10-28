#!/usr/bin/env bash
# Compile the complete production monitor and focused tests on macOS, without
# the unrelated native media dependency graph. This includes real FSEvents QA.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/illiquid-filesystem-handoff.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Sources/IlliquidCore" "$work/Sources/IlliquidApp" "$work/Tests/IlliquidAppTests"
cp "$root/Sources/IlliquidCore/Utilities/LifecyclePerformance.swift" "$work/Sources/IlliquidCore/"
for file in SourceFilesystemMonitor SourceFilesystemInvalidation SourceFilesystemEventMailbox SourceVolumeChangePolicy; do
    cp "$root/Sources/IlliquidApp/UI/$file.swift" "$work/Sources/IlliquidApp/"
done
for file in SourceFilesystemLifecycleTests SourceFilesystemEventMailboxTests SourceFilesystemHandoffTests SourceFilesystemEventBufferTests SourceFilesystemMonitorTests SourceFilesystemEventLossTests SourceFilesystemRootRegressionTests SourceFilesystemPlanningTests SourceVolumeChangePolicyTests; do
    cp "$root/Tests/IlliquidAppTests/$file.swift" "$work/Tests/IlliquidAppTests/"
done
cat > "$work/Package.swift" <<'SWIFT'
// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "FilesystemHandoff", platforms: [.macOS("26.0")], targets: [
    .target(name: "IlliquidCore"),
    .target(name: "IlliquidApp", dependencies: ["IlliquidCore"]),
    .testTarget(name: "IlliquidAppTests", dependencies: ["IlliquidApp"])
])
SWIFT
swift test --package-path "$work" --no-parallel "$@"
