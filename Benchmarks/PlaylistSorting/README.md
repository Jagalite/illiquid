# Playlist sorting performance qualification

Compare the actual `PlaylistMutation.sorted` implementation from integrated
`main` at `33fff16155c3472960f88e04c72dfdfdefd56dcf` with the working tree.
This is the playlist mutation sorter used after folder discovery, by explicit
playlist sort commands, and during multiple-file preparation. It is separate
from source-browser sorting and `NaturalFilenameOrdering.sort`.

## Reproduce

Requires Python 3, Swift 6.1 or later with Swift Testing, and the baseline commit
in local Git history. Native builds use the application's macOS 26 deployment
target. Always use a new output directory.

```sh
python3 Benchmarks/PlaylistSorting/run.py \
  --output /tmp/illiquid-playlist-sorting --pairs 6 --target-ms 60
```

Use `--tests-only` to run behavior checks without timing. `--swift` selects a
toolchain executable or wrapper; `--baseline` selects another full commit SHA.
`--sizes` and `--workloads` restrict the matrix. The default covers 10, 1,000,
and 10,000 items across eight workloads in both ascending and descending order.

## Method

The runner stages complete production files for `PlaylistMutation`,
`FolderPlaylist`, `NaturalFilenameOrdering`, and `NormalizedFileURL` into two
separately compiled Swift packages. Both use the same harness and repository
tests. The metadata type and comparison logic are not replaced with models.

Both variants run the repository's playlist mutation and sorting tests in debug
and release. The independent harness compares complete output sequences and
original-item equality, including dates and subtitle arrays. It also checks
the full exact fixture before timing each size/workload.

Fixtures cover shuffled, sorted, reverse-sorted, and repeated names; unique,
tied, and missing dates; and items with populated subtitle metadata. Setup,
normalization in item construction, and two warmup sorts are outside timing.
The missing-date fixture starts in ascending natural-name order in both
directions, matching the output of folder playlist construction.
Each measured call includes key preparation, sorting, result construction and
destruction, plus the same small count/endpoint checksum in both variants.

Six fresh-process pairs alternate baseline/candidate order and use identical
iteration counts. Reports retain all observations, medians, ranges, paired
changes, source hashes, compiler details, and correctness traces. No timing
threshold is used as a unit-test assertion.

## Contracts and scope

Name ordering retains Foundation's localized natural comparison and normalized
item-ID tie breaks. Date ordering retains its distinct literal original-path
fallback. Descending order reverses the comparator operands, including
missing-date placement. Complete ties retain input order and full item values.

The existing `Playlist restoration qualification` workflow runs the paired study
on macOS alongside playlist/restoration regressions. The repository's
`Restoration and thumbnail regressions` workflow builds the actual application
graph and runs the complete native release suite.

These are complete sorter component timings. They do not measure disk discovery,
SwiftUI rendering, decoding, frame rate, energy, or whole-player CPU usage.

## Retained study

The completed October 19 Linux study, source receipts, exact ordering traces,
and original runner snapshot are in [`Results/linux/`](Results/linux/).
See [the report](../../Documentation/PLAYLIST_SORTING_PERFORMANCE.md) for results,
limitations, and the current native qualification link.

The original Linux observation field `order` contains the playlist sort mode;
the original execution-order field was overwritten when merging harness output.
Execution order remains recoverable from observation-array sequence and the
retained command log, which were audited for six balanced pairs per case. The
current runner uses a distinct `execution_order` field for native and future
studies. This reporting correction does not change the measured Swift code.
