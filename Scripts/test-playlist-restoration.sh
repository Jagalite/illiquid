#!/usr/bin/env bash
# Test the production playlist sources without building macOS playback adapters.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/illiquid-playlist-restoration.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/Sources/IlliquidCore" "$WORK/Tests/IlliquidCoreTests"
for path in Playlist/FolderPlaylist.swift Playlist/PlaylistMutation.swift \
    Utilities/NormalizedFileURL.swift Utilities/NaturalFilenameOrdering.swift; do
    cp "$ROOT/Sources/IlliquidCore/$path" "$WORK/Sources/IlliquidCore/"
done
for name in PlaylistMutationTests PlaylistOrderRestorationTests PlaylistRestoredIdentityTests \
    NaturalFilenameOrderingTests FolderPlaylistTests; do
    cp "$ROOT/Tests/IlliquidCoreTests/$name.swift" "$WORK/Tests/IlliquidCoreTests/"
done
cat > "$WORK/Package.swift" <<'PACKAGE'
// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "PlaylistRestorationQualification",
    targets: [
        .target(name: "IlliquidCore"),
        .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"]),
    ]
)
PACKAGE
swift test --package-path "$WORK" --no-parallel "$@"
