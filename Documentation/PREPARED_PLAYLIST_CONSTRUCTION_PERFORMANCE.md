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

Results and native qualification will be added after the paired runs complete.

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
