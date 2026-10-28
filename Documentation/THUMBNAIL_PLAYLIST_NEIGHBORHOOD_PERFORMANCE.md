# Background thumbnail playlist neighborhood

## Finding and change

At baseline `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`,
`ThumbnailBackgroundScheduler.runPass` starts by mapping the complete
`PlaybackViewStore.playlist` to an array of URLs. It then searches for the current
source and copies at most nine neighbors. The complete intermediate URL array
is unnecessary, including when there is no current source. This synchronous
preparation runs on the main actor before detached candidate ranking.

`ThumbnailPlaylistNeighborhood` now searches the existing playlist and copies
only the bounded neighborhood, together with its distance dictionary. It returns
empty output immediately for a nil current source. The scheduler calls the
synchronous helper directly: it does not introduce a local playlist array in the
async method, and the result stores no playlist, subtitle metadata, or array
slice. The helper adds no cache or invalidation state.

The input array is read without mutation. Swift arrays use copy-on-write
storage, so passing this value does not itself copy its elements. Returning
bounded URL values also avoids retaining an `ArraySlice`, which would keep its
entire original storage alive. See Apple's
[Array documentation](https://developer.apple.com/documentation/swift/array) and
[ArraySlice storage guidance](https://developer.apple.com/documentation/swift/arrayslice).

## Behavior preserved

- The anchor is the first matching `URL`, using the same Foundation equality.
- The neighborhood contains the anchor, up to four preceding items, and up to
  four following items, in their existing order.
- Duplicate URLs remain in the output array. Distance dictionary entries retain
  the original last-assignment behavior, even if a duplicate current URL
  overwrites the anchor's zero distance.
- Missing and nil current sources produce empty neighborhoods.
- The scheduler's candidate ordering, ranking, limits, cancellation, and decode
  work are unchanged.
- `currentPlaylistIndex` is intentionally not substituted for the URL lookup;
  that would introduce a different identity and synchronization contract.

## Complexity and memory scope

For a playlist of `n` entries and first matching index `k`, the old preparation
projects `n` URLs before its search. The new search visits at most `k + 1`
entries, or all `n` when absent, and stores at most nine URLs and nine distance
entries. Nil current performs no playlist traversal. Late and absent lookup
remain O(n); extra result storage is O(1).

The removed intermediate URL array has a source-level element-payload model of
`n * MemoryLayout<URL>.stride` bytes. This is not a measured allocation, RSS
delta, or reduction in the referenced URL objects. Array headers, capacity
rounding, allocator behavior, and possible compiler transformations are not
included. Both versions already return the bounded neighbor array and distance
dictionary.

## Reproduction

Follow `AGENTS.md` and submit compilation through Kyoto when it is available.
The CI workflow checks that Kyoto is unavailable on its ephemeral runner before
performing direct, serial builds in isolated checkouts.

```sh
bash Scripts/test-thumbnail-playlist-neighborhood.sh --jobs 2 --no-parallel
git fetch --no-tags origin ea2ff568237e2667f7b1aeee67b11a44ebe95b72
python3 Benchmarks/ThumbnailPlaylistNeighborhood/run.py \
  --rounds 8 --target-ms 50 --counts 32,10000,100000 \
  --output /tmp/thumbnail-neighborhood-results.json
```

The component tests compile unmodified production support and helper sources
with the original regression test file in debug and release. They cover every
anchor for several short lengths, missing and nil sources, duplicate layouts,
decoded URL representations, a large playlist, and result value semantics.

For the benchmark, both neighborhood blocks are copied from the pinned original
scheduler. Only the `player.viewStore.playlist` input expression is adapted to
a function parameter; the resulting arrays are returned through the same shape
as the candidate. The candidate compiles the complete, unmodified helper.
Both use an identical separately compiled `IlliquidCore` and optimized
`IlliquidApp` module boundary. This isolates the preparation operation; it is
not a benchmark of the entire scheduler.

Every process constructs its fixture outside the timer, warms up once, checks
the exact URLs and distances against expected output, and consumes each timed
result's counts. Baseline/candidate processes run in eight balanced AB/BA pairs.
Each variant is independently calibrated to about 50 ms per process, capped at
one million calls. This prevents tiny candidate paths from using only a few
clock ticks. Raw times, exact output receipts, source hashes, compiler flags,
and host identity are retained in the JSON report.

The workflow also compiles the full app graph with the pinned native SDK and
runs the existing thumbnail scheduler and policy tests alongside the new tests.

## Validation results

Results are recorded after the branch's CI qualification. No application frame
rate, UI latency, process memory, GPU memory, or energy claim follows from this
isolated preparation benchmark. Live player interaction remains unqualified.
