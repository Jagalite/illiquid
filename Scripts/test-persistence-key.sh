#!/usr/bin/env bash
# Compile real identity, playlist, tab and persistence sources without resolving
# the app's native playback graph. Invoke through Kyoto when available (AGENTS.md).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/illiquid-persistence-key-tests.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Sources/IlliquidCore" "$work/Tests/IlliquidCoreTests"

key_source_revision=""
if [[ -n "${ILLIQUID_KEY_SOURCE_REVISION:-}" ]]; then
    key_source_revision="$(git -C "$root" rev-parse --verify --end-of-options \
        "${ILLIQUID_KEY_SOURCE_REVISION}^{commit}")"
fi

# Keep the complete dependency files: no replacement models, extracted types or
# normalizer stubs. A baseline run changes production sources only; it exercises
# the same current regression tests as the candidate.
for file in \
    Utilities/NormalizedFileURL.swift \
    Utilities/NaturalFilenameOrdering.swift \
    Utilities/MediaFileSupport.swift \
    Utilities/NonDecodePerformance.swift \
    Playlist/FolderPlaylist.swift \
    Playlist/PlaylistMutation.swift \
    Player/MediaSource.swift \
    Player/OpenVideoTabs.swift \
    Player/MediaTrack.swift \
    Player/PlaybackModels.swift \
    Player/PlaybackPhase.swift \
    Player/VideoPresentationGeometry.swift \
    Player/TrackSelectionPreferences.swift \
    Player/SubtitleFallbackEncoding.swift \
    Persistence/CoalescingPersistenceWriter.swift \
    Persistence/MediaContentVersion.swift \
    Persistence/MediaPlaybackSettings.swift \
    Persistence/PlaybackPersistenceStore.swift \
    Persistence/PlaybackPreferences.swift \
    Persistence/PlaybackRestoreTarget.swift; do
    if [[ -n "$key_source_revision" ]]; then
        git -C "$root" show "$key_source_revision:Sources/IlliquidCore/$file" \
            > "$work/Sources/IlliquidCore/$(basename "$file")"
    else
        cp "$root/Sources/IlliquidCore/$file" "$work/Sources/IlliquidCore/"
    fi
done

for file in \
    NormalizedFileURLPersistenceKeyTests.swift \
    LocalMediaSourceValidationTests.swift \
    UtilitiesTests.swift \
    NaturalFilenameOrderingTests.swift \
    FolderPlaylistTests.swift \
    FolderPlaylistLookupTests.swift \
    PlaylistIdentityLookupTests.swift \
    PlaylistMutationTests.swift \
    PlaylistDeduplicationTests.swift \
    PlaylistSortingTests.swift \
    PlaylistOrderRestorationTests.swift \
    OpenVideoTabsTests.swift \
    OpenVideoTabResourceIndexTests.swift \
    PlaybackPersistenceStoreTests.swift \
    HistoryPolicyTests.swift \
    MediaContentVersionTests.swift \
    IdempotentPersistenceTests.swift; do
    cp "$root/Tests/IlliquidCoreTests/$file" "$work/Tests/IlliquidCoreTests/"
done

# Swift Testing and XCTest are supplied by the native Swift toolchain. These
# sources use Foundation, CoreGraphics and os; no app/native-media dependencies.
cat > "$work/Package.swift" <<'SWIFT'
// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "IlliquidPersistenceKeyRegressions",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "IlliquidCore"),
        .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"]),
    ]
)
SWIFT

if [[ ! -f /Volumes/seed1/Projects/kyoto/kyoto.py ]]; then
    printf '%s\n' 'Kyoto is unavailable on this host; compiling the isolated regression package directly.'
fi
for configuration in debug release; do
    printf 'Persistence-key tests: sources=%s configuration=%s\n' \
        "${key_source_revision:-working-tree}" "$configuration"
    # Configurations share only this invocation's fresh package and build serially.
    swift test --package-path "$work" --configuration "$configuration" --no-parallel "$@"
done
