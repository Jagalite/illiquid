#!/usr/bin/env bash
# Run the real Foundation-only playlist, sorting, identity and discovery sources.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
baseline="33fff16155c3472960f88e04c72dfdfdefd56dcf"
variant="candidate"
if [[ "${1:-}" == "--baseline" ]]; then
    variant="baseline"
    shift
fi
work="$(mktemp -d "${TMPDIR:-/tmp}/illiquid-prepared-playlist-tests.XXXXXX")"
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
    if [[ "$variant" == "baseline" ]]; then
        git -C "$root" show "$baseline:Sources/IlliquidCore/$file" \
            > "$work/Sources/IlliquidCore/$(basename "$file")"
    else
        cp "$root/Sources/IlliquidCore/$file" "$work/Sources/IlliquidCore/"
    fi
done
for file in \
    PreparedPlaylistConstructionTests.swift \
    NaturalFilenameOrderingTests.swift \
    UtilitiesTests.swift \
    FolderPlaylistTests.swift \
    FolderPlaylistLookupTests.swift \
    FolderPlaylistDiscoveryTests.swift \
    FolderDiscoveryFilesystemRegressionTests.swift \
    ExternalSubtitleMatcherTests.swift \
    ExternalSubtitleMatcherEmptyTests.swift \
    PlaylistMutationTests.swift \
    PlaylistOrderRestorationTests.swift \
    PlaylistIdentityLookupTests.swift \
    TestSupport/TemporaryDirectory.swift; do
    cp "$root/Tests/IlliquidCoreTests/$file" "$work/Tests/IlliquidCoreTests/"
done
cat > "$work/Package.swift" <<'SWIFT'
// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "IlliquidPreparedPlaylistConstructionTests",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "IlliquidCore"),
        .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"]),
    ]
)
SWIFT
export CLANG_MODULE_CACHE_PATH="$work/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$work/module-cache"
swift test --package-path "$work" --scratch-path "$work/build" \
    --cache-path "$work/cache" --config-path "$work/config" \
    --security-path "$work/security" "$@"
