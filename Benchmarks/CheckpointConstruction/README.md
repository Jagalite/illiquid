# Playback checkpoint construction

This experiment measures complete `PlaybackCheckpoint.record()` construction
against main revision `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`.

## Why this path

`PlaybackController` requests a checkpoint when playback progress changes by at
least ten seconds, and on pause, playlist changes, source changes, and shutdown.
The controller captures values; `CoalescingPersistenceWriter` constructs the
session record on its background writer queue. Explicit multi-file playlists
can have no collection folder.

The original checkpoint builder normalizes both the current source and each
visited playlist item to decide whether the source belongs to the collection.
It performs that scan even when `folder == nil` means the saved collection folder
will be nil regardless of the answer. For a folder playlist, it also repeats the
same source normalization for every visited item.

The candidate skips the membership check when the folder is absent or the
playlist is empty. Otherwise, it computes the source's supported local-file key
once and compares each item against that key. There is no persistent cache or
filesystem lookup. Invalid URL keys cannot match each other, and the saved index
is not used to infer membership. The provided folder remains an opaque value.
Record construction, deduplication, position sanitization, and saved metadata
continue through the same production initializer.

## Reproduce

Requires Swift 6.1 or newer with bundled Swift Testing, Python 3.9 or newer, and
the frozen baseline commit in the local Git history. No external Swift package
or native codec dependency is required.

```sh
python3 Benchmarks/CheckpointConstruction/run.py \
  --pairs 8 --target-ms 100 --output /tmp/checkpoint-construction

# Behavior only, baseline/candidate in both debug and release.
python3 Benchmarks/CheckpointConstruction/run.py \
  --mode tests --output /tmp/checkpoint-construction-tests

# A short experiment-mechanics check, not a full performance study.
python3 Benchmarks/CheckpointConstruction/run.py \
  --quick --pairs 2 --target-ms 30 --output /tmp/checkpoint-construction-smoke
```

Output directories must be new or empty. Builds run serially; do not run competing
benchmark cohorts on the same machine. Follow the repository's Kyoto build
coordination instructions when its shared queue is available. The GitHub workflow
runs the same experiment on macOS 26 with the repository's selected Xcode.

## What is compiled and checked

The runner compiles the complete, unmodified `PlaybackCheckpointWriter.swift`
into a separate `IlliquidPlayer` module. Its `IlliquidCore` dependency uses the
actual `FolderPlaylist`, `PlaylistMutation`, `NaturalFilenameOrdering`,
`NormalizedFileURL`, and `MediaSource` source files, plus the complete
`PlaybackSessionRecord` type and `PlaybackSessionStoring` protocol. The runner
checks the boundary before the unrelated atomic disk store and records both
full-source and compiled-source hashes. It rejects changes to any of these core
dependencies between the baseline and candidate.

The new checkpoint tests and existing session-record/deduplication tests run
against both revisions in debug and release with warnings as errors. They cover
folder membership, arbitrary saved indices, raw decoded URL aliases, Unicode,
unsupported authorities/credentials/ports, remote sources, duplicate metadata,
shuffle IDs, and invalid positions. These are selected-source component builds;
the ordinary PR workflows separately build the full application graph.

For timing, both production modules and the identical driver are compiled
separately with `-O -whole-module-optimization -swift-version 6`. The internal
checkpoint API is accessed using `-enable-testing` and `@testable import`, without
rewriting access levels or substituting the production implementation. Separate
modules keep repeated calls opaque to the driver optimizer.

## Measurement protocol

The full study has 28 workloads:

- Flat and folder playlists with 0, 1, 32, 1,000, and 10,000 items, targeting the
  last item.
- Flat/folder first-item controls and folder missing-item scans at 32, 1,000, and
  10,000 items.
- Nine 1,000-item cases: flat missing item, folder middle item, flat/folder Unicode
  aliases, unsupported source authority, remote source, all invalid item URLs,
  mixed valid/invalid items, and duplicate identities.

Inputs, expected outputs, URL metadata, and JSON encoders are prepared outside
timing. Expected folder membership and deduplication order follow known fixture
identities rather than the production matching/deduplication helpers. Before and
after every observation, the driver checks every record field and exact sorted
JSON output after fixing only `updatedAt`; it separately checks that the generated
timestamp falls within the construction interval. An all-field fingerprint must
match between variants. Each timed output contributes to a checked constant-time
checksum, and its result is released within the timed operation. Darwin
autorelease pools drain inside each operation for both variants.

Every observation runs in a fresh process. Calibration is separate, targets the
faster variant's requested duration using the lesser of wall and CPU time, and
uses a common iteration count for the pair with a 2,000,000-iteration cap.
Eight pairs alternate baseline-first and
candidate-first order. Both wall and process CPU nanoseconds are retained. The
summary reports per-record medians, ranges, and the median paired percentage
change. It also records the shortest wall/CPU loop durations and explicitly
flags any variant with an observation below one quarter of the requested target
as unqualified for timing. There is no speedup threshold in CI and no outlier
removal. A successful runner status establishes output parity and completion;
the measured values determine whether the change is useful.

The output contains raw observations, calibration trials, command logs, toolchain
and host details, source snapshots/hashes, binary hashes, and a summary. Partial
evidence is retained if a run fails.

## Scope

This measures the background construction of a checkpoint record, including its
remaining playlist deduplication and identity work. It does not measure JSON
encoding, disk I/O, queue delay, visible playback, frame rate, or battery use.
Flat-playlist construction remains linear for larger playlists because record
deduplication is unchanged. First-item controls and empty/small playlists are
included to expose overhead as well as wins.

## Native results

[Native macOS qualification](https://github.com/Jagalite/illiquid/actions/runs/40634906801)
passed on an Apple M1 virtual machine running macOS 26.6.2 and Apple Swift 6.3.3
through Xcode 26.6. Both revisions passed 22 component tests in three suites in
debug and release. All 448 observations (224 baseline/candidate pairs) passed
complete output parity, checksums, and minimum-duration qualification. The
shortest native CPU observation was 72.370 ms, above the 25 ms floor.

| Last-item workload | Baseline CPU per record | Candidate CPU per record | Median paired CPU change |
| --- | ---: | ---: | ---: |
| No folder, 1,000 items | 12.49 ms | 4.26 ms | -65.8% |
| No folder, 10,000 items | 132.81 ms | 42.42 ms | -66.5% |
| Folder, 1,000 items | 13.16 ms | 8.66 ms | -32.5% |
| Folder, 10,000 items | 113.38 ms | 74.86 ms | -34.3% |

All 32 pairs in these four workloads used less candidate CPU. Wall-time paired
reductions were 65.8–66.1% for flat playlists and 32.5–33.0% for folder playlists.
The absolute columns are separate medians; the percentage is the median of paired
ratios and need not equal the ratio of those displayed medians.

First-match folder controls changed by +0.7%, +1.3%, and +3.3% paired CPU at
32, 1,000, and 10,000 items. The remote-source control changed by +2.7%. No
improvement or tight performance-equivalence claim is made for those controls.
The singleton folder case changed by +5.6% (9.44 to 10.03 microseconds in separate
CPU medians), and the empty folder case by +14.9% (0.460 to 0.540 microseconds).
These results are retained alongside the substantial large-scan reductions.

The [complete native results and receipts](evidence/macos/README.md) include all
28 workloads, raw observations, source hashes, compilation/test logs, and the
exact review archive emitted by the successful job. The measured production and
harness bytes are unchanged by the later evidence/documentation commits. An
independent audit recomputed the statistics and verified output parity receipts,
sample ordering, duration flags, and source/log hashes.

The [supplementary Linux study](evidence/linux/README.md) independently passed
the same 448 observations and four test configurations. It showed about 65% less
CPU for long flat-playlist scans and about 30% less for folder scans, with more
timing variance. These are checkpoint-construction results; full application
integration and visible playback remain separate qualification scopes.
