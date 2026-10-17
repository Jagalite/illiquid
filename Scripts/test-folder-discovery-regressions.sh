#!/usr/bin/env bash
# Runs real Foundation-only sources, not the native app or playback graph.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/illiquid-folder-discovery.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Sources/IlliquidCore" "$work/Tests/IlliquidCoreTests"
for file in \
    Playlist/ExternalSubtitleMatcher.swift \
    Playlist/FolderPlaylist.swift \
    Playlist/FolderPlaylistDiscovery.swift \
    Playlist/PlaylistMutation.swift \
    Utilities/MediaFileSupport.swift \
    Utilities/NaturalFilenameOrdering.swift \
    Utilities/NormalizedFileURL.swift; do
    cp "$root/Sources/IlliquidCore/$file" "$work/Sources/IlliquidCore/"
done
for file in \
    FolderPlaylistDiscoveryTests.swift \
    FolderDiscoveryFilesystemRegressionTests.swift \
    TestSupport/TemporaryDirectory.swift; do
    cp "$root/Tests/IlliquidCoreTests/$file" "$work/Tests/IlliquidCoreTests/"
done
cat > "$work/Package.swift" <<'SWIFT'
// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "IlliquidFolderDiscoveryRegressions",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "IlliquidCore"),
        .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"]),
    ]
)
SWIFT
swift test --package-path "$work" "$@"
