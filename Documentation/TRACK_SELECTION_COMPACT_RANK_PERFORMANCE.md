# Compact automatic track-selection ranks

## Result and decision

Replace the temporary seven-element rank arrays in
[`TrackSelectionPreferences.select`](../Sources/IlliquidCore/Player/TrackSelectionPreferences.swift)
with a scalar integer rank. Native macOS measurements show a reproducible
reduction in ranking cost when language normalization is absent. Selection
semantics remain unchanged in the tested corpus.

The independent twenty-pair replication measured the following complete
`select` call costs. Time columns are medians in microseconds per selection;
the change column is the percentage difference between those medians.

| Workload | Baseline µs | Candidate µs | Median-time change | Candidate faster pairs |
| --- | ---: | ---: | ---: | ---: |
| Audio, 2 tracks, no language policy | 0.458 | 0.393 | -14.3% | 20/20 |
| Audio, 8 tracks, no language policy | 1.173 | 0.908 | -22.6% | 19/20 |
| Audio, 32 tracks, no language policy | 3.633 | 2.501 | -31.2% | 20/20 |
| Subtitles, Always, 8 tracks, no language policy | 1.239 | 0.943 | -23.9% | 20/20 |

These save approximately 66 ns, 265 ns, and 1.13 µs per audio selection,
and 296 ns per Always-subtitle selection in this cohort. The result supports
the small production change. It does not establish a perceptible reduction
in media-open latency, playback-frame cost, battery use, or application memory.

## Why this area

The preceding [ranking optimization](TRACK_SELECTION_RANKING_PERFORMANCE.md)
already cached the incumbent's rank and avoided ranking empty/singleton
catalogs. Current main still constructs a seven-element `[Int]` for each
eligible ranked track, then compares arrays for equality and lexicographic order.
This follow-up removes those temporary rank representations and uses scalar
comparisons. No persistent cache, dependency, public API, or playback policy
is added.

The order is language preference, commentary avoidance, accessibility,
dedicated forced subtitles, default-track flag, subtitle forced flag, and
demuxer fallback. Language priority receives weight 64; the six binary
preferences retain their exact predicates and receive weights 32, 16, 8, 4,
2, and 1 respectively.

All six lower weights sum to 63, so a one-level language advantage dominates
every lower preference. Existing sanitization admits at most 32 language
entries, making the complete rank range `0...2111`. Equal ranks still select
the lowest signed `Int64` ID. Eligibility, language normalization, mutable
preference sanitization, automatic/off behavior, and empty/singleton paths
retain their source logic.

The experiment measures complete component call time. It does not separately
measure allocation counts; the array-removal mechanism should not be described
as a measured application-memory reduction.

## Experiment and provenance

Both variants compile complete production `MediaTrack.swift` and
`TrackSelectionPreferences.swift` sources as separate optimized shared
`IlliquidCore` modules. The same independently compiled driver calls each
module. There are no platform stubs, copied scoring algorithms, or cross-module
inlining of the production selection function.

The frozen follow-up baseline is current main at
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`, with the original incumbent-rank
optimization already present. Its [manifest](../Benchmarks/TrackSelectionRanking/baseline-compact-rank/manifest.json)
pins both Git blob IDs and SHA-256 hashes. The runner rejects modified frozen
inputs before building. The historical baseline and evidence remain intact;
`--baseline-dir` selects this follow-up explicitly.

The native environment was macOS 26.6.2/arm64, Apple Swift 6.3.3 under Xcode 26.6,
and the macOS 26.5 SDK, targeting macOS 26.0. Kyoto was unavailable on the
hosted runners; component builds ran serially in isolated output directories.

Two independent cohorts are retained:

1. [Initial run](https://github.com/Jagalite/illiquid/actions/runs/40633467004):
   commit `3169391027fe2873743708784f0bcdc5fdbc66ea`, ten pairs per workload,
   100 ms calibration target, 320 final observations. It showed ranking gains
   and two apparent subtitle slowdowns, prompting replication.
2. [Longer replication](https://github.com/Jagalite/illiquid/actions/runs/40633913283):
   commit `4c55b401e13b101158753dc0c75f7b3e3c0f1e63`, twenty pairs per
   workload, 250 ms calibration target, 640 final observations. Only the
   workflow's round count and calibration target changed. All staged source,
   test, runner, and harness hashes match the initial cohort.

Every final observation runs in a fresh process. Baseline-first and
candidate-first orders are balanced for every workload. Separate pilot
processes calibrate one iteration count shared by both variants. Inputs and
warm-up are outside timing; sanitization, filtering, normalization, ranking,
and temporary work inside `select` remain timed. Every selection contributes
to an observable checksum and selected count, and pair receipts must match.

The replication's timed intervals span 248.8–518.7 ms. Its 640 process-log
hashes, all summary values, both execution orders, complete selection receipts,
and four test logs were checked against the retained raw data.

## All workload results and the initial slowdowns

The table below uses **median paired change**:
the median of `candidate elapsed / baseline elapsed - 1` across matched pairs.
It is a different statistic from the ratio of independently calculated
medians in the headline table. Negative values favor the candidate. The two
cohorts are reported separately; their absolute timings are not pooled.

| Workload | Initial: 10 pairs | Replication: 20 pairs |
| --- | ---: | ---: |
| `audio-0-none` | -0.65% | -2.30% |
| `audio-0-languages` | 3.55% | -0.02% |
| `audio-1-none` | 3.80% | -0.31% |
| `audio-1-languages` | 3.78% | -1.42% |
| `audio-2-none` | -14.90% | -14.03% |
| `audio-2-languages` | -2.34% | -0.95% |
| `audio-8-none` | -18.65% | -22.44% |
| `audio-8-languages` | 4.35% | -0.44% |
| `audio-32-none` | -33.24% | -30.84% |
| `audio-32-languages` | -5.77% | -1.91% |
| `subtitle-automatic` | 18.29% | 0.35% |
| `subtitle-off` | -9.49% | -2.17% |
| `subtitle-always` | -24.85% | -23.28% |
| `subtitle-forced-languages` | 0.24% | -1.12% |
| `subtitle-forced-audio-fallback` | 7.29% | -0.69% |
| `mutable-preferences` | 2.42% | -1.09% |

The no-language audio ranking reductions and Always-subtitle reduction
reproduced across the independent cohorts. In the replication, the candidate
won 20/20, 19/20, and 20/20 pairs for two-, eight-, and 32-track audio, and
20/20 pairs for Always subtitles.

The initial automatic-subtitle slowdown (+18.29% paired) did not reproduce:
the replication's paired change was +0.35%. Forced selection with audio-language
fallback moved from +7.29% to −0.69%. They remain documented as unconfirmed
slowdowns from the initial cohort, rather than being omitted because their
source paths mostly bypass ranking. This is not a proof of statistical
equivalence or absence of regressions on other hardware.

Empty/singleton audio and disabled-subtitle controls in the replication varied
by approximately −2.30% to −0.02% using the paired statistic. Workloads dominated
by Foundation language normalization showed much smaller differences than the
target ranking cases. Those small differences are not claimed as improvements.

## Correctness qualification

Both variants passed all 13
[`TrackSelectionRankingTests`](../Tests/IlliquidCoreTests/TrackSelectionRankingTests.swift)
in debug and release on both native runs. These independently state preference
precedence, forced eligibility, fallback behavior, duplicates, extreme signed
IDs, empty/singleton behavior, and sanitization expectations.

The added regression test covers all 32 distinct admitted language priorities,
publicly mutated preferences, exclusion of the 33rd language, and both input
orders. Under forced-only selection the preferred-language candidate loses all
six lower preferences yet remains eligible through forced-event filtering.
Always mode also compares language rank 1 with an unlisted language's rank 0.

Before timing, the complete baseline and candidate receipts agreed for all
55,296 deterministic selections: every subtitle policy, both accessibility and
commentary settings, language aliases and invalid values, catalog permutations,
all track-flag combinations, mixed kinds, fallbacks, and extreme IDs. Equality
is checked over complete selected-ID arrays, not only aggregate checksums.

These runs qualify the native component and its focused tests. They do not
provide live playback/UI qualification or substitute for the repository's
full application integration CI.

## Reproduce and inspect

```sh
python3 Benchmarks/TrackSelectionRanking/run.py test --baseline-dir Benchmarks/TrackSelectionRanking/baseline-compact-rank --configuration debug --output /tmp/compact-rank-debug
python3 Benchmarks/TrackSelectionRanking/run.py test --baseline-dir Benchmarks/TrackSelectionRanking/baseline-compact-rank --configuration release --output /tmp/compact-rank-release
python3 Benchmarks/TrackSelectionRanking/run.py benchmark --baseline-dir Benchmarks/TrackSelectionRanking/baseline-compact-rank --rounds 20 --target-ms 250 --output /tmp/compact-rank-benchmark
```

Use a fresh output directory for each command. On a development machine with
Kyoto available, submit these commands through the shared queue as described
in `AGENTS.md`. The native workflow uses the follow-up baseline and longer
measurement settings. The temporary research-branch push trigger is removed
from the final change; normal pull-request and manual triggers remain.

The complete unmodified Actions artifacts are retained with
[initial evidence](../Benchmarks/TrackSelectionRanking/evidence/compact-rank-initial/README.md)
and [replication evidence](../Benchmarks/TrackSelectionRanking/evidence/compact-rank-native/README.md).
They contain raw final and calibration measurements, individual process logs,
complete differential outputs, build manifests, compiler hashes, and test logs.
Each directory includes the original ZIP digest and instructions to regenerate
its summary without relying on an expiring Actions artifact.
