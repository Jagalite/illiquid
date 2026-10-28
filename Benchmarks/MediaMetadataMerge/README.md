# Media metadata merge performance

This experiment measures source-attribution work inside complete production
metadata merges and per-episode `.plexmatch` lookups. It builds on the concurrent
[catalog-ID storage PR #163](https://github.com/Jagalite/illiquid/pull/163).
The frozen baseline is its exact `MediaMetadataHints.swift` at
`ed6bf4058bb576cdef36c5ee1b58f4fd85a6374b`. Both variants compile with the same actual
`MediaNameRecognition.swift` and `PlexMatchHints.swift`, so catalog-ID sharing is
already present in both versions and receives no credit in these measurements.

## Change and scope

An episode mapping adds episode identity but no source attribution. The baseline
still constructs a set and sorts the inherited source list on every merge, even
though the common list contains only `".plexmatch"`.

The candidate reuses source attribution when the override is empty and the
inherited array has zero or one entry. Uniqueness and sorting are already
satisfied in those cases. Every other source list retains the previous Set/sort
implementation. The existing catalog-ID helper, identity resets, provider
replacement, parsing, and metadata precedence are unchanged.

The production delta from PR #163 is a guarded assignment in `overriding(_:)`.
The retained array keeps Swift value semantics; regression tests mutate returned
copies and check that their inputs and the parsed index remain unchanged.
The `applying(_:)` benchmarks are unchanged-code controls.

## Reproduce

Use Swift 6.1 or newer and Python 3. The component uses Foundation only and can
run on Linux or macOS without FFmpeg, libass, or an application launch. The Linux
workflow pins Swift 6.2.4's official Ubuntu 24.04 container by digest. The native
workflow selects Xcode 26.6 on macOS 26.

If Kyoto is available, submit the complete command to the shared queue:

```sh
python3 /Volumes/seed1/Projects/kyoto/kyoto.py submit -- \
  python3 Benchmarks/MediaMetadataMerge/run.py benchmark \
  --output /tmp/illiquid-metadata-merge --pairs 8 --target-ms 75
```

Inspect the returned job with `show JOB_ID`, `logs JOB_ID`, and `wait JOB_ID`.
When Kyoto is unavailable, explain the limitation before running directly:

```sh
python3 Benchmarks/MediaMetadataMerge/run.py benchmark \
  --output /tmp/illiquid-metadata-merge --pairs 8 --target-ms 75
python3 Benchmarks/MediaMetadataMerge/run.py summarize \
  --output /tmp/illiquid-metadata-merge
```

Output must be new or empty. Put matching `swift` and `swiftc` executables on
PATH; `--swiftc` or `SWIFTC` selects the benchmark compiler only.
`--tests-only` runs all four baseline/candidate debug/release test combinations
and complete-output verification without timings. Repeat `--case ID` to select
timed cases; full verification still runs.

## Correctness and timing protocol

Both versions run the same independent expected-result tests and existing
PlexMatch regressions, in debug and release with warnings as errors. The driver
compares complete metadata snapshots, including absent fields, content identity,
catalog ID order and duplicates, attribution, and all recognized-name fields.
Parsing and fixture construction happen before timing.

Separate optimized modules contain the actual three production files. The same
driver is linked against each with `-O -whole-module-optimization`, Swift 6
checking, and no cross-module optimization. Each timed iteration visits a pool
of 16 inputs and consumes every returned model with a bounded checksum.
Snapshots, encoding, full comparisons, and receipts stay outside timing.

The baseline calibrates an operation count per workload; the candidate uses the
same count. Eight fresh-process pairs alternate AB/BA order and reverse case
traversal on alternating pairs. Measurements run serially. The summary retains
all paired ratios and their median/range for monotonic wall and process CPU time.
It validates order, operation counts, complete outputs, and checksums again.

Evidence contains the frozen baseline manifest, source snapshots/hashes,
compiler/flags/platform identity, compiled archive/executable hashes, test logs,
compressed complete verification outputs, calibration trials, and every timing
receipt. The dedicated workflow runs measurements on the research branch and
repeats correctness-only checks for pull requests.

These are in-memory metadata merge and lookup measurements. They exclude sidecar
file I/O, XML/text parsing, directory scans, UI responsiveness, native playback,
whole-player CPU, memory, and energy. Native qualification and measured findings
are recorded below when the cohort completes.
