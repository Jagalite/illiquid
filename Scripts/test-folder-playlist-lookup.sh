#!/usr/bin/env bash
# Isolated Foundation-only regression slice, using unmodified production/tests.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "$root/.folder-playlist-lookup-tests.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Sources/IlliquidCore" "$work/Tests/IlliquidCoreTests"
for file in \
    Playlist/FolderPlaylist.swift \
    Utilities/NaturalFilenameOrdering.swift \
    Utilities/NormalizedFileURL.swift \
    Utilities/MediaFileSupport.swift; do
    if [[ -n "${ILLIQUID_LOOKUP_SOURCE_REVISION:-}" ]]; then
        git -C "$root" show "$ILLIQUID_LOOKUP_SOURCE_REVISION:Sources/IlliquidCore/$file" \
            > "$work/Sources/IlliquidCore/$(basename "$file")"
    else
        cp "$root/Sources/IlliquidCore/$file" "$work/Sources/IlliquidCore/"
    fi
done
for file in UtilitiesTests.swift FolderPlaylistTests.swift FolderPlaylistLookupTests.swift; do
    cp "$root/Tests/IlliquidCoreTests/$file" "$work/Tests/IlliquidCoreTests/"
done
cat > "$work/Package.swift" <<'SWIFT'
// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "IlliquidFolderPlaylistLookupRegressions",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "IlliquidCore"),
        .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"]),
    ]
)
SWIFT
for configuration in debug release; do
    swift test --package-path "$work" --configuration "$configuration" "$@"
done
