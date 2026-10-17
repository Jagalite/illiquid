#!/usr/bin/env bash
# Run selected, real Foundation-only sources without resolving native macOS SDKs
# or the app's dependency graph. This is NOT the full application test suite.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/illiquid-regressions.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Sources/IlliquidCore" "$work/Tests/IlliquidCoreTests"
for file in \
    Player/MediaTrack.swift \
    Player/ThumbnailPolicy.swift \
    Player/ThumbnailPassCursor.swift \
    Player/ThumbnailVisibilityPolicy.swift \
    Persistence/MediaPlaybackSettings.swift \
    Persistence/LegacyPreferencesMigration.swift \
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
    TrackRestorationRegressionTests \
    InterruptedMigrationRegressionTests \
    ThumbnailSchedulingPolicyRegressionTests \
    ExternalSubtitleMatcherTests \
    FolderPlaylistDiscoveryTests \
    FolderPlaylistTests \
    PlaylistMutationTests \
    TestSupport/TemporaryDirectory; do
    cp "$root/Tests/IlliquidCoreTests/$file.swift" "$work/Tests/IlliquidCoreTests/"
done
cat > "$work/Package.swift" <<'SWIFT'
// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "IlliquidRestorationRegressions",
    // Match the app manifest: the copied sources use Swift concurrency APIs.
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "IlliquidCore"),
        .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"])
    ]
)
SWIFT
swift test --package-path "$work" "$@"
