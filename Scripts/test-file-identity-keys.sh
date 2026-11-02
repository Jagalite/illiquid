#!/usr/bin/env bash
# Compile exact production sources and tests without the player SDK dependencies.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/illiquid-file-identity.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Sources/IlliquidCore" "$work/Tests/IlliquidCoreTests"
export CLANG_MODULE_CACHE_PATH="$work/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$work/module-cache"

for source in \
    Utilities/NormalizedFileURL.swift \
    Utilities/NaturalFilenameOrdering.swift \
    Utilities/MediaFileSupport.swift \
    Playlist/FolderPlaylist.swift \
    Player/MediaSource.swift; do
    destination="$work/Sources/IlliquidCore/$(basename "$source")"
    if [[ -n "${ILLIQUID_KEY_SOURCE_REVISION:-}" ]]; then
        git -C "$root" show "$ILLIQUID_KEY_SOURCE_REVISION:Sources/IlliquidCore/$source" > "$destination"
    else
        cp "$root/Sources/IlliquidCore/$source" "$destination"
    fi
done
for test in \
    NormalizedFileURLPersistenceKeyTests.swift \
    LocalMediaSourceValidationTests.swift \
    UtilitiesTests.swift \
    FolderPlaylistTests.swift \
    FolderPlaylistLookupTests.swift; do
    cp "$root/Tests/IlliquidCoreTests/$test" "$work/Tests/IlliquidCoreTests/"
done

cat > "$work/Package.swift" <<'SWIFT'
// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "IlliquidFileIdentityRegressions",
    targets: [
        .target(name: "IlliquidCore"),
        .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"]),
    ]
)
SWIFT

for configuration in debug release; do
    swift test --package-path "$work" --configuration "$configuration" \
        --cache-path "$work/package-cache" --config-path "$work/package-config" \
        --security-path "$work/package-security" \
        --no-parallel -Xswiftc -warnings-as-errors "$@"
done
