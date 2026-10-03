# Building Illiquid

## Requirements

- macOS 26 or newer
- full Xcode selected by `xcode-select`
- Xcode's Metal Toolchain component for packaged-app shader compilation
- Homebrew `ffmpeg`, `libass`, and `pkg-config` on the build machine

```sh
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -runFirstLaunch
xcodebuild -downloadComponent MetalToolchain
brew install ffmpeg libass pkg-config
xcodebuild -version
pkg-config --modversion libavformat libavfilter libass
```

Homebrew is a build-time input only. The Illiquid packaging workflow copies the
complete non-system dynamic-library closure into the application and rejects
any resulting dependency or runtime path that escapes the bundle.

## Development gates

The Swift package and executable product retain the internal `Superplayr`
name. These commands exercise the internal development build:

```sh
swift run SuperplayrArchitectureCheck
swift test --no-parallel
swift build --product Superplayr
```

The architecture check enforces the framework-free deterministic-core boundary,
rejects direct core-owned runtime commands, and rejects duplicate native
synchronization or recovery policy state.
Fixture-backed qualification can be run with:

```sh
./Scripts/generate-native-fixtures.sh
SUPERPLAYR_NATIVE_FIXTURE_DIR="$PWD/TestFixtures/Generated" \
SUPERPLAYR_NATIVE_REQUIRE_FIXTURES=1 swift test --no-parallel
```

## Native dependency lock

Packaging verifies `Scripts/native-dependencies.lock.json` against the direct
FFmpeg/libass inputs: architecture, versions, library and public-header hashes,
pkg-config metadata, and the FFmpeg libraries' own configuration strings. The
schema-2 lock also pins hashes and architectures for the complete non-system
native-library closure (26 libraries in the current ARM64 inputs, including
libavfilter and its libvmaf dependency for automatic BWDIF deinterlacing).
A mismatch fails packaging. The checked-in lock records the reviewed ARM64
inputs; it does not download dependencies or prove a reproducible build.
Packaging supplies the actual original libraries it copies to the lock check;
extra/missing inputs and conflicting basenames fail. Dependencies are resolved
from original files before install-name rewriting. The bundle inventory must
match those inputs. System frameworks/libraries remain SDK/OS dependencies.
Comparison of two clean release hosts is still required for reproducibility
qualification. Standalone lock collection rejects ambiguous `@rpath` inputs;
it does not emulate an arbitrary executable's dyld runpath stack.

After deliberately changing dependencies, review their provenance and run the
relevant compatibility tests before refreshing and committing the lock:

```sh
python3 Scripts/record-native-dependencies.py \
  --output /tmp/platinum-native-inputs.json \
  --write-lock Scripts/native-dependencies.lock.json
python3 Scripts/record-native-dependencies.py \
  --output /tmp/platinum-native-inputs-verified.json \
  --verify-lock Scripts/native-dependencies.lock.json
python3 Scripts/tests/native-dependency-lock-tests.py
```

Packaged apps include `Contents/Resources/NativeDependencyProvenance.json`, with
source/toolchain evidence and bundled-library hashes captured before signing.
Those hashes are not post-sign artifact verification.

## Distribution bundle

The canonical local distribution workflow is:

```sh
PLATINUM_VERSION=0.1.0 \
PLATINUM_BUILD_NUMBER=1 \
./Scripts/build-local-dmg.sh --adhoc
```

It produces `dist/Illiquid.app`, a compressed DMG, and a SHA-256 checksum
without writing build output into tracked source directories.

See [DISTRIBUTING.md](../DISTRIBUTING.md) for signing modes, metadata inputs,
dependency and architecture auditing, Launch Services registration, and the
installed-copy qualification flow.

FFmpeg, libass, and their transitive libraries have independent license and
redistribution obligations. Review the exact packaged versions before shipping.

## Generated bitmap subtitle regression fixtures

The generator creates original PGS compositions and muxes/transcodes them with
`ffmpeg` into tiny PGS, DVD and DVB MKVs. It downloads no media and launches no player.
Use a disposable output directory; generated files at these names are replaced.

```sh
python3 Scripts/generate-bitmap-subtitle-fixtures.py /tmp/platinum-bitmap-fixtures
SUPERPLAYR_BITMAP_FIXTURE_DIR=/tmp/platinum-bitmap-fixtures \
  swift test --filter 'BitmapSubtitleTests|PiPSubtitlePipelineTests'
```

The environment enables container/worker tests; raw-packet, memory-bound,
forced-event and offscreen pixel tests also run without it. Generated coverage
includes a caption lasting 14 seconds, clear events, and forward/backward paused
seeks. It does not qualify real windows, NAS I/O or a broad subtitle corpus.

## Planar software-output qualification

Generate the additional original fixtures and run the independent code-value
checks plus the existing decoder, buffer, seek and replacement suite:

```sh
python3 Scripts/generate-planar-fixtures.py /tmp/platinum-planar-fixtures
SUPERPLAYR_PLANAR_EXPERIMENT_FIXTURE_DIR=/tmp/platinum-planar-fixtures \
  swift test --no-parallel --filter 'PlanarPrecisionReferenceTests|PlanarSoftwareOutputExperimentTests'
```

The suite also uses `TestFixtures/Generated` from `generate-native-fixtures.sh`.
The generators overwrite their named outputs. For a separate warm conversion
probe, set `SUPERPLAYR_MEASURE_PLANAR_CONVERSION=1` and run only
`PlanarPrecisionReferenceTests` with `--no-parallel`. The reported wall/thread
CPU times exclude allocation, decoding and presentation; they are not playback
or energy measurements. Native renderer tests may create temporary test windows;
they do not launch the player application.
