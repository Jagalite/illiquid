# Background thumbnail playlist neighbor projection

## Finding and scope

Baseline: `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`.

`ThumbnailBackgroundScheduler.runPass` projected every `FolderPlaylistItem.url`
into a new array before looking for the current video. It then kept only the
current item and up to four entries on each side. This made the temporary URL
array proportional to playlist length, including passes with no current video
or with a current URL absent from the playlist.

This work happens synchronously on the main actor before the scheduler submits
thumbnail ranking to a detached task. It is reachable when background thumbnail
generation is enabled and the scheduler admits a pass. Background generation is
opt-in; normal playback without those passes does not receive this improvement.

The finding concerns temporary allocation traffic and neighbor-selection cost.
It is not an unbounded cache or a leaked video frame. The existing playlist,
thumbnail images, decoding buffers, and disk cache are outside this change.

## Change

`ThumbnailPlaylistNeighbors` searches the existing playlist items and copies
only the selected window. It owns an array and a distance dictionary with at
most nine entries each, and it does not retain the playlist or a slice of its
backing storage. A nil current URL returns empty results immediately.

The helper preserves the scheduler's existing rules:

- Match the first item using Foundation `URL` equality. Do not substitute a
  normalized persistence identity or the player's current index.
- Select the same half-open window, from `max(0, anchor - 4)` through
  `min(count, anchor + 5)`.
- Preserve playlist order and repeated URLs in the window.
- Preserve the last occurrence's distance for duplicate URLs in the dictionary,
  including a repeated current URL overwriting distance zero.
- Return empty neighbors and distances when the current URL is absent.

The scheduler still combines current, visible, discovered, neighboring, and
recent URLs in the same order. It uses the same ranking, pass cursor, exclusion
policy, cancellation checks, and generation checks. No asynchronous boundary
was added or removed.

Finding a non-nil current URL still takes up to O(n) comparisons. A match near
the end and a missing match therefore retain linear search cost. The bounded
copy removes the independent O(n) URL projection; it does not make every pass
constant-time.

## Reproduction and method

The runner is
[`Benchmarks/ThumbnailPlaylistNeighbors/run.py`](../Benchmarks/ThumbnailPlaylistNeighbors/run.py).
It stages the complete production helper and actual playlist/core dependencies
into a small component package. The baseline wraps the original scheduler's
projection and distance statements, with a check against the pinned source.
The surrounding SwiftUI application and native media frameworks are not mocked
or compiled in this component package.

```sh
python3 Benchmarks/ThumbnailPlaylistNeighbors/run.py \
  --output /tmp/thumbnail-neighbors-timing --pairs 6 --target-ms 100

# Linux/glibc only; allocation instrumentation is a separate cohort.
python3 Benchmarks/ThumbnailPlaylistNeighbors/run.py \
  --output /tmp/thumbnail-neighbors-allocations \
  --allocations --skip-tests --pairs 2
```

Use fresh output directories. `--swift` selects a compiler explicitly.
`--tests-only` runs the focused correctness gates without a timing campaign.
When the shared Kyoto queue is available, submit these commands through it as
required by `AGENTS.md`; otherwise record its absence and run isolated builds
serially.

Inputs cover empty, 16-, 512-, 10,000-, and 100,000-item playlists, with no
current URL, a missing URL, and first/middle/last positions. The largest input
is a scaling stress case, not an observed user-library size. Fixture creation,
normalization, and warmup are outside the measured operation. Complete neighbor
outputs are checked against a reference outside the timing interval.

Timing uses optimized Swift builds, fresh processes, alternating baseline-first
and candidate-first pairs, and per-operation wall and process CPU measurements.
Each variant is calibrated separately because eliminating an entire scan for
nil/early anchors can produce very different operation costs. Iteration counts
and raw observations are retained. Timing runs do not load the allocation meter.

The separate Linux allocation probe counts successful `malloc`, `calloc`, and
`realloc` requests and their cumulative requested bytes around the operation.
Those values describe allocation traffic, not live heap, peak memory, process
RSS, macOS physical footprint, or GPU allocation. It does not intercept every
possible allocator API. The same probe and fixtures are used for both variants.

## Correctness and integration

The focused suite compares the helper with the old projection across small
playlist boundaries, duplicate anchors, missing and nil inputs, decoded and
noncanonical URL representations, a seeded mixed corpus, and a large playlist.
It checks that returned values remain independent when the original playlist
is replaced or cleared. Existing thumbnail ranking and scheduling-policy tests
run alongside the new tests in debug and optimized configurations.

The
[`thumbnail-playlist-neighbors` workflow](../.github/workflows/thumbnail-playlist-neighbors.yml)
runs the component campaign on Linux and macOS. The repository's existing
restoration/thumbnail workflow builds the actual app graph and runs the native
release suite on pull requests, including `ThumbnailBackgroundSchedulerTests`.
Component measurements alone do not qualify AppKit integration, live playback,
frame pacing, thumbnail throughput, energy use, or end-to-end responsiveness.

## Initial component qualification

The local Linux smoke run passed 19 tests in each of four configurations:
baseline debug/release and candidate debug/release. Full measurement receipts
and native component qualification are pending the reproducible CI campaign.
