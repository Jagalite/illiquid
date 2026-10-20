# Prepared folder playlist construction

Date: October 19, 2026. Baseline:
`33fff16155c3472960f88e04c72dfdfdefd56dcf`.

## Problem and change

The current baseline already includes the filename-key caching from PR #39.
This follow-up addresses the next repeated operation:
`FolderPlaylistDiscovery.makePlaylist` sorts normalized media URLs, builds and
deduplicates playlist items, and then sends those items to the public
`FolderPlaylist` initializer for another natural filename sort.

The candidate reuses the established order when preparation preserved every URL
representation exactly. It compares the original and constructed URLs' UTF-8
bytes, requires the current locale to match the locale captured for the first
sort, and then uses an internal initializer that retains the prepared items.
Stable deduplication leaves a subsequence of that established order. Lists with
at most two final items keep the original path without the representation check.
The public initializer continues to sort arbitrary input items.

The representation check is necessary. With the unchanged normalizer on Swift
6.3.2/Linux, these three input URLs demonstrate an ordering change:

```text
file:///tmp/Z/%2E%2E/A/Same.mkv
file:///tmp/M/Same.mkv
file:///tmp/N/Same.mkv
```

The first normalization and sort produce parent paths `M`, `N`, and `Z/../A`.
Item construction normalizes again, producing `M`, `N`, and `A`. The original
final sort puts `A` first. The candidate detects the changed URL bytes and uses
that same final sorting path. It does not assume normalization is idempotent or
weaken identity to Unicode-equivalent string equality.

The change preserves subtitle association, metadata lookup, duplicate selection,
the natural filename comparator, literal-path ties, and folder normalization.
It adds no persistent state or filesystem access. Preparing items in a named
array extends that array's lifetime through the check; allocator traffic and
peak memory are not measured.

## Measurement

The new benchmark compiles exact production source snapshots for both variants.
It measures the full in-memory `makePlaylist` operation, including normalization,
the first sort, subtitle association, item construction, deduplication, and the
guard or final sort. Input generation and verification stay outside timing.
Fresh workers and alternating baseline/candidate order limit persistent-process
bias; both wall and process CPU time are retained.

The native study completed on October 19 in [workflow run
39322226036](https://github.com/Jagalite/illiquid/actions/runs/39322226036).
An independent October 20 audit matched all 14 baseline/candidate production
source hashes to baseline `33fff16155c3472960f88e04c72dfdfdefd56dcf` and PR head
`dd370843dceb180c6216604b6acc7f6cdb9b56bd`. The workflow checked out their synthetic
merge `4d0c46079bae104d34e391883358b61b7116a073`; its measured source bytes match
those intended revisions. Later documentation-only changes do not alter them.

Environment: macOS 26.6.2 arm64, Apple Swift 6.3.3, locale `en_US`, three logical
CPUs on the hosted runner. All 97 complete-output comparisons passed. All four
baseline/candidate debug/release runs passed 93 tests across 12 suites. The audit
checked complete snapshot hashes, alternating pair order, matching iteration
counts and output witnesses, and recomputed every wall/CPU median and paired
speedup from 1,020 samples (510 pairs).

The timing result is mixed: 49 of 85 case medians improved, and the candidate was
faster in 288 of 510 matched pairs. Among the 43 construction cases with more
than two inputs, 32 medians improved. The eight unchanged public-constructor
controls split evenly between higher and lower medians, consistent with runner noise.
These data do not establish a dependable improvement for every workload.

At 10,000 media URLs without subtitles, eight of nine medians improved:

- Unique names, shuffled: 386.796 to 350.787 ms, a 9.3% reduction. Individual
  paired speedups ranged from 0.877 to 1.486, including slower candidate pairs.
- Identical basenames in distinct directories, sorted: 214.682 to 176.985 ms,
  a 17.6% reduction; all six pairs improved (1.059 to 1.357 speedup).
- Multilingual names, sorted: 283.898 to 309.113 ms, an 8.9% regression in the
  median; paired speedups ranged from 0.860 to 1.187. This case establishes no
  dependable benefit.

Both subtitle-present 1,000-item cases had higher candidate medians: unique
names increased 2.3%, and multilingual names increased 1.5%. Their paired ranges
crossed parity. Skipping a redundant sort is correct, but these results support
only workload-specific performance claims and leave small/noisy differences
unresolved. No completed Linux timing study was present on the reviewed head.

The [permanent native receipts](PerformanceEvidence/PreparedPlaylistConstruction/macos)
retain the unmodified manifest, all timing samples, all 85 summaries, output
hashes and audit receipt. The [full native artifact](https://github.com/Jagalite/illiquid/actions/runs/39322226036/artifacts/12221017949)
also contains complete output snapshots and native test logs; it expires
November 2, 2026. Those files were audited, and their hashes are retained, but
their bytes remain in the hosted artifact.

## Validation and reproduction

On Linux, the same 93 tests across 12 suites pass against baseline and candidate
in both debug and release builds. The four logs and exact source/test hashes are
retained in the [test evidence](PerformanceEvidence/PreparedPlaylistConstruction/linux/tests).
The new suite compares complete models and exact URL representations
against the preserved original pipeline, covering normalized aliases, metadata,
duplicates, ambiguous subtitles, encoded segments, Unicode, authorities, and
relative URLs. It also checks the public constructor with unsorted items.

The benchmark compares complete outputs before collecting timings and retains
source fingerprints, compiler and locale information, calibration, raw samples,
and paired summaries. See the
[benchmark README](../Benchmarks/PreparedPlaylistConstruction/README.md).

```sh
bash Scripts/test-prepared-playlist-construction.sh --baseline -c release
bash Scripts/test-prepared-playlist-construction.sh -c release
python3 Benchmarks/PreparedPlaylistConstruction/run.py \
  --pairs 6 --target-ms 50 --output /tmp/illiquid-prepared-playlist
```

These are component measurements using synthetic URL listings. They exclude
directory enumeration, disk latency, media probing, decoding, rendering, and
time to first frame. They do not establish whole-player CPU, energy, memory, or
end-to-end folder-open improvements. Native macOS measurements qualify the
shipping Foundation implementation; Linux measurements are supplemental.
