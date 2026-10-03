# Illiquid

Illiquid is a native macOS media player built with SwiftUI, AppKit, FFmpeg,
VideoToolbox, Apple sample-buffer renderers, and libass. It supports local files
and folder playlists, tracks and subtitles, crash-safe resume, HDR/EDR display
policy, Now Playing/media keys, and system Picture in Picture.

## Build and run

Requirements: macOS 26, full Xcode, Homebrew, FFmpeg, libass, and pkg-config.

```sh
brew install ffmpeg libass pkg-config
swift run SuperplayrArchitectureCheck
swift test --no-parallel
./Scripts/build-local-dmg.sh
open dist/Illiquid.app
```

See [DISTRIBUTING.md](DISTRIBUTING.md) for release packaging
and [Documentation/MANUAL_PLAYBACK_CHECKLIST.md](Documentation/MANUAL_PLAYBACK_CHECKLIST.md)
for physical-device playback QA.

The [living findings register](Documentation/ROBUSTNESS_REVIEW_MPV_IINA.md)
tracks structural, robustness, and user-experience research against mpv and IINA.

## Architecture

- `SuperplayrPlaybackCore` is the deterministic imperative playback authority.
  It owns transitions, effect identity, seeks, drains, recovery, lifecycle,
  synchronization, track intent, and subtitle/control state.
- `SuperplayrNativePlayback` executes those decisions through FFmpeg,
  VideoToolbox, AVSampleBuffer renderers, and libass. Generation fences and
  leases reject stale work and separate logical invalidation from cleanup.
- `SuperplayrPlayer` coordinates product commands, persistence, and immutable
  runtime snapshots. It constructs the native runtime directly.
- `SuperplayrApp` is the reactive SwiftUI/AppKit shell. It observes
  `PlaybackViewStore` and does not own playback truth.

The internal Swift package and module names intentionally retain the historical
`Superplayr` prefix. The installed product and all user-facing surfaces are
named Illiquid. The macOS bundle identifier is `io.github.jagalite.illiquid`;
existing user data is preserved through the documented preference migration.

There is one playback implementation. The package has no engine selector,
fallback preference, libmpv dependency, or OpenGL surface.

## Qualification

Synthetic fixture generation and native qualification are repeatable:

```sh
./Scripts/run-playback-state-space.sh
./Scripts/generate-native-fixtures.sh
SUPERPLAYR_NATIVE_FIXTURE_DIR="$PWD/TestFixtures/Generated" swift test --no-parallel
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
