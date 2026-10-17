#!/usr/bin/env bash
# Test the unchanged production utility files without the native playback graph.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/illiquid-natural-filename-ordering.XXXXXX")"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/Sources/IlliquidCore" "$work/Tests/IlliquidCoreTests"
for file in NaturalFilenameOrdering NormalizedFileURL MediaFileSupport; do
    cp "$root/Sources/IlliquidCore/Utilities/$file.swift" "$work/Sources/IlliquidCore/"
done
for file in NaturalFilenameOrderingTests UtilitiesTests; do
    cp "$root/Tests/IlliquidCoreTests/$file.swift" "$work/Tests/IlliquidCoreTests/"
done

cat > "$work/Package.swift" <<'SWIFT'
// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "IlliquidNaturalFilenameOrderingRegressions",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "IlliquidCore"),
        .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"]),
    ]
)
SWIFT

swift test --package-path "$work" --no-parallel "$@"
