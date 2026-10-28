# Saved track preference matching

## Research question

`MediaTrackPreference.bestMatch(in:)` restores a remembered audio or subtitle
choice from the current track catalog. It filters by kind, assigns metadata
scores, rejects zero-score candidates, and takes the maximum using the existing
saved-ID and lower-ID tie breakers.

The baseline eagerly materializes three intermediate arrays. The candidate
adds `.lazy` to the same pipeline so the maximum consumes scored candidates as
they are produced. The scoring weights, order, nil behavior, matching rules,
and comparator are unchanged. There is no new cache or state.

## Reproduce

Use Swift 6.1 or newer. The native workflow targets macOS 26 with Xcode 26.6.

```sh
python3 Benchmarks/TrackPreferenceMatching/run.py test --configuration debug --output /tmp/track-match-debug
python3 Benchmarks/TrackPreferenceMatching/run.py test --configuration release --output /tmp/track-match-release
python3 Benchmarks/TrackPreferenceMatching/run.py benchmark --rounds 10 --target-ms 30 --output /tmp/track-match-benchmark
```

Use a new output directory for every invocation. The runner refuses to
overwrite existing evidence. Where the shared Kyoto queue is available, submit
the intended command through it, then inspect the job with `show`, `logs`,
and `wait` before reporting a result. The workflow explicitly records that Kyoto
is unavailable on its isolated hosted runner and serializes all builds there.

## Method

The frozen baseline is commit
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`. The baseline manifest verifies
its complete `MediaPlaybackSettings.swift` and the shared
`MediaTrack.swift` against their Git blob IDs before every test or benchmark.
The candidate uses the actual current production file. No algorithm copies or
platform stubs are used for either implementation.

The two source files form an optimized shared `IlliquidCore` module compiled
with `-O -whole-module-optimization` and Swift 6 language mode. The driver is
compiled separately without cross-module optimization, and the measured API is
not inlinable. Every output contributes to a retained checksum.

Both variants run the existing saved-track restoration regressions and the new
matching edge cases in debug and release builds. A separate deterministic
differential corpus compares complete selected tracks before timing, including
fields that distinguish otherwise tied tracks.

Fixture and preference construction, verification, and warm-up are outside the
timed region. Calls to the production matcher and result consumption remain
inside it. Pilot processes choose one shared iteration count per workload so
the faster implementation's interval reaches at least 30 ms. Final timing uses
ten fresh-process pairs per workload, five baseline-first and five
candidate-first. Every pilot and final observation is retained. Timing
percentages are evidence, not CI pass/fail gates.

The runner records exact commands, compiler and source hashes, executable
hashes, platform information, raw measurements, pair ratios, and full
differential results. The workflow also uploads those receipts and test logs
as `track-preference-matching-native`.

## Scope

This measures the cost of matching one saved track preference. It does not
measure whole-file open latency, decoding, frame pacing, or visible playback.
Large catalogs are stress cases; empty and small catalogs are controls.
