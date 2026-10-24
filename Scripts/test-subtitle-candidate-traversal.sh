#!/usr/bin/env bash
# Compile the unchanged production matcher dependencies in an isolated package.
# These component tests do not build the native player or exercise playback.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/illiquid-subtitle-candidates.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Sources/IlliquidCore" "$work/Tests/IlliquidCoreTests"
for file in Playlist/ExternalSubtitleMatcher.swift Utilities/MediaFileSupport.swift \
    Utilities/NaturalFilenameOrdering.swift; do
    cp "$root/Sources/IlliquidCore/$file" "$work/Sources/IlliquidCore/"
done
for file in ExternalSubtitleMatcherTests ExternalSubtitleMatcherEmptyTests \
    ExternalSubtitleTokenizationTests ExternalSubtitleCandidateTraversalTests; do
    cp "$root/Tests/IlliquidCoreTests/$file.swift" "$work/Tests/IlliquidCoreTests/"
done
cat > "$work/Package.swift" <<'SWIFT'
// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "SubtitleCandidateTraversalQualification",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "IlliquidCore"),
        .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"])
    ]
)
SWIFT
export CLANG_MODULE_CACHE_PATH="$work/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$work/swift-cache"
swift test --package-path "$work" "$@"
