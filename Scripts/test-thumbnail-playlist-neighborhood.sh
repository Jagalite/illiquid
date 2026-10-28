#!/usr/bin/env bash
# Compile the unmodified Foundation-only production sources and regression tests.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "$root/.thumbnail-playlist-neighborhood-tests.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Sources/IlliquidCore" "$work/Sources/IlliquidApp" "$work/Tests/IlliquidAppTests"
for file in \
    Playlist/FolderPlaylist.swift \
    Utilities/NaturalFilenameOrdering.swift \
    Utilities/NormalizedFileURL.swift; do
    cp "$root/Sources/IlliquidCore/$file" "$work/Sources/IlliquidCore/"
done
cp "$root/Sources/IlliquidApp/App/ThumbnailPlaylistNeighborhood.swift" "$work/Sources/IlliquidApp/"
cp "$root/Tests/IlliquidAppTests/ThumbnailPlaylistNeighborhoodTests.swift" "$work/Tests/IlliquidAppTests/"
cat > "$work/Package.swift" <<'SWIFT'
// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "IlliquidThumbnailPlaylistNeighborhoodRegressions",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "IlliquidCore"),
        .target(name: "IlliquidApp", dependencies: ["IlliquidCore"]),
        .testTarget(name: "IlliquidAppTests", dependencies: ["IlliquidApp", "IlliquidCore"]),
    ]
)
SWIFT
for configuration in debug release; do
    swift test --package-path "$work" --configuration "$configuration" "$@"
done
