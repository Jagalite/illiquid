#!/usr/bin/env bash
# Run the existing exhaustive oracle and singleton representation regression.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "$root/.thumbnail-singleton-tests.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Sources/IlliquidCore" "$work/Sources/IlliquidApp" "$work/Tests/IlliquidAppTests"
for file in \
    Playlist/FolderPlaylist.swift \
    Utilities/NaturalFilenameOrdering.swift \
    Utilities/NormalizedFileURL.swift; do
    cp "$root/Sources/IlliquidCore/$file" "$work/Sources/IlliquidCore/"
done
if [[ -n "${ILLIQUID_SINGLETON_HELPER_REF:-}" ]]; then
    git -C "$root" show "$ILLIQUID_SINGLETON_HELPER_REF:Sources/IlliquidApp/App/ThumbnailPlaylistNeighborhood.swift" \
        > "$work/Sources/IlliquidApp/ThumbnailPlaylistNeighborhood.swift"
else
    cp "$root/Sources/IlliquidApp/App/ThumbnailPlaylistNeighborhood.swift" "$work/Sources/IlliquidApp/"
fi
for file in ThumbnailPlaylistNeighborhoodTests.swift ThumbnailSingletonNeighborhoodTests.swift; do
    cp "$root/Tests/IlliquidAppTests/$file" "$work/Tests/IlliquidAppTests/"
done
cat > "$work/Package.swift" <<'SWIFT'
// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "IlliquidThumbnailSingletonRegressions",
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
