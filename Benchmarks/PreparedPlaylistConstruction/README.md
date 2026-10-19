# Prepared playlist construction benchmark

This experiment measures avoiding the second natural filename sort inside
`FolderPlaylistDiscovery.makePlaylist`. Its media URLs have already been
normalized and sorted before item creation and order-preserving deduplication.
The public `FolderPlaylist(folderURL:items:)` initializer is an unchanged control.
The candidate reuses the first sort only when item construction preserves every
URL's exact UTF-8 representation and the locale has not changed. Other inputs
retain the original final sort. Lists with at most two final items also retain
the original path without a representation scan.

The baseline is commit `33fff16155c3472960f88e04c72dfdfdefd56dcf`. The runner compiles
seven exact, real Foundation-only production files. The candidate uses current
`FolderPlaylist.swift` and `FolderPlaylistDiscovery.swift`; the other five files
come from the same pinned baseline. Neither implementation is reproduced or
substituted in the harness. This benchmark is independent of the existing
`NaturalFilenameOrdering` experiment.

## Run

From the repository root on macOS:

```sh
python3 Benchmarks/PreparedPlaylistConstruction/run.py \
  --swift "$(xcrun --find swiftc)" \
  --output /tmp/illiquid-prepared-playlist-macos
```

On Linux, supply the desired `swiftc` path with `--swift` and set the runtime
library search path needed by that installation. No Swift package downloads are
required. Python 3, Git, Swift, and Foundation are the only dependencies.

For a development check, append `--quick --pairs 2 --target-ms 10`. Use
`--verify-only` to compile both variants and compare outputs without timing.
Evidence destinations must be empty to avoid mixing runs. `--max-media-size`
(default 10,000) and `--max-subtitle-size` (default 1,000) bound the corpus.

## Workloads

The default zero-subtitle matrix measures the real `makePlaylist` method at
0, 1, 2, 10, 100, 1,000, and 10,000 media URLs, with unique, multilingual, and
identical filenames in different directories. Each case has naturally sorted,
reversed, and deterministic shuffled input. Zero-subtitle cases dominate because
they avoid unrelated subtitle parsing and matching work.

Subtitle-present cases supply two subtitle URLs per media item and use shuffled
unique and multilingual names through 1,000 items. Small repeated-filename cases
at 2 and 10 items cover ambiguous subtitle associations. Large repeated stems
with subtitles are excluded because their quadratic matching workload belongs to
a different subsystem. Public-constructor controls use prepared items, include
all three filename patterns, and retain dates and ordered subtitle arrays.

Twelve additional untimed edge cases cover both entry points, three input orders,
and zero/two subtitles per media item. They include exact duplicates carrying
different item metadata, absent and present dates, numeric and case differences,
composed/decomposed Unicode, literal path ties, parent-directory normalization,
relative file URLs, localhost authorities, rejected remote file authorities,
non-file URLs, and literal percent/hash characters. A proven fallback case mixes
`file:///tmp/Z/%2E%2E/A/Same.mkv` with `/tmp/M/Same.mkv` and `/tmp/N/Same.mkv`:
item normalization exposes a new path segment, requiring the final sorting path
to restore the correct order. The edge fixture contains enough distinct items to
exercise the fast-path size boundary.

All data is synthetic. No media is opened, no directories are scanned, and no
filesystem metadata is read. Fixture generation, reference input sorting, test
metadata creation, and construction of items for the public-constructor control
are outside timing. Timed `makePlaylist` calls include their actual production
normalization, first sort, subtitle association, item creation, deduplication,
and final model construction. The small shared observer is included in both
variants and consumes a varying item position, subtitle count, and date value.

## Correctness and measurements

Every case must pass complete-output equality before any timed sample is
collected. Comparisons include folder URL, every item URL and its exact URL
representations, ordered external subtitle URLs and representations, and optional
date bit patterns. Full snapshots and SHA-256 hashes of outputs and URL order are
retained. Each timed pair also checks its consumed output witnesses.

The default run uses six alternating AB/BA pairs per case. **Every pair starts
fresh baseline and candidate worker processes**, so previous cases cannot leave
different allocator or Foundation state in long-lived workers. Launch, setup,
calibration, and measurement order alternate together. Each new worker warms up
the selected workload, and both workers receive the same calibrated iteration
count, targeting an average 50 ms per sample. Large operations need at least one
iteration and may exceed that target. Startup, fixture creation, serialization,
and calibration are excluded from reported samples.

The finite default matrix has 85 timed cases and 12 extra edge checks. Its target
sample budget is roughly one minute; large cases and process/fixture preparation
add wall time. Use the upper-bound options for a shorter development run.

The evidence directory retains source snapshots and hashes, driver sources,
compiler commands, compiler/OS/locale metadata, binary hashes, complete output
verification, every calibration and timed sample, worker PIDs, elapsed and process
CPU time, per-case medians, and paired speedup ranges. Environment settings,
including `SWIFT_DETERMINISTIC_HASHING`, are inherited and recorded rather than
silently changed.

Fresh processes reduce one source of measurement variation; they do not guarantee
that a small delta is an implementation effect. Inspect paired samples and the
unchanged constructor control. Linux measurements qualify this Foundation
workload on Linux. Native macOS results are needed for macOS performance claims.
The experiment measures pure playlist preparation, not filesystem scanning,
playback CPU usage, or end-to-end time to first frame.
