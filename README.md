# Illiquid

Illiquid is a native macOS media player built with SwiftUI, AppKit, FFmpeg,
VideoToolbox, Apple sample-buffer renderers, and libass. It supports local files
and folder playlists, tracks and subtitles, crash-safe resume, HDR/EDR display
policy, Now Playing/media keys, and system Picture in Picture.

## Download

Get the Apple Silicon DMG from [GitHub Releases](https://github.com/Jagalite/illiquid/releases).
Requires macOS 26 or later. Current releases are **ad hoc signed, unnotarized
prereleases**; macOS may block downloaded copies. Notarization is planned later.

## Build and run

Requirements: macOS 26, full Xcode, Homebrew, FFmpeg, libass, and pkg-config.
Packaging enforces the exact native versions/hashes in the dependency lock;
current Homebrew versions may differ. See the pinned CI inputs in
[DISTRIBUTING.md](DISTRIBUTING.md).

```sh
brew install ffmpeg libass pkg-config
swift run Illiquid
# Validate the architecture separately:
swift run IlliquidArchitectureCheck
swift test --no-parallel
./Scripts/build-local-dmg.sh
open dist/Illiquid.app
```

See [DISTRIBUTING.md](DISTRIBUTING.md) for release packaging
and [Documentation/MANUAL_PLAYBACK_CHECKLIST.md](Documentation/MANUAL_PLAYBACK_CHECKLIST.md)
for physical-device playback QA.

The [living findings register](Documentation/ROBUSTNESS_REVIEW_MPV_IINA.md)
tracks structural, robustness, and user-experience research against mpv and IINA.

Use **⌘+** and **⌘−** to resize the interface, and **⌘0** to reset it to 100%.
The scale is remembered across launches and can also be selected in
**Settings → Appearance → UI Scale** (80–150%, in 10% steps).

Double-click or double-tap the video’s left third to seek backward 5 seconds,
or the right third to seek forward 5 seconds. Double-click the center third to
toggle fullscreen. Trackpad taps require macOS **Tap to click** to be enabled.
After a side double-tap, each additional rapid tap seeks another 5 seconds.

## Architecture

- `IlliquidPlaybackCore` is the deterministic imperative playback authority.
  It owns transitions, effect identity, seeks, drains, recovery, lifecycle,
  synchronization, track intent, and subtitle/control state.
- `IlliquidNativePlayback` executes those decisions through FFmpeg,
  VideoToolbox, AVSampleBuffer renderers, and libass. Generation fences and
  leases reject stale work and separate logical invalidation from cleanup.
- `IlliquidPlayer` coordinates product commands, persistence, and immutable
  runtime snapshots. It constructs the native runtime directly.
- `IlliquidApp` is the reactive SwiftUI/AppKit shell. It observes
  `PlaybackViewStore` and does not own playback truth.

The Swift package, executable, modules, and installed app are named Illiquid. The macOS bundle identifier is `io.github.jagalite.illiquid`;
existing user data is preserved through the documented preference migration.

There is one playback implementation. The package has no engine selector,
fallback preference, libmpv dependency, or OpenGL surface.

## Qualification

Synthetic fixture generation and native qualification are repeatable:

```sh
./Scripts/run-playback-state-space.sh
./Scripts/generate-native-fixtures.sh
ILLIQUID_NATIVE_FIXTURE_DIR="$PWD/TestFixtures/Generated" swift test --no-parallel
./Scripts/run-native-qualification.sh
```

The ownership model and qualification evidence are documented in
[Documentation/ARCHITECTURE.md](Documentation/ARCHITECTURE.md) and
[Documentation/NATIVE_PLAYBACK_QUALIFICATION.md](Documentation/NATIVE_PLAYBACK_QUALIFICATION.md).
The bounded policy explorer is documented in
[Documentation/PLAYBACK_STATE_SPACE_SEARCH.md](Documentation/PLAYBACK_STATE_SPACE_SEARCH.md).

## License

Original project code, documentation and assets are licensed under
**GPL-3.0-or-later**. See [LICENSE](LICENSE), [licensing scope](LICENSING.md), and
[third-party notices](THIRD_PARTY_NOTICES.md).
