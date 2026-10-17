# Track selection ranking performance

Date: October 17, 2026. Baseline:
`68274d1b09dcc866296321a5a8858efc297c4f19`.

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

For N eligible candidates after filtering, the ranking work is:

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

The benchmark also compares the complete sequence of selected IDs from the
baseline and candidate across deterministic policy/catalog combinations. Timing
receipts compare each pair's operation count and consumed-result checksum.

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
