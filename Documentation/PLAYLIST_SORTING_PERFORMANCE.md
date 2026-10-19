# Playlist reordering performance study

## Finding and scope

Caching comparison keys within `PlaylistMutation.sorted` and sorting original
indices reduces complete sorter latency in the measured Linux workloads. At
10,000 items, shuffled name sorting fell from 606.1 to 338.2 ms ascending, and
repeated-basename sorting fell from 4,068.6 to 452.0 ms. One naturally ordered,
missing-date case had a 1.0 ms higher candidate median with mixed paired results;
this study does not establish an improvement for every input.

These are Linux component measurements, not a claim about physical Mac or
whole-player performance. Consult [PR #62](https://github.com/Jagalite/illiquid/pull/62)
for native macOS measurements, workflow receipts, and current qualification
status. The PR runs the paired component study on macOS and the existing native
application regression workflows.

## Why this area

`PlaylistMutation.sorted` is used by `PlaybackCoordinator` in
`PlaybackController.swift` when applying folder discovery results, executing an
explicit playlist sort, and preparing multiple files. The first two paths
reorder the playlist on the main actor. The folder
and multiple-file paths request descending date order. Reducing work here can
reduce the sorting portion of those operations; the experiment does not measure
disk discovery, UI rendering, decoding, playback frame rate, or energy.

This method is separate from the source-browser sorter and the optimized
`NaturalFilenameOrdering.sort` used during playlist construction. Subsequent
user-requested and date-based reordering goes through `PlaylistMutation.sorted`.

The original comparator repeatedly extracts basenames and, when names tie,
normalizes item IDs. It also sorts the complete item records. The candidate:

- Prepares basename keys once for name sorting.
- Creates basename keys lazily for date ties, leaving unique-date comparisons
  free of basename extraction.
- Caches normalized IDs lazily when natural names compare equal in name mode.
- Sorts original integer indices and materializes the final item array once.

All caches are local to one call. There is no persistent invalidation state,
public API change, or change to stored item metadata. On the measured Linux
runtime, an item has a 40-byte stride and an integer index an 8-byte stride.
This explains a data-movement opportunity; memory usage and allocation counts
were not measured. Unique-date comparisons do not use filename caching; their
measured gains are consistent with reduced record movement from index sorting.
The experiment does not isolate the individual costs within that change.

## Ordering and metadata contracts

Name sorting still uses Foundation's localized natural basename comparison,
then normalized item ID as its tie break. Date sorting compares unequal known
dates chronologically and places known dates before missing dates in ascending
order. Equal or both-missing dates fall back to natural basenames and the
literal original URL path. These two tie breaks intentionally differ.
Descending sorting reverses the full comparator, including missing-date
placement. Complete ties preserve input order.

The implementation returns the original items. It preserves dates, duplicate
records, subtitle array order and multiplicity, and exact URL representations.
Tests include relative and decoded URLs, lexical aliases, Unicode, remote URL
identities, natural-name ties, date ties, and stable complete ties.

## Experiment

The baseline is integrated main at
`33fff16155c3472960f88e04c72dfdfdefd56dcf`. The measured candidate production
files, harness, runner, and tests match published commit
`7b78a1de66ed530f7f70474e208670da271d1d16` byte for byte. The subsequent runner
receipt-field correction described below does not change the measured Swift
code. Source hashes and publication checks are retained with the observations.

The runner compiles four complete production source files into separate
baseline and candidate packages: `PlaylistMutation`, `FolderPlaylist`,
`NaturalFilenameOrdering`, and `NormalizedFileURL`. It does not substitute
model types or an extracted comparator. Both variants use the same test and
harness sources and run through the public sorting method.

The October 19, 2026 study used Swift 6.3.2 on x86_64 Linux 6.18.55 with glibc
2.39, nine available logical CPUs, and Foundation locale `en_001`. The local
Swift wrapper selects the integrated Swift driver and supplies the toolchain's
shared-library path; its exact contents are retained. macOS CI uses its native
Xcode toolchain. Compiler and environment details are in `environment.json`.

The matrix covers 10, 1,000, and 10,000 items; eight workloads; and both
directions: 48 cases in total. Six fresh-process pairs per case alternate which
variant runs first, producing 576 observations with matched iteration counts.
All 48 cases have three baseline-first and three candidate-first pairs.
Fixtures and two warmups are prepared outside timing. Every measured call
includes local key preparation, sorting, output construction/destruction, and
the same small count/endpoint checksum. No samples are discarded.

Ordinary timing fixtures have unique media URLs and empty subtitle arrays. The
metadata workload carries six subtitle URLs per item. Repeated-name fixtures
use identical basenames in distinct directories. Missing-date fixtures begin
in ascending natural-name order for both directions, representing the output
of folder playlist construction before the requested date sort.

## Results

The table reports the median milliseconds per complete sort for 10,000 items.
Change is candidate median divided by baseline median minus one. It is not
the median paired change; both statistics and all ranges are retained.

| Workload | Baseline ms | Candidate ms | Change |
|---|---:|---:|---:|
| Random names, ascending | 606.079 | 338.217 | −44.2% |
| Random names, descending | 555.585 | 332.796 | −40.1% |
| Already sorted names, ascending | 27.413 | 23.365 | −14.8% |
| Already sorted names, descending | 28.514 | 21.101 | −26.0% |
| Reverse-sorted names, ascending | 27.636 | 22.088 | −20.1% |
| Reverse-sorted names, descending | 28.479 | 21.278 | −25.3% |
| Repeated basenames, ascending | 4,068.636 | 451.959 | −88.9% |
| Repeated basenames, descending | 4,275.653 | 442.955 | −89.6% |
| Unique dates, ascending | 7.227 | 3.801 | −47.4% |
| Unique dates, descending | 6.850 | 3.609 | −47.3% |
| Tied dates, ascending | 434.549 | 255.328 | −41.2% |
| Tied dates, descending | 455.649 | 237.952 | −47.8% |
| Missing dates, ascending | 30.029 | 30.992 | +3.2% |
| Missing dates, descending | 32.059 | 25.228 | −21.3% |
| Names with subtitle metadata, ascending | 687.833 | 381.775 | −44.5% |
| Names with subtitle metadata, descending | 703.817 | 372.539 | −47.1% |

At 1,000 items, random ascending names fell from 69.878 to 34.571 ms
(−50.5%), repeated ascending basenames from 405.727 to 50.018 ms (−87.7%),
and missing-date descending sorting from 2.661 to 2.257 ms (−15.2%).
All 10-item and 1,000-item case medians were lower. Across all sizes,
47 of 48 case medians were lower; this count is descriptive, not a statistical
significance test or a universal nonregression guarantee.

The missing-date ascending case at 10,000 items deserves separate treatment.
Its candidate median was 0.963 ms higher (+3.208%). Baseline observations ranged
from 27.218 to 128.293 ms and candidate observations from 23.951 to 36.603 ms.
Three pairs were faster and three slower, with a median paired change of
−0.543%. This establishes no dependable benefit for that input and does not
establish a consistent regression.

Other cases also contain variation: random ascending names at 10,000 items
range from 575.369 to 727.130 ms in the baseline and 320.859 to 828.813 ms in
the candidate. The candidate's high outlier is retained. These medians do not
establish a tail-latency guarantee, and synthetic workload gains should not be
interpreted as equal reductions in total folder-open time.

## Correctness and evidence

Both variants passed all 12 playlist mutation/sorting tests in debug and
release: 48 test method executions. The independent harness produced exact
baseline/candidate agreement for 30 fixtures across four sort configurations
(120 output traces) in each build mode. All 48 timing fixtures were also
verified before timing, including their complete output permutation and
original item values. The evidence audit independently recomputed all
48 summaries and checked observation order, checksums, and source hashes.

Reproduction instructions are in
[`Benchmarks/PlaylistSorting/README.md`](../Benchmarks/PlaylistSorting/README.md).
The permanent Linux evidence is in
[`Benchmarks/PlaylistSorting/Results/linux/`](../Benchmarks/PlaylistSorting/Results/linux/):
all observations and summaries, environment and source receipts, command logs,
the original runner and Swift wrapper, four test logs, and compressed complete
correctness traces. The compressed traces are JSON in a standard gzip archive.

The original Linux runner used `order` both for execution order and the sort
criterion; merging harness output overwrote the former. The original receipts
are preserved. Observation sequence and the independent command log confirm
the actual balanced run order. The current runner records execution order in
the separate `execution_order` field for subsequent studies.
