#!/usr/bin/env bash
# Exercise the unchanged production writer and its lifetime/ordering tests without
# resolving the native macOS application graph. This is not a full app test run.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/illiquid-persistence-regressions.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Sources/IlliquidCore" "$work/Tests/IlliquidCoreTests"
cp "$root/Sources/IlliquidCore/Persistence/CoalescingPersistenceWriter.swift" "$work/Sources/IlliquidCore/"
cp "$root/Tests/IlliquidCoreTests/PersistenceWriterLifetimeTests.swift" "$work/Tests/IlliquidCoreTests/"
cat > "$work/Package.swift" <<'SWIFT'
// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "IlliquidPersistenceWriterRegressions", targets: [
    .target(name: "IlliquidCore"),
    .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"])
])
SWIFT
swift test --package-path "$work" "$@"
