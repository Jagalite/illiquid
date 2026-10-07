# Distributing Illiquid

This guide covers local packaging and GitHub Actions prerelease publication.
Tagged releases require Developer ID Application signing and Apple notarization.
Main-branch builds use ad hoc signing for packaging validation without publishing.

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
ILLIQUID_VERSION=0.1.0 \
ILLIQUID_BUILD_NUMBER=1 \
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
./Scripts/build-illiquid-app.sh --adhoc
./Scripts/audit-illiquid-app.sh --require-signature \
  --archs arm64 dist/Illiquid.app
```

Supported metadata and build inputs are:

| Variable | Default source | Purpose |
| --- | --- | --- |
| `ILLIQUID_VERSION` | `Resources/Info.plist` | Marketing version |
| `ILLIQUID_BUILD_NUMBER` | `Resources/Info.plist` | Bundle build number |
| `ILLIQUID_BUNDLE_ID` | `Resources/Info.plist` | Bundle identifier override |
| `ILLIQUID_ARCHS` | `Resources/Info.plist` | Space-separated required architectures |
| `ILLIQUID_MINIMUM_MACOS` | `Resources/Info.plist` | Deployment target |
| `ILLIQUID_COPYRIGHT` | `Resources/Info.plist` | About/Finder copyright |
| `ILLIQUID_BUILD_ROOT` | temporary directory | Explicit isolated build root |
| `ILLIQUID_SIGNING_MODE` | `adhoc` | `unsigned`, `adhoc`, or `developer-id` |
| `DEVELOPER_ID_APPLICATION` | none | Locally installed signing identity |
| `ILLIQUID_SMOKE_VIDEO` | generated fixture | Representative install-smoke video |

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

GitHub tagged releases import Illiquid’s dedicated Application certificate into a
temporary runner keychain, notarize and staple the app before DMG assembly, then
sign, notarize and staple the DMG. Apple acceptance, ticket validation and
Gatekeeper assessment are required before publishing. Final checksums are
generated after stapling. The temporary keychain is removed even on failure.

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
`@executable_path`. `./Scripts/audit-illiquid-app.sh` fails for missing
resources, inconsistent Illiquid metadata, escaping dependencies, unresolved
embedded libraries, incompatible architectures, or a required invalid
signature.

## Local installation and Launch Services

For a manual install test, mount the DMG, drag `Illiquid.app` to Applications,
then register that exact copy without resetting the global Launch Services
database:

```sh
./Scripts/register-illiquid-launch-services.sh \
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
GitHub namespace: <https://github.com/Jagalite/illiquid>. Before creating settings
stores, migration copies `Superplayr.*` and `Platinum.*` preferences into
`Illiquid.*` keys. Existing Illiquid values win, followed by old keys in the
current domain, then `com.example.Superplayr`. The original keys remain intact.
The playback session is copied once from Application Support/Superplayr to
Application Support/Illiquid; the old file remains intact. A marker prevents a
cleared session from being imported again.

macOS permissions and system-managed saved application state are not copied;
users may need to grant permissions again. The new app registers its media
associations through Launch Services; existing user-selected default handlers
are not forcibly replaced. On each launch from `/Applications` or
`~/Applications`, Illiquid offers to become the default video player if any
supported format still opens with another app. “Not Now” dismisses the offer
for that launch only; reopening the player window does not repeat it.
Settings → Behavior includes an enabled-by-default launch reminder toggle and
a Make Default button that remains available when reminders are disabled. The action uses macOS consent handling and verifies the resulting
associations, reporting formats that could not be changed. Copies running from
the DMG must first be moved to Applications. Use the exact Illiquid.app path when launching during
the transition because old Illiquid copies can remain installed.

Internal Swift package, target, module, type, logging, and persistence names
retain `Illiquid` where no user sees them. The temporary reproducible Illiquid
icon is correctly embedded and is original project artwork.

## License and corresponding source

Original project material is GPL-3.0-or-later; see [LICENSING.md](LICENSING.md).
App assembly copies LICENSE, LICENSING.md, THIRD_PARTY_NOTICES.md and Licenses/
into Contents/Resources before signing. The bundle audit requires these resources.

The dependency notice collection and matching source inputs, patches and build
recipes are assembled. Follow [Documentation/CORRESPONDING_SOURCE.md](Documentation/CORRESPONDING_SOURCE.md)
to verify and distribute the companion package beside matching binaries. Recheck
the final bundle whenever dependencies change. Source availability, signing and
physical-device playback qualification remains separate from CI packaging checks.

## Illiquid rename and existing user data

The Swift package, executable, modules, scripts and active settings keys now use
Illiquid. Local development uses `swift run Illiquid`; packaging uses
`Scripts/build-illiquid-app.sh` and `ILLIQUID_*` environment variables. The bundle
identifier remains `io.github.jagalite.illiquid`. Migration tests cover existing
destination values, repeat imports, binary preference payloads, preservation of
the old domain, and cleared sessions remaining cleared.

## GitHub prerelease workflow

[release.yml](.github/workflows/release.yml) builds on a GitHub-hosted Apple
Silicon macOS 26 runner with Xcode 26.6. Update the version/build in
`Resources/Info.plist`, commit the clean release candidate, then push a matching
`v<version>` tag. Publish by choosing that tag and the prerelease option through
Actions → Build and release DMG → Run workflow. Tag pushes alone do not publish.
Pushes to `main` run the same
build and packaging checks without creating a release.

```sh
git tag -a v0.1.2 -m 'Illiquid 0.1.2 notarized prerelease'
git push origin main v0.1.2
gh workflow run release.yml -f tag=v0.1.2 -f prerelease=true
```

CI verifies matching source inputs, installs the pinned native SDK, checks the
architecture, runs focused packaging/product tests, builds and audits the app,
and mounts and launch-tests the DMG. Publication happens only after these
checks pass. The GitHub token needs `contents: write`. Configure the following
repository Actions secrets before dispatching a release:

| Secret | Value |
| --- | --- |
| `APPLE_APPLICATION_CERT_P12_BASE64` | Base64 of Illiquid’s dedicated Developer ID Application certificate and private key, exported as P12 |
| `APPLE_APPLICATION_CERT_PASSWORD` | Password protecting that P12 |
| `APPLE_NOTARY_USERNAME` | Apple Account email |
| `APPLE_NOTARY_PASSWORD` | Dedicated app-specific password for Illiquid notarization |
| `APPLE_TEAM_ID` | Ten-character team identifier matching the certificate |

These are separate from Superseedr’s credentials; its Installer certificate is
not an Application signing identity. Missing or invalid secrets fail the tagged
release before the build. Main-branch checks do not require these credentials.

Each release attaches the DMG, its checksum, the exact Git project-source
archive, the dependency-source archive, native build provenance, SHA256SUMS and Apple app/DMG notarization receipts.
The dependency source archive is required alongside the project source archive.
Git archive excludes the SDK and the separately distributed dependency sources.

`BuildInputs/native-sdk.tar.gz` contains reviewed native dylibs, development
headers, pkg-config metadata and the FFmpeg CLI. It preserves the exact native
lock hashes rather than taking moving Homebrew versions. Its manifest validates
every member and binds the SDK to `DependencySources/source-manifest.json`.
The installer only runs on disposable GitHub-hosted runners; it must not replace
a developer's local Homebrew installation. `DependencySources/` contains the
matching upstream source, notices, recipes and patches. A full dependency rebuild
from source has not yet been qualified; these inputs pin the release build,
without claiming bit-for-bit source reproducibility.

For a local release from an already configured Mac with matching dependencies:

```sh
./Scripts/build-release-artifacts.sh
```

## In-app updates

Illiquid embeds Sparkle 2.10.0. The app menu and Settings → Updates provide
manual checks, a daily automatic-check toggle, and an opt-in prerelease channel.
Updates always require installation confirmation. System profiling is disabled.
The updater is disabled for bare SwiftPM executables and benchmark launches.

Production signing happens in GitHub Actions. `SPARKLE_PRIVATE_KEY` is an Actions
secret containing Sparkle's base64 Ed25519 seed; `SPARKLE_PUBLIC_KEY` is the
matching repository variable. Only the public key is included in
`Resources/Info.plist`. Local app testing uses ad hoc code signatures and the
installation smoke test generates an independent disposable update key.
Do not replace a production update key after shipping without a key-rotation plan.

The permanent feed URL is
`https://github.com/Jagalite/illiquid/releases/download/appcast/appcast.xml`.
The `appcast` prerelease is infrastructure and must not be marked as the latest
application release. Initialize it once by dispatching the release workflow with
`initialize_update_feed=true`; no tag is required for that mode. It creates a
signed empty feed, or verifies and preserves existing signed update history.

For each application release:

1. Increment `CFBundleVersion` to an integer greater than all builds in the feed,
   update the marketing version and corresponding metadata tests, and tag that
   version. The release script requires a clean source checkout.
2. Dispatch the workflow with the existing tag and choose `prerelease=true` for
   beta or `prerelease=false` for stable. Tag pushes do not publish automatically;
   this prevents a beta publication racing a stable dispatch for the same build.
   Stable updates are
   visible to everyone; beta updates require the Settings opt-in. Disabling beta
   updates never downgrades the installed app.
3. CI signs and notarizes the app and DMG using its Apple credentials, verifies
   the existing signed feed, generates the new signed appcast, and validates the
   archive signature against the public key embedded in the app.
4. CI uploads the release archive before replacing the feed. Release jobs are
   serialized to prevent concurrent feed edits. Existing or decreasing build
   numbers fail instead of replacing a published update's bytes.
   To move from beta to stable, publish a new version with a higher build number.

The feed and update archives both require Ed25519 signatures. Signing secrets
are sent to Sparkle tools through stdin, never command arguments or repository
files. If feed publication fails after the release assets were uploaded, rerun
the workflow before attempting another release; if the feed was already updated,
use a new version/build instead of overwriting it.

Validation:

- `python3 Scripts/tests/update-feed-tests.py` checks build sequencing and malformed history.
- `AppUpdateControllerTests` checks configuration and channel preferences.
- `Scripts/tests/sparkle-install-smoke.py --app APP --tools SPARKLE_BIN --cli SPARKLE_CLI`
  tests signed feed selection, tampered download rejection, and a real installation
  into disposable app copies. Build `sparkle-cli` from the matching upstream
  Sparkle source; it is not included in the SwiftPM binary archive. This test does
  not qualify Apple notarization or the public production feed.

Existing installations without Sparkle need one manual upgrade to an
updater-enabled build. The current updater build is 5; its future update must
have a higher build number.
