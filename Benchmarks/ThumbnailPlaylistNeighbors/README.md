# Thumbnail playlist neighbor construction

Background thumbnail scheduling previously projected every playlist item to a new
URL array before finding the current video and selecting at most four neighbors
on either side. This work runs synchronously on the main actor at the start of
each eligible background pass.

The bounded helper searches the original item array directly and copies only the
selected window. It stores at most nine URL values and nine distance entries.
A nil current video returns immediately; an absent video still requires a linear
search. It preserves exact URL equality, the first matching anchor, playlist
order, duplicates, clipping at the ends, and the previous last-occurrence distance
for duplicate URLs.

The production change is limited to:

- `Sources/IlliquidApp/App/ThumbnailPlaylistNeighbors.swift`
- The preparation block in `ThumbnailBackgroundScheduler.runPass`

## Results and platform qualification

[The research report](RESULTS.md) records a successful Linux component run,
including exact raw measurements and source, executable, and test receipts. These results establish the portable algorithm comparison. They do not
establish a macOS application build or macOS performance. The dedicated native
workflow supplies those separate checks; consult the report and workflow status
for their current qualification.

## Reproduce

Use a complete checkout, Python 3, and the repository's native macOS/Swift
toolchain for target-platform evidence. The standalone component runner also
supports Linux with Swift; its results must be labeled with that platform.
The baseline commit must be available in Git history.

```sh
python3 Benchmarks/ThumbnailPlaylistNeighbors/run.py \
  --output /tmp/thumbnail-neighbors --pairs 6

# Behavior checks only, in both debug and release configurations:
python3 Benchmarks/ThumbnailPlaylistNeighbors/run.py \
  --output /tmp/thumbnail-neighbors-tests --tests-only
```

Output directories must be new or empty. Compilation uses the shared Kyoto queue
when its documented executable exists; otherwise the runner announces the
limitation before compiling separate temporary packages serially. The workflow
also builds the full native application graph and executes the relevant thumbnail
policy, scheduling, cancellation, and lifecycle tests with the pinned native SDK.

## Baseline and behavior checks

The baseline is commit `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`. The runner
extracts that commit's exact eager map, anchor, neighbor-window, and distance
blocks from `ThumbnailBackgroundScheduler.runPass`. It replaces only the
caller's `player.viewStore.playlist` expression with the initializer's
`items` parameter, and wraps the blocks in the new helper's interface.

Both variants compile the same real `FolderPlaylistItem`, URL normalization,
filename ordering, and thumbnail policy sources in `IlliquidCore`. The
helper compiles in a separate `IlliquidApp` module; the probe uses testable
access without cross-module optimization. Source, executable, toolchain,
configuration, and command receipts are recorded.

The same nine Swift Testing tests run against both variants in debug and release.
They cover empty/nil/missing inputs, a singleton, explicit boundary windows,
duplicate anchors and distances, URL identity, 256 deterministic differential
cases, and downstream ranked-candidate equivalence.

## Measurement method

The probe measures synchronous helper construction for 10, 10,000, and
100,000 playlist entries, with current nil, first, middle, last, or missing.
Fixture and independent query construction, warmup, result serialization, and
JSON output are excluded from timing. The timed loop includes result ownership
and checksum work; there is no empty-loop subtraction.

Each workload is calibrated toward 30 milliseconds per sample. The six sample
pairs alternate baseline/candidate and candidate/baseline order, rotate workload
order, and execute each sample in a fresh process. Exact URL and distance
receipts and per-call checksums must agree across variants. Raw measurements and
paired wall/CPU summaries are retained.

The recorded platform's `MemoryLayout<URL>.stride` supports a structural description of
the eliminated array: the old full projection holds `playlist.count` URL
values, while the new output holds at most nine. Multiplying count by stride
describes element storage only. It excludes array headers, allocator rounding,
URL backing objects, and the shared input playlist; it is not a measured live-heap,
RSS, or application-footprint reduction.

These measurements concern neighborhood preparation. The full scan remains for
late or absent matches. Playback frame rate, decoding, energy, and visible UI
latency require separate application-level measurements.
