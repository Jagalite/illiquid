# Folder playlist lookup performance

## Question and scope

Can a folder playlist find a selected or last-watched file with less repeated URL
normalization while retaining exactly the same file-identity rules?

The baseline [`FolderPlaylist.index(of:)`](https://github.com/Jagalite/illiquid/blob/68274d1b09dcc866296321a5a8858efc297c4f19/Sources/IlliquidCore/Playlist/FolderPlaylist.swift) scans items with
[`NormalizedFileURL.representsSameFile`](../Sources/IlliquidCore/Utilities/NormalizedFileURL.swift). That helper computes both URLs' normalized
path identities on every comparison. The query URL is the same throughout the
scan. [`PlaybackController`](../Sources/IlliquidPlayer/Player/PlaybackController.swift) calls this lookup after folder discovery returns to
the main actor; `FolderPlaylist.initialIndex(restoring:)` also uses it when
restoring a previously watched file.

This study targets that lookup only. The baseline is integrated main at
`68274d1b09dcc866296321a5a8858efc297c4f19`. An independent concurrent PR,
[#36](https://github.com/Jagalite/illiquid/pull/36), covers filename-key caching
in sorting. This change does not depend on it or modify its sorting code.

## Change and behavioral argument

The production change is confined to `FolderPlaylist.index(of:)`:

1. Visit items in their existing index order and compute each item's existing
   `persistenceKey`, skipping unsupported items.
2. Compute the query's `persistenceKey` after the first valid item is found. Return
   `nil` if that query is unsupported.
3. Reuse the query key for the rest of the scan, returning the first matching
   index.

For a valid query in an all-valid scan of K items (K >= 1), this reduces key computations from
2K to K + 1. The lookup remains O(n). It retains one query key for the duration of
the call, with no persistent cache, stored index, invalidation logic, or Codable
schema change.

Item identities are still normalized individually. Synthesized decoding can
produce `FolderPlaylistItem` values whose URL did not pass through the public
initializer, so comparing raw paths or assuming every stored URL is canonical
would change behavior. Unsupported item URLs still cannot match a supported
query. The same local-authority checks, lexical path standardization, canonical
Unicode normalization, and first-match semantics remain in force. Normalization
continues to avoid filesystem identity resolution.

Empty playlists and playlists containing only unsupported items never normalize
the query, preserving the original short-circuit behavior. A first-item match
still needs two normalizations, so it is a useful control rather than an expected
speedup. An unsupported query can now return after the first valid item is found;
that is recorded separately from the valid-query workloads.

An excluded five-case smoke test of an eager-key prototype exposed extra query
work when every stored item was invalid. The lazy lookup above avoids that work.
The invalid-item controls remain in the final benchmark matrix. Smoke timings
are not included in the final statistics.

## Measurements

Measured on 2026-10-17 using Swift 6.3.2 on Linux x86_64, glibc 2.39, an Intel
Xeon Platinum 8573C, and `C.UTF-8` environment settings. The exact compiler flags,
source/harness hashes, locale receipts, raw timings, and summaries are retained in
[results.json](../Benchmarks/FolderPlaylistLookup/evidence/linux/results.json).

There are **18 workloads and 12 matched pairs per workload**, balanced six
baseline-first and six candidate-first pairs: **432 timed process observations**.
One baseline calibration per workload and one warmup in every process are
excluded. Each timed invocation batches 32 lookups; all times below are divided
by both the iteration count and 32, so they are **per individual lookup**. Every
batch matches the independent original predicate, and complete cross-process
receipts match. No measured observation was discarded.

The primary statistic is the median of the 12 paired baseline/candidate CPU
ratios. The CPU-change column is `100 * (1 / median_paired_speedup - 1)`; negative
values mean less CPU time. Absolute baseline and candidate medians are computed
independently and therefore need not yield exactly that percentage. Wall-clock
observations and their separate summaries are retained in the same JSON file.

| Workload | Baseline CPU µs | Candidate CPU µs | Paired CPU change | Faster pairs |
| --- | ---: | ---: | ---: | ---: |
| `empty` | 0.030 | 0.030 | -2.0% | 8/12 |
| `singleton-hit` | 12.080 | 11.777 | -3.8% | 7/12 |
| `singleton-miss` | 11.203 | 11.052 | -0.4% | 6/12 |
| `last-2` | 22.125 | 16.815 | -27.4% | 11/12 |
| `miss-2` | 25.063 | 17.778 | -30.8% | 12/12 |
| `last-16` | 202.337 | 103.820 | -51.9% | 12/12 |
| `miss-16` | 187.983 | 101.492 | -46.0% | 12/12 |
| `last-250` | 2,684.867 | 1,315.586 | -49.7% | 12/12 |
| `miss-250` | 2,740.000 | 1,356.523 | -51.0% | 12/12 |
| `last-1000` | 10,645.859 | 5,242.078 | -51.1% | 12/12 |
| `miss-1000` | 10,843.891 | 5,224.891 | -51.7% | 12/12 |
| `first-1000` | 9.812 | 10.255 | +2.9% | 3/12 |
| `middle-1000` | 5,168.891 | 2,619.438 | -49.1% | 12/12 |
| `long-path-1000` | 64,414.906 | 30,642.875 | -50.6% | 12/12 |
| `unicode-relative-1000` | 11,464.500 | 4,995.875 | -56.2% | 12/12 |
| `invalid-query-1000` | 7,066.906 | 5.938 | -99.9% | 12/12 |
| `invalid-items-1` | 0.785 | 0.788 | -0.3% | 7/12 |
| `invalid-items-16` | 12.383 | 11.903 | -2.1% | 7/12 |

The ordinary 250/1,000-item late-hit and missing-file cases, plus the middle hit,
use **49–52% less CPU time** by the paired estimator. All 12 pairs improve in each
of those cases. A 1,000-item last hit saves about **5.40 ms** at the independent
medians; a missing file saves **5.62 ms**. The additional saving in the
Unicode/relative/local-authority cohort is consistent with more expensive
query normalization; that mechanism was not separately profiled.
The long-path fixture is a stress case, with roughly 400 characters in its parent
path, rather than a measured distribution of users' folder layouts.

Controls qualify the result. A first-item hit still needs both identities and was
**2.9% slower** by the paired estimator, improving in only three of 12 pairs. Its
independent medians rise from **9.812 µs to 10.255 µs**, a **0.444 µs** difference
(4.5% by the independent-median ratio). Empty, singleton, and all-invalid-item
controls show small, inconsistent changes rather than a clear benefit. The large
invalid-query reduction reflects early rejection and is not a valid-folder
headline. The eager prototype's all-invalid extra-query cost is absent from the
final algorithm and full-run control results.

These results establish the component improvement on this Linux host. Native
macOS measurements are collected by the PR workflow; they are not yet part of
this initial report.

## Reproduction and validation

See [the benchmark guide](../Benchmarks/FolderPlaylistLookup/README.md) for the
exact build, timing, output-parity, and reproduction protocol. The benchmark uses
the production Foundation code and pinned baseline, not a rewritten model of
the optimized function. Fixture construction, sorting, independent expected
results, and receipt serialization are outside the timed operations.

**13 tests in three suites passed for both the baseline and final candidate, in
both debug and release.** Regression tests exercise the original comparator as a differential oracle,
including decoded URLs, lexical aliases, Unicode, local and unsupported
authorities, duplicates, empty and small playlists, missing targets, and the
last-watched fallback. Existing folder playlist and core utility tests are also
included in that qualification. The final production source has Git blob
`35e4ba72001a72199682fd629154f611b6995ac1`; the candidate test log records this
exact compiled-source snapshot. Independent checks after testing and benchmarking
confirmed that the source and harness hashes still match the reviewed checkout.

The first baseline release build stopped when the shared filesystem filled,
before test execution. After clearing task-owned temporary files, the identical
source/test snapshot passed on retry. The [original baseline log](../Benchmarks/FolderPlaylistLookup/evidence/linux/tests-baseline.log.gz),
[release retry log](../Benchmarks/FolderPlaylistLookup/evidence/linux/tests-baseline-release-retry.log),
and [final candidate log](../Benchmarks/FolderPlaylistLookup/evidence/linux/tests-candidate.log)
retain that sequence, commands, and source hashes. The excluded eager-prototype
smoke and its source are retained [separately](../Benchmarks/FolderPlaylistLookup/evidence/exploratory-eager/README.md).

The focused `folder-playlist-lookup.yml` workflow repeats the tests and paired
benchmark on macOS and retains its raw output as an Actions artifact. It has no
timing threshold. Existing repository workflows provide broader native
qualification.

## Limits

These are warm, in-memory component measurements. They do not include directory
enumeration, filesystem identity resolution, playlist construction, persistence
reads, decoding, or playback. Actual application time saved depends on the
number of items examined and the URL forms involved; workload frequencies were
not measured. A lower lookup cost on a main-actor path is useful, but these
measurements do not establish a whole-window latency, frame-rate, or battery
improvement.

Process CPU time reduces sensitivity to descheduling on a shared host, while
still reflecting CPU frequency, cache behavior, all process threads, and clock
sampling overhead. The reported method includes those costs and retains wall
measurements rather than subtracting an artificial control. CPU-clock behavior
is documented by Apple's
[clock(3) reference](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/clock.3.html).
Memory allocation counts and peak memory were not measured.
