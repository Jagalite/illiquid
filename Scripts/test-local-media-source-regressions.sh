#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/illiquid-local-media-source.XXXXXX")"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/Sources/IlliquidCore" "$work/Tests/IlliquidCoreTests"
cp "$root/Sources/IlliquidCore/Utilities/NormalizedFileURL.swift" "$work/Sources/IlliquidCore/"
cp "$root/Sources/IlliquidCore/Player/MediaSource.swift" "$work/Sources/IlliquidCore/"
cp "$root/Tests/IlliquidCoreTests/LocalMediaSourceValidationTests.swift" "$work/Tests/IlliquidCoreTests/"
cp "$root/Tests/IlliquidCoreTests/NormalizedFileURLPersistenceKeyTests.swift" "$work/Tests/IlliquidCoreTests/"

# Compile unchanged production files and repository tests without the app's
# native dependencies. The toolchain's bundled Testing module is sufficient.
cat > "$work/Package.swift" <<'PACKAGE'
// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "LocalMediaSourceRegressions",
    targets: [
        .target(name: "IlliquidCore"),
        .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"]),
    ]
)
PACKAGE

swift test --package-path "$work" "$@"
