# Saved track preference matching

## Research question

`MediaTrackPreference.bestMatch(in:)` restores a remembered audio or subtitle
choice from the current track catalog. It filters by kind, assigns metadata
scores, rejects zero-score candidates, and takes the maximum using the existing
saved-ID and lower-ID tie breakers.

The baseline eagerly materializes three intermediate arrays. The candidate
scores eligible tracks in one pass and keeps only the current winner. The
scoring weights, traversal order, nil behavior, metadata matching, and tie
breaking rules are preserved. A complete tie still retains the first whole
track, including non-ranking flags. There is no new cache or state.

## Results — 2026-10-28

The single-pass loop passed native and portable qualification. On **macOS
26.6.2 arm64 with Apple Swift 6.3.3 (Xcode 26.6, SDK 26.5)**, it reduced median
matching time by **75.4–82.4%** across all sixteen populated 1-, 2-, 8-, and
32-track workloads. The candidate was faster in **160/160 paired comparisons**
for those workloads. The same production source on **Linux x86_64 with Swift
6.4** reduced medians by **73.6–84.9%**, also winning 160/160 pairs.

Representative native metadata-preference results: audio with 2 tracks fell
from 549.6 ns to 101.7 ns; 8 tracks from 1,431.9 ns to 274.3 ns; and 32 tracks
from 3,995.5 ns to 982.8 ns. Subtitle results were similar. These are fractions
of a microsecond to several microseconds saved per call, not an end-to-end
player latency measurement.

Each platform passed both variants' debug and release test invocations, using
the existing restoration regressions and the new matching tests. Each also
passed **1,801 complete selected-track comparisons** before timing. The
verification receipt SHA256 is identical across both platforms and the
rejected experiment:
`ecdb856a1b02e6430e005ecb08eae950d55bbed04bf6dc08c36120b814549055`.
The test suite contains 17 test functions in two suites; the Linux log prints
that count. Native logs expose passing invocation receipts; complete test
output is in the uploaded artifact.

Empty inputs improved on both platforms: approximately 46 ns to 32 ns on
macOS, and 15 ns to 6 ns on Linux. Wrong-kind controls were essentially
unchanged: native medians fell about 2.6–2.7%, while Linux audio was flat and
subtitle increased about 0.8% (1.8 ns). This small variation is not a claimed
benefit or regression. Zero-score inputs improved about 73% on macOS and 66%
on Linux. The 128- and 1,024-track cases are stress workloads, with no claim
that they represent typical user catalogs.

The native run contains 640 timing observations and 122 calibration
observations; the final Linux run contains 640 and 132 respectively. All
observations are retained. All 32 native workload medians improved, but
316/320 individual pairs improved; no claim is made that every sample won.
These are ten paired process samples per workload on hosted runners, not a
confidence interval or a survey of hardware.

Measured candidate commit:
`ecb8ceab7b3e2ca9b034afbe862a44f77dc4514a`.
Candidate production-file SHA256:
`ebbb3656e92dae0a9a61b30126b4d5e67d9d3858829c6f5629a32b4d495bb38e`.
Subsequent evidence-only commits do not change measured code.

### Complete median table

Times are nanoseconds per selection, including the benchmark's identical
result-consumption loop. Reduction is `100 × (1 − candidate / baseline)`;
a negative reduction means an increase. Metadata and legacy saved-ID
preferences are separate workloads. Each has ten samples per variant.

| Workload | macOS baseline ns | macOS loop ns | Reduction | Linux baseline ns | Linux loop ns | Reduction |
|---|---:|---:|---:|---:|---:|---:|
| audio-0-metadata | 46.1 | 31.8 | 31.0% | 14.5 | 6.3 | 56.8% |
| audio-0-legacy | 46.1 | 32.1 | 30.3% | 14.5 | 6.0 | 58.7% |
| audio-1-metadata | 323.0 | 65.5 | 79.7% | 272.6 | 41.2 | 84.9% |
| audio-1-legacy | 339.1 | 76.9 | 77.3% | 268.3 | 40.8 | 84.8% |
| audio-2-metadata | 549.6 | 101.7 | 81.5% | 477.0 | 79.4 | 83.4% |
| audio-2-legacy | 574.0 | 111.4 | 80.6% | 467.9 | 72.4 | 84.5% |
| audio-8-metadata | 1431.9 | 274.3 | 80.8% | 1330.2 | 297.4 | 77.6% |
| audio-8-legacy | 1639.7 | 288.5 | 82.4% | 1356.9 | 269.4 | 80.1% |
| audio-32-metadata | 3995.5 | 982.8 | 75.4% | 4414.7 | 1165.0 | 73.6% |
| audio-32-legacy | 4664.2 | 992.7 | 78.7% | 4597.1 | 1013.0 | 78.0% |
| audio-128-metadata | 12797.4 | 3538.1 | 72.4% | 15424.8 | 4547.4 | 70.5% |
| audio-128-legacy | 15928.0 | 3821.3 | 76.0% | 16607.7 | 3952.4 | 76.2% |
| audio-1024-metadata | 94243.9 | 27179.2 | 71.2% | 228127.2 | 35437.8 | 84.5% |
| audio-1024-legacy | 118269.3 | 30017.2 | 74.6% | 235574.4 | 31490.6 | 86.6% |
| audio-wrong-kind | 235.4 | 229.2 | 2.6% | 229.3 | 229.2 | 0.0% |
| audio-zero-score | 880.9 | 238.2 | 73.0% | 720.2 | 245.1 | 66.0% |
| subtitle-0-metadata | 46.1 | 32.0 | 30.6% | 14.5 | 6.0 | 58.5% |
| subtitle-0-legacy | 46.5 | 31.8 | 31.5% | 14.3 | 6.2 | 56.9% |
| subtitle-1-metadata | 315.6 | 64.8 | 79.5% | 273.2 | 41.1 | 84.9% |
| subtitle-1-legacy | 341.6 | 76.8 | 77.5% | 268.1 | 40.9 | 84.7% |
| subtitle-2-metadata | 546.0 | 101.9 | 81.3% | 476.7 | 79.5 | 83.3% |
| subtitle-2-legacy | 575.4 | 110.3 | 80.8% | 465.9 | 71.5 | 84.7% |
| subtitle-8-metadata | 1464.7 | 278.6 | 81.0% | 1350.2 | 297.9 | 77.9% |
| subtitle-8-legacy | 1639.9 | 293.0 | 82.1% | 1354.9 | 261.0 | 80.7% |
| subtitle-32-metadata | 3946.2 | 966.0 | 75.5% | 4402.0 | 1155.6 | 73.7% |
| subtitle-32-legacy | 4696.8 | 1004.2 | 78.6% | 4601.8 | 1010.4 | 78.0% |
| subtitle-128-metadata | 12788.9 | 3532.8 | 72.4% | 15626.3 | 4568.5 | 70.8% |
| subtitle-128-legacy | 15995.4 | 3811.2 | 76.2% | 16429.5 | 3957.2 | 75.9% |
| subtitle-1024-metadata | 93099.3 | 27661.3 | 70.3% | 227724.3 | 35685.5 | 84.3% |
| subtitle-1024-legacy | 118485.3 | 30154.9 | 74.5% | 235872.9 | 31312.4 | 86.7% |
| subtitle-wrong-kind | 236.0 | 229.6 | 2.7% | 228.4 | 230.3 | -0.8% |
| subtitle-zero-score | 868.9 | 238.5 | 72.6% | 712.2 | 245.0 | 65.6% |

### Retained evidence

| Experiment | Status | Run | Permanent numerical evidence |
|---|---|---|---|
| Initial lazy pipeline, Linux | Rejected | [40636220419](https://github.com/Jagalite/illiquid/actions/runs/40636220419) | [linux-lazy-rejected](evidence/linux-lazy-rejected) |
| Single pass, Linux | Passed | [40637102097](https://github.com/Jagalite/illiquid/actions/runs/40637102097) | [linux-single-pass](evidence/linux-single-pass) |
| Single pass, native macOS | Passed | [40637102083](https://github.com/Jagalite/illiquid/actions/runs/40637102083) | [macos-single-pass](evidence/macos-single-pass) |

Each evidence directory retains every calibration and timing JSON record, the
full workload summary with pair ratios, and manifests containing source and
compiler hashes, test-log hashes, verification receipt hashes, run identities,
and artifact digests. The JSONL records are copied from the runner's stdout
markers without filtering observations. Independent arithmetic checks
recomputed every median and pair ratio and checked paired selection
counts/checksums. Full process logs, compiled-input snapshots, and complete
differential output are available in the workflow artifacts until their
configured expiry on 2026-11-11. The committed numerical data remains after
artifact expiry.

## Reproduce

Use Swift 6.1 or newer. The native workflow targets macOS 26 with Xcode 26.6.

```sh
python3 Benchmarks/TrackPreferenceMatching/run.py test --configuration debug --output /tmp/track-match-debug
python3 Benchmarks/TrackPreferenceMatching/run.py test --configuration release --output /tmp/track-match-release
python3 Benchmarks/TrackPreferenceMatching/run.py benchmark --rounds 10 --target-ms 30 --output /tmp/track-match-benchmark
```

The benchmark always uses optimized `-O` builds; `--configuration` applies
to test mode only, even though the environment receipt records its default
value during benchmark mode.

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
as `track-preference-matching-native` or `track-preference-matching-linux`.

## Scope

This measures the cost of matching one saved track preference. It does not
measure whole-file open latency, decoding, frame pacing, or visible playback.
The controller calls this matcher while restoring saved audio/internal subtitle
settings in `applyPendingMediaSettings()` and external subtitles in
`applyPendingExternalSubtitleRestore()`. It is a per-file restoration path,
not a per-frame rendering path. Full-app integration and UI responsiveness
are not qualified by these component runs.

Large catalogs are stress cases; empty and small catalogs are controls.

## Rejected lazy pipeline

The first experiment added `.lazy` to the existing chain. On Linux x86_64
with Swift 6.4, it passed the tests and all 1,801 differential comparisons and
improved populated catalogs. However, it regressed empty inputs from about
15 ns to 113–119 ns and wrong-kind inputs from about 229 ns to 339–342 ns.
That candidate was rejected in favor of the direct loop above. The original
[run and logs](https://github.com/Jagalite/illiquid/actions/runs/40636220419)
and [retained evidence](evidence/linux-lazy-rejected) are kept distinct from
the final experiment; no samples are discarded or combined across
implementations. This trial contains 640 timing and 122 calibration rows.
