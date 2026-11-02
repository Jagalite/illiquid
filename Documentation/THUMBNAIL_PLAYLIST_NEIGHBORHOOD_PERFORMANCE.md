# Background thumbnail playlist neighborhood research

## Result and scope

The candidate removes the full-playlist URL projection from
`ThumbnailBackgroundScheduler.runPass`. On the native macOS CI host, planning
a middle selection in 100,000 items fell from **11.856 ms to 5.016 ms** in median
per-call wall time (57.7% lower). A last-item selection fell from **20.241 ms to
11.911 ms** (41.2% lower). Every 100,000-item workload was faster in all eight
paired trials.

This affects **opt-in background/library thumbnail generation**. Automatic
current-video preparation uses `runCurrent` and is outside the changed path.
These are component throughput measurements, not measurements of complete
background passes, decoding, interactive UI latency, playback frame rate, or
energy use.

The measured baseline is commit
[`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`](https://github.com/Jagalite/illiquid/commit/ea2ff568237e2667f7b1aeee67b11a44ebe95b72).
The measured candidate is
[`2d066cacc8d8fc844dcaf6008cfdaeda61b69010`](https://github.com/Jagalite/illiquid/commit/2d066cacc8d8fc844dcaf6008cfdaeda61b69010).
The [native component job passed](https://github.com/Jagalite/illiquid/actions/runs/40634599986/job/122638536177).
This report and its evidence are added in a documentation-only follow-up to that implementation.

## What changed

The scheduler previously started every library pass with:

```swift
let playlist = player.viewStore.playlist.map(\.url)
```

It then searched that array and selected only the four entries before and after
the first matching current URL. The entire projection happened even when the
current URL was nil. This is synchronous work on the scheduler's main actor,
before the existing detached ranking task.

The internal `ThumbnailPlaylistNeighborhood` helper now searches
`[FolderPlaylistItem]` directly and constructs only the requested window. Its
result contains at most nine URLs and nine distance entries. It stores concrete
collections, not an `ArraySlice`, a playlist reference, or a closure that captures
the playlist.

The behavioral contract is unchanged:

- The first equal URL anchors the window; URL equality is not replaced with path
  normalization or the separate `FolderPlaylist.index(of:)` identity policy.
- Windows are clipped at either playlist edge and preserve playlist order.
- Duplicate URLs remain in the URL sequence. The last occurrence within the
  window still overwrites that URL's dictionary distance.
- Empty, missing, and nil selections produce an empty neighborhood.
- Current, visible, discovered, neighboring, and recent candidates enter
  `ThumbnailPolicy.ranked` in the same order with the same metadata.

No persistent index or cache is added. Middle, last, and missing selections
still require a linear URL search. A nil selection returns immediately, and an
early match no longer requires first projecting all later items.

## Memory interpretation

The native runtime reported `MemoryLayout<URL>.stride == 16`. At 100,000 items,
the eliminated eager URL array has a nominal **1,600,000-byte element payload**
(about 1.53 MiB), before allocator bookkeeping and capacity effects. At 10,000
items, the corresponding payload is 160,000 bytes.

These figures describe the array's URL values, excluding URL objects and string
backing storage. They are not measured allocator totals, peak RSS, or an
equivalent reduction in whole-player memory. The experiment did not instrument
allocation counts. The defensible structural result is that neighbor planning
no longer constructs an O(n) URL projection; its output storage is bounded by
the nine-entry window.

The baseline's lifetime after its last source-level use is optimizer-dependent.
This report does not claim that the old array necessarily remained alive across
an async suspension.

## Native measurements

The campaign used Apple M1 (Virtual), arm64, macOS 26.6.2 (25G83), Xcode 26.6
(17F113), Apple Swift 6.3.3, and the macOS 26.5 SDK, targeting macOS 26.0. The
measured checkout was clean.

All times in this table are **microseconds per call**. Reduction compares the
two medians; paired reduction is the median of the eight within-pair reductions.
Negative reduction means a slower candidate. These are different statistics,
so both are retained.

| Playlist items | Selection | Baseline µs | Candidate µs | Reduction | Paired reduction | Faster pairs |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 0 | nil | 0.107 | 0.113 | -6.0% | -1.0% | 4/8 |
| 1 | first | 0.615 | 0.780 | -26.9% | -27.6% | 1/8 |
| 32 | first | 5.169 | 1.691 | 67.3% | 69.0% | 8/8 |
| 32 | middle | 6.670 | 3.044 | 54.4% | 48.7% | 7/8 |
| 32 | last | 7.446 | 5.773 | 22.5% | 31.7% | 6/8 |
| 32 | missing | 3.729 | 3.240 | 13.1% | 18.9% | 7/8 |
| 32 | nil | 3.233 | 0.114 | 96.5% | 96.5% | 8/8 |
| 1,000 | middle | 78.838 | 39.692 | 49.7% | 50.6% | 8/8 |
| 1,000 | last | 93.127 | 74.635 | 19.9% | 16.7% | 8/8 |
| 10,000 | first | 898.383 | 1.564 | 99.8% | 99.8% | 8/8 |
| 10,000 | middle | 1406.604 | 581.291 | 58.7% | 56.1% | 8/8 |
| 10,000 | last | 1864.273 | 1229.864 | 34.0% | 32.9% | 7/8 |
| 10,000 | missing | 1678.082 | 1351.767 | 19.4% | 25.2% | 5/8 |
| 10,000 | nil | 781.495 | 0.098 | >99.9% | >99.9% | 8/8 |
| 100,000 | first | 9033.229 | 1.537 | >99.9% | >99.9% | 8/8 |
| 100,000 | middle | 11855.688 | 5015.586 | 57.7% | 52.1% | 8/8 |
| 100,000 | last | 20240.882 | 11911.459 | 41.2% | 35.6% | 8/8 |
| 100,000 | missing | 14022.222 | 9925.307 | 29.2% | 29.0% | 8/8 |
| 100,000 | nil | 8347.042 | 0.094 | >99.9% | >99.9% | 8/8 |

Process CPU time moved in the same direction for the large workloads. At 100,000
items, middle-selection medians were 11.846 ms versus 4.986 ms (57.9% lower);
last-selection medians were 19.487 ms versus 11.915 ms (38.9% lower). Both CPU
comparisons were faster in all eight pairs. The
[complete summaries](PerformanceEvidence/ThumbnailPlaylistNeighborhood/summary.json)
retain CPU and wall-time ranges and all other workloads.

### Small-input tradeoff and variability

The single-item control regressed from **0.615 µs to 0.780 µs**, an absolute
increase of approximately **0.165 µs** (26.9% between medians); the candidate
was faster in only one of eight pairs. The change is therefore not a universal
latency improvement. The empty/nil control differed by roughly 6 ns between
medians, with four of eight faster pairs; this run does not establish a useful
change for that control.

Some smaller and missing-target workloads varied substantially. In particular,
the 10,000-item missing-target case was faster in five of eight pairs despite
a 19.4% reduction between medians. Do not treat every table percentage as an
equally strong result.

Nine of the 304 observations were shorter than 10 ms despite the 30 ms
calibration target: six candidate 32-item middle samples (4.525–5.880 ms), one
candidate 32-item last sample (9.091 ms), one baseline 10,000-item last sample
(9.764 ms), and one candidate 10,000-item missing sample (8.988 ms).
They remain included and individually identified in the
[qualification audit](PerformanceEvidence/ThumbnailPlaylistNeighborhood/qualification.json).
None of the 100,000-item observations was shorter than 10 ms.

## Correctness and integration

The same **six test functions** passed for the frozen baseline and candidate,
each in debug and release: four successful configurations, not 24 distinct
test functions. The tests include explicit edge windows and duplicate rules,
a decoded-URL fixture that bypasses the normalizing initializer, and a
10,000-item input.

An independent integer-label oracle enumerates 1,093 playlists of length zero
through six over three labels and checks five current-selection cases for each:
**5,465 neighborhood comparisons per configuration**. Expected selections and
distances come from the labels rather than the helper's URL search.

The separately compiled release probes also matched **40 complete output
traces**. Every measured baseline/candidate pair agreed on its full result
digest and per-call witness. There are no performance thresholds in the tests.

Full application-graph qualification is a separate
[`native-app-regressions` job](https://github.com/Jagalite/illiquid/actions/runs/40634599986/job/122638536385)
that builds the release app/test graph with pinned native dependencies and runs
`ThumbnailPlaylistNeighborhoodTests`, `ThumbnailBackgroundSchedulerTests`,
and `ThumbnailLifecycleRegressionTests`. It was still queued when this component
evidence was collected. The PR description records its later qualification
status; the component pass above must not be read as a full-app test pass.

The existing suites contain three optional fixture/screenshot paths controlled
by `ILLIQUID_PROGRESSIVE_PREVIEW_FIXTURE`,
`ILLIQUID_THUMBNAIL_IDLE_FIXTURES`, and
`ILLIQUID_THUMBNAIL_SETTINGS_IMAGE`. The workflow does not supply those inputs,
so even a successful default integration run does not qualify those paths.

This work has not performed live user interaction, visible playback, decoder
quality comparison, or physical-device memory/energy qualification.

## Measurement design

The runner extracts the two original neighborhood blocks from the pinned
baseline scheduler. Only the input expression and enclosing callable type are
adapted. The candidate is the complete production helper file. Both variants
use identical current production `FolderPlaylist`, `NormalizedFileURL`, and
`NaturalFilenameOrdering` sources.

The helper and identical public, non-inlinable probe compile into separate
optimized dynamic modules. The driver compiles separately, without cross-module
optimization, so repeated unchanged inputs still cross an opaque function call.
Each returned result contributes to a checked witness, and the final full
result is checked outside timing.

The 19 workloads have eight alternating baseline-first/candidate-first pairs:
**304 measured observations in fresh processes**, plus **119 retained calibration
observations**. Input construction and one checked warmup are outside timing.
Calibration selects a separate iteration count for each variant, then keeps
those counts fixed for all retained pairs. This gives the constant-time
nil/early-hit path a useful timing interval without requiring an extremely
long baseline batch.

Wall and process CPU measurements include result consumption and cleanup of one
autorelease pool around the whole batch. They describe repeated planning
throughput, not an isolated cold call or per-pass peak memory. No timing
observation was discarded. All medians, ranges, paired reductions, faster-pair
counts, ordering, result digests, and short-duration counts were independently
recomputed from the raw records without discrepancies.

To reproduce, follow the shared Kyoto queue instructions and native requirements
in the [runner README](../Benchmarks/ThumbnailPlaylistNeighborhood/README.md).
The hosted CI runner verified that the shared Kyoto queue was unavailable before
running its builds directly and serially.

## Evidence and concurrent work

The permanent [evidence directory](PerformanceEvidence/ThumbnailPlaylistNeighborhood/)
contains all measured and calibration records, complete numeric summaries, the
source/toolchain manifest, test and parity receipts, and the arithmetic audit.
Those files were recovered from the completed job's structured log records.
The recorded CI artifact also contains full verification traces, source
snapshots, binaries, and command logs; its identifier and SHA-256 digest are in
the qualification receipt.

During this investigation, the separate
[`perf/thumbnail-playlist-neighbors` branch](https://github.com/Jagalite/illiquid/tree/perf/thumbnail-playlist-neighbors)
appeared with an independent implementation of the same scheduler optimization
(initially observed at
[`e4a31ce`](https://github.com/Jagalite/illiquid/commit/e4a31ce145f69f117ece6b7d16799f302d573460)).
These are alternative implementations of the same production fix. The PR calls
out the overlap so integration can reconcile them as one change. This study
measures the candidate identified above, not the other branch.

The observed effect is consistent with eliminating the eager projection. It is
evidence from one native virtual host and synthetic playlists. It does not
establish real-world playlist sizes or background-generation frequency, and it
does not quantify UI, decode, total-process memory, or battery improvements.
