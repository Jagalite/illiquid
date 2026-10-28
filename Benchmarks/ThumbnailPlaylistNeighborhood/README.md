# Thumbnail playlist neighborhood

## Finding

Before this change, `ThumbnailBackgroundScheduler.runPass` projected the complete
playlist into a new `[URL]`, found the first current URL, and selected a window of
at most nine URLs. This is the opt-in background/library thumbnail path.
The projection ran on the main actor, including when the current URL was absent
or nil.

The baseline is commit
[ea2ff568237e2667f7b1aeee67b11a44ebe95b72](https://github.com/Jagalite/illiquid/blob/ea2ff568237e2667f7b1aeee67b11a44ebe95b72/Sources/IlliquidApp/App/ThumbnailBackgroundScheduler.swift#L273-L290).

`ThumbnailPlaylistNeighborhood` now searches the existing playlist items and
copies only the selected window. It returns an owned array and distance
dictionary with at most nine entries. The helper is synchronous and does not
store the input playlist or an `ArraySlice` in its result. This matters because
an escaping slice can retain its entire original allocation; see
[Swift's ArraySlice documentation](https://developer.apple.com/documentation/swift/arrayslice).

The change preserves the original behavior:

- The first equal URL anchors the neighborhood.
- The window includes up to four entries on each side, in playlist order.
- Repeated URLs remain in the output array.
- Later occurrences in the window overwrite earlier dictionary distances.
- URL equality is used directly, without changing normalization or consulting
  `currentPlaylistIndex`.

For a playlist of N items, the full N-element temporary URL array is eliminated.
The new output storage is bounded by the nine-item window. This is a source-level
allocation improvement, not a measurement of process RSS, peak memory or a leak.
The old array's lifetime across an async suspension is not assumed: optimized ARC
may already release it at its last use.

| Query | Previous selection work | New selection work |
| --- | --- | --- |
| No current URL | Project all N URLs | Return empty immediately |
| Current URL at the front | Project all N URLs, then find the match | Find the match and copy the small window |
| Current URL at the tail | Project and search N URLs | Search the original items and copy the window |
| Current URL missing | Project and search N URLs | Search the original items |

## Concurrent work

[PR #132](https://github.com/Jagalite/illiquid/pull/132) and
[PR #135](https://github.com/Jagalite/illiquid/pull/135) appeared during this
investigation with equivalent production changes. This branch is an independent
qualification of the same optimization. The implementations and competing
benchmark files should be reconciled into one production change. The related
branches have not been modified by this work.

## Qualification

The component runner compiles the complete production helper and its actual
`FolderPlaylistItem`, `NormalizedFileURL` and `NaturalFilenameOrdering`
dependencies. The baseline helper is assembled from the two unchanged
map/anchor/window/distance blocks in the pinned scheduler. Only the input
expression and surrounding declaration are adapted. Source and binary hashes
are recorded.

Both variants run the same differential tests in debug and release builds.
The tests cover every anchor in small playlists, large playlists, nil and
missing current URLs, duplicates, seeded reordered inputs, decoded URL forms,
and independence from later input mutations.

Timing uses separate release-built SwiftPM modules for the helper and driver,
with no cross-module optimization. There are 19 workloads: empty and eight-item
controls, then front, middle, tail, missing and nil queries for 512, 10,000 and
100,000 items. Each observation uses a fresh process and three warmup calls.
Input construction and URL normalization are outside the timed region.
`withExtendedLifetime((playlist, current))` keeps both fixture roots alive through
the loop and both final clock reads, excluding input destruction from timing.

Eight balanced AB/BA pairs produce 304 observations. Workload order rotates
between pairs. Baseline and candidate iteration counts are independently
calibrated toward 50 ms and results are normalized per call. Every timed call
contributes to an observable checksum; ordered URLs and the complete distance
dictionary are compared across variants. Wall and process CPU time include loop
and checksum overhead, with no subtraction.

The native regression job compiles the complete application graph and runs
`ThumbnailPlaylistNeighborhoodTests`, `ThumbnailBackgroundSchedulerTests`,
`ThumbnailPolicyTests`, `ThumbnailSchedulingPolicyRegressionTests` and
`ThumbnailLifecycleRegressionTests`. Existing tests that require optional media
or screenshot fixtures retain their own guards. This job does not qualify live
playback, displayed frames, energy use or end-to-end thumbnail latency.

## Reproduce

Use the shared Kyoto queue when available, as required by `AGENTS.md`. For example,
submit the component command below with `kyoto.py submit --`, and inspect the
result with `show`, `wait` and `logs`. The hosted workflow reports when Kyoto is
unavailable and compiles serially in its isolated checkout.

```sh
python3 Benchmarks/ThumbnailPlaylistNeighborhood/run.py \
  --pairs 8 --output /tmp/illiquid-thumbnail-neighborhood
```

The output directory must be new or empty. The runner requires macOS and Swift,
plus the pinned baseline commit in Git history (`actions/checkout` uses full
history for this job). Results include manifests, exact output receipts, debug
and release test logs, calibration, every raw timing observation, and a summary
with all paired samples.

## Current qualification record

The production helper matched the baseline in all six test functions for both
debug and release in the [first component job](https://github.com/Jagalite/illiquid/actions/runs/40634639998/job/122638660357).
Its timing measurements are retained as exploratory evidence and are excluded
from performance claims: that driver did not bind the input playlist lifetime,
and nominally constant-work nil queries scaled with fixture size.

The corrected driver explicitly extends both input lifetimes through the final
clock reads. The [corrected native run](https://github.com/Jagalite/illiquid/actions/runs/40636216399)
is queued at the time of this documentation commit. Native integration and final
timing qualification will be recorded before this study is marked complete.
