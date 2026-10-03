# Distributing Illiquid

This guide covers the local Illiquid application and DMG workflow. It does not
implement notarization, Apple credential handling, release publishing, or
GitHub Actions.

## Prerequisites

The build Mac needs macOS 26, full Xcode, and Homebrew copies of `ffmpeg`,
`libass`, and `pkg-config`:

```sh
brew install ffmpeg libass pkg-config
```

These are build-time inputs. `Illiquid.app` embeds its complete non-system
runtime library closure and must not load from Homebrew, Xcode, the source
checkout, `/opt/homebrew`, or `/usr/local` when installed.

The current output is Apple Silicon (`arm64`) only. Do not label the artifact
universal: every embedded binary would need both `arm64` and `x86_64` before a
universal build could be produced.

## One-command local DMG

Ad hoc signing is the default and is the normal local-development workflow:

```sh
PLATINUM_VERSION=0.1.0 \
PLATINUM_BUILD_NUMBER=1 \
./Scripts/build-local-dmg.sh
```

The explicit signing variants are:

```sh
./Scripts/build-local-dmg.sh --unsigned
./Scripts/build-local-dmg.sh --adhoc
DEVELOPER_ID_APPLICATION="Developer ID Application: Example Corp (TEAMID)" \
  ./Scripts/build-local-dmg.sh --developer-id
```

The command runs focused product and packaging tests, performs a Release build
in an isolated SwiftPM scratch directory, assembles and audits the application,
signs in deterministic inside-out order, packages and mounts the DMG, copies the
app to a temporary Applications-like directory, launch-tests that installed
copy with isolated user data, and generates the checksum.

Outputs are not tracked:

```text
dist/Illiquid.app
dist/Illiquid-<version>-macOS.dmg
dist/Illiquid-<version>-macOS.dmg.sha256
```

The DMG volume is `Illiquid` and contains:

```text
Illiquid.app  ->  Applications
```

## Build only the application

```sh
./Scripts/build-platinum-app.sh --adhoc
./Scripts/audit-platinum-app.sh --require-signature \
  --archs arm64 dist/Illiquid.app
```

Supported metadata and build inputs are:

| Variable | Default source | Purpose |
| --- | --- | --- |
| `PLATINUM_VERSION` | `Resources/Info.plist` | Marketing version |
| `PLATINUM_BUILD_NUMBER` | `Resources/Info.plist` | Bundle build number |
| `PLATINUM_BUNDLE_ID` | `Resources/Info.plist` | Bundle identifier override |
| `PLATINUM_ARCHS` | `Resources/Info.plist` | Space-separated required architectures |
| `PLATINUM_MINIMUM_MACOS` | `Resources/Info.plist` | Deployment target |
| `PLATINUM_COPYRIGHT` | `Resources/Info.plist` | About/Finder copyright |
| `PLATINUM_BUILD_ROOT` | temporary directory | Explicit isolated build root |
| `PLATINUM_SIGNING_MODE` | `adhoc` | `unsigned`, `adhoc`, or `developer-id` |
| `DEVELOPER_ID_APPLICATION` | none | Locally installed signing identity |
| `PLATINUM_SMOKE_VIDEO` | generated fixture | Representative install-smoke video |

`Resources/Info.plist` is the checked-in metadata source of truth. The assembly
script applies environment overrides to the copied bundle only and records the
current Git revision for local About-window diagnostics.

## Signing modes

- **Unsigned** removes existing signatures. It is only appropriate for
  controlled diagnostics.
- **Ad hoc signed** signs embedded code and the outer app with `-`. It supports
  local validation but does not establish a publisher identity or bypass
  Gatekeeper on another Mac.
- **Developer ID signed** uses an already-installed identity supplied through
  `DEVELOPER_ID_APPLICATION`. No identity or credential is stored in the repo.
- **Notarized** means Apple has accepted the signed artifact and its ticket has
  normally been stapled. Notarization is not implemented in this pass.

Public signing, notarization, stapling, and publishing will be added later in
GitHub CI. A local ad hoc DMG is for development/testing, not normal public
internet distribution.

## Dependency and architecture audit

The automated audit checks every packaged Mach-O image. Useful manual checks
are:

```sh
file dist/Illiquid.app/Contents/MacOS/Illiquid
lipo -info dist/Illiquid.app/Contents/MacOS/Illiquid
otool -L dist/Illiquid.app/Contents/MacOS/Illiquid
find dist/Illiquid.app/Contents/Frameworks -type f -print0 |
  xargs -0 -n1 otool -L
codesign --verify --deep --strict dist/Illiquid.app
```

Allowed non-system references use `@rpath`, `@loader_path`, or
`@executable_path`. `./Scripts/audit-platinum-app.sh` fails for missing
resources, inconsistent Illiquid metadata, escaping dependencies, unresolved
embedded libraries, incompatible architectures, or a required invalid
signature.

## Local installation and Launch Services

For a manual install test, mount the DMG, drag `Illiquid.app` to Applications,
then register that exact copy without resetting the global Launch Services
database:

```sh
./Scripts/register-platinum-launch-services.sh \
  /Applications/Illiquid.app \
  /absolute/path/to/video.mkv
```

The helper verifies the bundle name, executable, identifier, and document-type
declarations before registration. Supplying a video tests opening it with that
specific application copy. Further useful checks are:

```sh
open -a /Applications/Illiquid.app /absolute/path/to/video.mp4
open -a /Applications/Illiquid.app /absolute/path/to/folder
open -a /Applications/Illiquid.app \
  /absolute/path/to/video.mkv /absolute/path/to/video.srt
```

The DMG packaging command performs its own isolated installed-copy smoke test.
Interactive release qualification should additionally cover Finder
double-click/Open With, Dock and app-icon drops, multiple files, a folder,
video-plus-subtitle input, resume, Now Playing/media keys, and the video-only,
subtitle, HDR/Main10, and close-window PiP cases in
`Documentation/MANUAL_PLAYBACK_CHECKLIST.md`.

## Bundle identity and release prerequisites

The production identifier is `io.github.jagalite.illiquid`, using the owner's
GitHub namespace: <https://github.com/Jagalite/illiquid>. On first launch under
this identity, the app copies its `Superplayr.*` and `Platinum.*` preference keys
from `com.example.Superplayr` before creating theme/player stores. Existing
Illiquid values win, and a marker prevents repeat imports. The old defaults
domain is retained. History/session files continue in the existing Superplayr
Application Support location.

macOS permissions and system-managed saved application state are not copied;
users may need to grant permissions again. The new app registers its media
associations through Launch Services; existing user-selected default handlers
are not forcibly replaced. Use the exact Illiquid.app path when launching during
the transition because old Platinum copies can remain installed.

Internal Swift package, target, module, type, logging, and persistence names
retain `Superplayr` where no user sees them. The temporary reproducible Illiquid
icon is correctly embedded, but final production artwork remains a public
release prerequisite.

## License and corresponding source

Original project material is GPL-3.0-or-later; see [LICENSING.md](LICENSING.md).
App assembly copies LICENSE, LICENSING.md, THIRD_PARTY_NOTICES.md and Licenses/
into Contents/Resources before signing. The bundle audit requires these resources.

The dependency notice collection and matching source inputs, patches and build
recipes are assembled. Follow [Documentation/CORRESPONDING_SOURCE.md](Documentation/CORRESPONDING_SOURCE.md)
to verify and distribute the companion package beside matching binaries. Recheck
the final bundle whenever dependencies change. Source availability, signing and
physical-device playback qualification must still be established for a public release.

## Illiquid rename and existing user data

The visible product and packaged executable are now Illiquid. Build scripts keep
their existing `platinum` filenames and `PLATINUM_*` environment variables for
compatibility. Swift package/module names, persistence keys, the Application
Support location and custom metadata keys retain their previous names.

The permanent identifier is `io.github.jagalite.illiquid`. Preferences are imported
once from the original domain before app settings are read; history retains its
existing path. Migration tests cover existing destination values, repeat imports,
binary preference payloads and the untouched source domain.
