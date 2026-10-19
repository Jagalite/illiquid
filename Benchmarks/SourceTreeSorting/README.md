# Source-browser sorting qualification

This experiment compares the exact sorter from integrated `main` at
`33fff16155c3472960f88e04c72dfdfdefd56dcf` with the working-tree sorter. It
measures complete source-entry sorting calls, including temporary filename keys,
index sorting, result construction, and result destruction.

The change affects Files Only/Media ordering and folder sibling ordering when
the browser rebuilds its immutable row input. Query-only searches already reuse
cached rows. Sorting runs on the existing browser actor; this is not a playback
decoder, frame-rate, or end-to-end GUI benchmark.

## Reproduce

Requires Python 3, Swift 6.1 or later with Swift Testing, and the pinned baseline
commit in the local Git history. Use a new output directory for each invocation.

```sh
python3 Benchmarks/SourceTreeSorting/run.py \
  --output /tmp/illiquid-source-tree-sorting \
  --pairs 6 --target-ms 60
```

For behavior checks without timing:

```sh
python3 Benchmarks/SourceTreeSorting/run.py \
  --tests-only --output /tmp/illiquid-source-tree-sorting-tests
```

`--swift` selects a toolchain executable or local wrapper. `--sizes` and
`--workloads` restrict the workload matrix. The default sizes are 10, 100, 1,000,
and 10,000 entries. The runner does not download a toolchain or dependencies.
In a shallow checkout that lacks the baseline, fetch the pinned commit first.
`--baseline` selects a different full commit SHA and records it in the receipt.
The retained October 17 Linux study used `68274d1b09dcc866296321a5a8858efc297c4f19`;
its measured production declarations and runner are archived beside its results.
After a subsequent integration, the unchanged sorter patch was applied to the
new main revision above for the native comparison.

## What is compiled and checked

The runner extracts the unchanged entry/sort declarations from
`Sources/IlliquidApp/UI/SourcesSidebar.swift` for each revision and compiles them
with the complete actual `MediaNameRecognition.swift` core source. This avoids
unrelated SwiftUI/native dependencies without replacing the entry representation
or comparator with a benchmark model. Extraction fails if its unique declaration
boundaries change. Source hashes and the staged Swift files are retained.

Both revisions run the same 12 repository semantic tests in debug and release.
The standalone harness additionally compares complete output ordinal sequences
for 18 fixtures under all 27 tri-state configurations in each build mode. It
checks that every returned entry exactly equals its original entry, including
metadata, dates, visibility paths, and URLs.

Before timing each size/workload, the runner also compares the full output order
and metadata of that exact fixture between revisions. One copy of the equal
ordinal sequence is retained in `verified-fixtures/`. The measured loop uses a
small observable count/endpoint checksum, identical in both variants, rather
than paying for full verification inside the measured interval.

## Measurement method

- Baseline and candidate are separately compiled release executables, using the
  same fixture and harness source.
- Each process constructs its original entries and performs two warmup sorts
  before timing. Filename keys inside production `sorted()` are rebuilt and
  timed on every iteration.
- A preliminary invocation selects a shared iteration count for both variants.
  Six pairs alternate baseline/candidate and candidate/baseline process order.
- Reports include every observation, medians, ranges, paired percentage changes,
  the Swift version, OS, locale, and the entry/index strides.
- Timing assertions are intentionally absent from unit tests and CI. Interpret
  measured differences together with their ranges and host conditions.

The workloads include random/sorted/reverse filenames, repeated basenames in
different directories, folders mixed with media, unique dates in both directions,
repeated/missing dates with name fallback, date-only/type-only/all-off controls,
and real populated recognition metadata. Fixtures use generated URLs and require
no media files or filesystem scans.

## Native integration

`.github/workflows/source-tree-sorting.yml` runs the component qualification on
macOS and separately builds the real application/test graph with the repository's
pinned native dependencies. The integration job exercises the sorter, source
folder model, browser filtering, media organization, and empty-folder visibility.

The component benchmark measures sorting service time on its host. It does not
measure resident memory, energy, initial filesystem discovery, total sidebar
refresh latency, or user-machine playback performance.
