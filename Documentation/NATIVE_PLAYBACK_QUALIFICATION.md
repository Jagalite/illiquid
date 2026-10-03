# Native playback qualification

The production playback runtime is qualified with deterministic core tests,
generated media fixtures, sanitizer passes, long A/V synchronization runs, and
packaged-app dependency verification.

The qualification runner first executes the deepest bounded playback policy
search. That result is a separate evidence line: it does not replace the
differential, renderer, fixture, sanitizer, stress, package, or physical-device
gates that follow it.

## Automated matrix

- H.264, HEVC, HEVC 10-bit/P010, VP9, AV1, and variable-frame-rate video
- AAC, FLAC, Opus, Vorbis, MP3, PCM, 5.1, and 7.1 audio
- embedded and external ASS/SRT subtitles, animated ASS, and embedded fonts
- HDR10/PQ, HLG, rotation, nonzero timeline origins, resize stress
- rapid seeks, exact audio trim, repeated open/replace/shutdown, sleep/wake
- stale callback, lease, fence, recovery, drain, and track rollback state search

The standard suite runs with:

```sh
SUPERPLAYR_STATE_SPACE_PROFILE=pr ./Scripts/run-playback-state-space.sh
./Scripts/generate-native-fixtures.sh
SUPERPLAYR_NATIVE_FIXTURE_DIR="$PWD/TestFixtures/Generated" \
SUPERPLAYR_NATIVE_REQUIRE_FIXTURES=1 swift test --no-parallel
```

Long steady-state A/V gates cover H.264, HEVC/P010, and VFR. Override the default
duration when doing release qualification:

```sh
SUPERPLAYR_NATIVE_LONG_RUN_SECONDS=1800 ./Scripts/run-native-qualification.sh
```

The drift calculation excludes preroll and final drain. Its minimum analysis
window adapts to the requested run duration while retaining the same drift
threshold, so short developer qualification runs do not silently fall back to
an endpoint-only proxy.

## Robustness implementation regression (2026-09-04)

The fixture-required suite passed 645 tests in 89 suites with the native,
bitmap and planar fixture directories enabled. This covers automatic BWDIF field
order/cadence/drain/seek contracts, negotiated PCM sample-buffer layout, planar
code values, bitmap subtitle reconstruction and existing integration checks.
It does not replace the historical physical/stress evidence below or qualify
those scenarios for the current implementation. No player app was launched.
Detailed limits and artifacts are in the
[findings register](ROBUSTNESS_REVIEW_MPV_IINA.md#tenth-implementation-checkpoint-2026-09-04).

## Bounded policy-search evidence

`Scripts/run-playback-state-space.sh` executes every named seed in six separate
models and supports deterministic `SUPERPLAYR_STATE_SPACE_SHARD_INDEX` /
`SUPERPLAYR_STATE_SPACE_SHARD_COUNT` partitioning. PR runs are unreduced and
checked against the versioned baseline. Nightly runs use conservative POR;
qualification runs add dynamic diamond checks before the remaining native
qualification stages.

Each summary records model version, seed, bounds, termination, state and edge
counts, production transition count, gate rejections, POR measurements,
structural reachable-key digest, progress classification, and trend findings.
A passing statement is limited to “no invariant or progress violation within
the recorded model/version/configuration bounds.” Depth/state/edge frontier
nodes are explicitly unmeasured. See
[PLAYBACK_STATE_SPACE_SEARCH.md](PLAYBACK_STATE_SPACE_SEARCH.md) for commands,
bounds, abstraction rules, and artifact replay.

## Structural migration baseline

Captured on 2026-07-19 with Xcode 26.6 (`17F113`) on arm64 macOS:

- the fixture-required suite passed 112 tests in 20 suites;
- deterministic replay/model/invariant and architecture boundary checks passed;
- fresh 12-reopen AddressSanitizer and ThreadSanitizer stress runs passed;
- all three default 60-second steady-state fixture runs passed with zero dropped frames;
- the release app built, its 25 Mach-O images resolved inside the bundle, the
  arm64 bundle passed strict validation, and its ad-hoc signature verified;
- package verification found no removed engine or OpenGL dependency.

| Fixture | Presented | Steady drift | Memory growth | Submitted |
| --- | ---: | ---: | ---: | ---: |
| `long-h264-av-sync.mkv` | 59.62 s | -0.056 s | 32 KiB | 1,436 |
| `long-hevc-p010-av-sync.mkv` | 59.47 s | -0.001 s | 336 KiB | 1,433 |
| `long-vfr-av-sync.mkv` | 59.41 s | +0.000 s | 80 KiB | 747 |

A live `leaks` snapshot during the repeated HDR/P010 playback stress reported
13,536 bytes in 264 allocations, all rooted in LinkServices/AppIntents XPC
cycles. An idle app snapshot in the same build reported the same system roots
and a larger 14,272 bytes in 284 allocations. Neither report identified a
playback-owned root.

## FC/IS behavior-authority completion run

Captured on 2026-07-20 with Xcode 26.6 (`17F113`) on arm64 macOS after the
production authority switch:

- the fixture-required suite passed 119 tests in 20 suites;
- production-driver seam tests passed delayed, duplicate, stale, failed, and
  cancelled identified outcomes;
- deterministic core and architecture validation passed, including static
  rejection of direct core-command backend bypasses and duplicate native policy
  state;
- fresh 12-reopen AddressSanitizer and ThreadSanitizer production-driver stress
  runs passed;
- all three 60-second steady-state fixture runs passed with zero dropped frames;
- the release app built and all 25 bundled Mach-O images resolved; the arm64
  bundle passed strict validation and its ad-hoc signature verified; and
- a live packaged-app smoke opened the 2-minute H.264/AAC fixture, observed
  advancing playback, changed logical position with the scrubber, verified an
  exact stable pause, resumed advancement, and exited cleanly through the UI.

| Fixture | Presented | Steady drift | Memory growth | Submitted | Dropped |
| --- | ---: | ---: | ---: | ---: | ---: |
| `long-h264-av-sync.mkv` | 60.134 s | +0.063 s | 32 KiB | 1,448 | 0 |
| `long-hevc-p010-av-sync.mkv` | 60.237 s | -0.009 s | 64 KiB | 1,450 | 0 |
| `long-vfr-av-sync.mkv` | 60.169 s | -0.059 s | 2,960 KiB | 757 | 0 |

## Manual release checks

Run the [manual playback checklist](MANUAL_PLAYBACK_CHECKLIST.md) on real media
and hardware for lip sync, fullscreen/resize, HDR-to-SDR display movement,
audio-device changes, sleep/wake, PiP, subtitle appearance, and repeated teardown.

## Packaging gate

`Scripts/build-platinum-app.sh` packages only the native dependency closure.
`Scripts/audit-platinum-app.sh` fails on unresolved or external loader paths,
architecture gaps, missing resources, and invalid signatures. The qualification
runner then packages and smoke-tests a copied DMG application. Record `otool -L`,
architecture, signature, and bundled library versions with release evidence.
