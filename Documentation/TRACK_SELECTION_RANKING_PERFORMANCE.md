# Track selection ranking performance

Date: October 17, 2026. Baseline:
`68274d1b09dcc866296321a5a8858efc297c4f19`.

## Result

Keep the candidate. On the native macOS runner, an eight-track audio catalog
without language preferences falls from **22.33 to 1.33 microseconds per
selection**, a **94.06% reduction** in elapsed time. With ordered language
preferences, the same catalog falls from **38.77 to 23.30 microseconds**,
**39.91% less time**. Both variants make exactly the same selections in the
behavior tests and complete differential corpus.

This is a small production change: 15 inserted and 5 removed lines in one file.
The absolute saving for the eight-track no-preference fixture is about 21
microseconds per selection, and for the 32-track fixture about 126 microseconds.
These savings apply to automatic stream choice during media opening.

## Native measurements

The successful [Actions run](https://github.com/Jagalite/illiquid/actions/runs/39067310230)
measured commit `20dedeaa37e51eb6e5dfd2e18605d760b20f3e24` on macOS 26.6.2/arm64,
Apple Swift 6.3.3, with the macOS 26.5 SDK and a macOS 26.0 deployment target.
Both variants use release optimization. Each workload has ten fresh-process
pairs, five AB and five BA. The table gives per-selection medians; a negative
change means less elapsed time.

| Workload | Baseline (µs) | Candidate (µs) | Elapsed-time change |
| --- | ---: | ---: | ---: |
| `audio-0-none` | 0.1735 | 0.1756 | +1.21% |
| `audio-0-languages` | 6.5965 | 6.5877 | -0.13% |
| `audio-1-none` | 0.2967 | 0.2654 | -10.55% |
| `audio-1-languages` | 6.7812 | 6.7809 | -0.00% |
| `audio-2-none` | 4.7805 | 0.5182 | -89.16% |
| `audio-2-languages` | 11.2851 | 11.3593 | +0.66% |
| `audio-8-none` | 22.3325 | 1.3257 | -94.06% |
| `audio-8-languages` | 38.7652 | 23.2955 | -39.91% |
| `audio-32-none` | 129.4734 | 3.9492 | -96.95% |
| `audio-32-languages` | 156.5415 | 74.1782 | -52.61% |
| `subtitle-automatic` | 0.8694 | 0.8613 | -0.92% |
| `subtitle-off` | 2.1202 | 2.1336 | +0.63% |
| `subtitle-always` | 22.7116 | 1.4002 | -93.83% |
| `subtitle-forced-languages` | 27.0081 | 25.4023 | -5.95% |
| `subtitle-forced-audio-fallback` | 19.0477 | 16.1521 | -15.20% |
| `mutable-preferences` | 40.3961 | 29.8410 | -26.13% |

The single-track language-preference control is effectively unchanged at
6.781 microseconds, preserving the case that regressed in the earlier probe.
Three controls have slightly higher candidate medians: empty/no-policy audio
(+2.1 ns), two-track audio with language preferences (+74.2 ns), and subtitles
off (+13.4 ns). These small changes are reported rather than counted as wins.
The two-track language case still requires two ranks in both versions and is
slower in seven of ten pairs. All ten pairs improve for the two-, eight-, and
32-track no-language ranking workloads,
the eight- and 32-track language workloads, subtitle Always, and mutable
preferences.

The forced-only/audio-fallback fixture starts with eight subtitle tracks but
filters to one English candidate or two Japanese candidates. Its result measures
eligibility filtering plus that small final selection, rather than eight
eligible ranks. Forced-only explicit-language filtering is also included in
the timing boundary. Both forced-only fixtures improve in nine of ten pairs;
the audio-fallback fixture has one pair that is 58.3% slower. These measurements
do not establish improved tail latency.

The [full summary](../Benchmarks/TrackSelectionRanking/evidence/macos-arm64/summary.json)
contains each variant's minimum and maximum, all paired ratios, and iteration
counts. The [retained evidence](../Benchmarks/TrackSelectionRanking/evidence/macos-arm64/README.md)
includes the unmodified native artifact, all 320 final observations, separate
calibration runs, exact source/build receipts, and complete output comparisons.
Each workload's iteration count was calibrated separately to a faster-variant
pilot of at least 20 ms; final intervals vary with the runner. Fixture creation
and warm-up are outside timing, while actual preference sanitization, filtering,
ranking, and the documented mutable-field assignments are included.

## Scope and motivation

This investigation follows the track-ranking opportunity deferred in
[the shortcut dispatch research](SHORTCUT_DISPATCH_PERFORMANCE.md#deferred-opportunities).
That experiment regressed singleton catalogs with language preferences. The
candidate here retains the existing zero-ranking behavior for zero or one
eligible track.

[`FFmpegMediaInfo.preferredTrackIndex`](../Sources/IlliquidNativePlayback/Media/NativeTrackSelection.swift)
calls `TrackSelectionPreferences.select` when choosing audio and subtitle streams
for media opening. The selection code first sanitizes preferences, filters
eligible candidates, and applies the automatic subtitle fallback rule. It then
compares seven ranking priorities and breaks an otherwise equal rank with the
lower track ID.

The baseline uses `max(by:)` and constructs both ranks for every comparison.
Constructing a rank normalizes the candidate's language through Foundation's
`Locale.Language`, even when the requested-language array is empty and the
resulting language rank must be zero. The current winner can be normalized
repeatedly as later candidates are considered.

This is work performed during track selection. Its cost is separate from file
I/O, stream probing, decoding, rendering, and the total time to open media.

## Implementation

The production change is confined to
[`TrackSelectionPreferences.swift`](../Sources/IlliquidCore/Player/TrackSelectionPreferences.swift):

1. Return the sole eligible track (or nil) after the existing subtitle eligibility
   and automatic fallback rules, before constructing any rank.
2. Use a language rank of zero directly when there are no ranking language
   preferences.
3. Retain the current winner's rank in a local variable. Rank each remaining
   candidate once and replace the winner and its rank together.

The original seven-element rank and its lexicographic comparison are retained.
The tie rule still compares signed IDs directly, without subtraction. Preference
sanitization runs on every call, including preferences changed after construction
or decoded from JSON. Forced-only filtering can still normalize languages to
enforce an explicit subtitle language or an audio-language fallback.

For calls that do not take an earlier subtitle-policy return, with N eligible
candidates after filtering, the ranking work is:

| Case | Baseline rank evaluations | Candidate rank evaluations | Baseline / candidate candidate-language normalizations during ranking |
| --- | ---: | ---: | ---: |
| N = 0 or 1 | 0 | 0 | 0 / 0 |
| N > 1, no language preferences | 2(N−1) | N | 2(N−1) / 0 |
| N > 1, language preferences | 2(N−1) | N | 2(N−1) / N |

These counts exclude preference sanitization and forced-only eligibility
filtering, whose work is unchanged. The candidate keeps only the current winner
and rank; it introduces no persistent cache or invalidation policy.

## Correctness checks

The new
[`TrackSelectionRankingTests`](../Tests/IlliquidCoreTests/TrackSelectionRankingTests.swift)
suite uses independently specified expected selections. It exercises each
ranking priority against conflicting lower priorities, signed ID extremes,
input permutations, duplicate IDs with different metadata, empty and singleton
catalogs, mixed track kinds, every subtitle policy, filterable bitmap subtitles,
language aliases, mutable and decoded preferences, and the first-32-input
sanitization bound.

All **12 behavior tests passed against both baseline and candidate in debug and
release**, for 48 successful test-function executions. The complete baseline and
candidate receipts also agree for **55,296 selections** across deterministic
policy/catalog combinations. Each timing pair matches its operation count and
consumed-result checksum. Independent review reproduced all 320 rows' medians,
ranges, and paired ratios, checked the five-AB/five-BA order per workload, and
verified source and individual process-log hashes against the retained inputs.

The first native attempt passed all four test runs but failed to compile the
standalone timing module because its direct compiler invocation needed an
explicit SDK path. The runner was corrected to resolve and record the SDK with
`xcrun` and pass `-sdk` to both compilation commands. That failed attempt produced
no timings; all figures above come from the subsequent successful run.

## Reproduction and native qualification

See the [benchmark guide](../Benchmarks/TrackSelectionRanking/README.md) for
commands, workload definitions, source provenance, and timing boundaries.
Both versions compile the actual Foundation-based production sources; no player
or platform substitutes are used. The optimized production module and timing
driver are compiled separately so repeated calls cannot be folded into a
constant result by whole-module optimization.

The dedicated
[macOS workflow](../.github/workflows/track-selection-ranking.yml) runs the
component checks and paired benchmark on macOS 26. The existing restoration
workflow also builds the full application dependency graph and runs its complete
native release test suite, including track metadata mapping and persistence
coverage. Physical playback and complete media-open latency require a separate
interactive macOS measurement.
