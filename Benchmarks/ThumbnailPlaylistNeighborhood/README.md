# Thumbnail playlist neighborhood allocation

When background thumbnail generation is enabled, its library passes previously projected the entire playback playlist to
an owned `[URL]`, then kept only the first matching current item's radius-four
neighborhood. The eager projection also ran when there was no current item.
The new `ThumbnailPlaylistNeighborhood` scans the existing items and owns at
most nine URLs and nine distance entries. It returns no playlist slice, lazy
collection, or closure that could keep the source playlist alive across an await.

## Behavior

The scheduler still uses exact `URL` equality and the first matching playlist
entry. Neighbors retain playlist order. Duplicate URLs remain in the URL array;
distance writes follow playlist order, so the last occurrence in the window
still wins. Visible rows, discovered files, recent files, ranking, cancellation,
the pass cursor, and decode policy retain their existing behavior.

Search remains linear for a late or missing current item. There is no persistent
index or invalidation state. A nil current item skips the search entirely.
The copied URL storage is bounded by the nine-item window instead of the
playlist size.

## Reproduce

From the repository root:

```sh
python3 Benchmarks/ThumbnailPlaylistNeighborhood/run.py \
  --pairs 8 --target-ms 40 --output /tmp/thumbnail-neighborhood-results
```

The runner uses the shared Kyoto queue when available, including its show, wait,
and logs receipts. When the queue is absent, it explains that condition before
building the isolated packages directly and serially.

The baseline is pinned to
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`. The runner extracts the old scheduler's
two neighborhood-construction blocks and changes only the input binding from
`player.viewStore.playlist` to a parameter. The candidate compiles the complete
production helper. Both use the same complete `FolderPlaylistItem`,
`NaturalFilenameOrdering`, and `NormalizedFileURL` source files. The runner
rejects dependency drift and records all input hashes.

Both variants run the same behavior tests in debug and release. The optimized
probe is a separate Swift module from the helper and production item types.
A checksum consumes every timed result, and exact URLs and distances are checked
against an independent index-distance oracle. Input creation, oracle computation,
warmup, validation, JSON output, and the allocation probe are outside timing.
Eight fresh-process pairs alternate baseline/candidate and candidate/baseline.
Each variant calibrates its own loop length; wall and process CPU times are
normalized per neighborhood construction. Timings include the same call,
checksum, and autorelease-pool overhead; nothing is subtracted.

Cases include empty, single-item, 32-item and 1,000-item playlists, plus
100,000-item playlists with no current item, a head/middle/tail selection, or a
missing selection. The large list is a scaling stress case, not a claim about
typical library size.

## Memory measurement

The separate inventory compiles the old projection statement verbatim except
for its parameter name. It warms that path, measures the array's actual
capacity, and reports `capacity * MemoryLayout<URL>.stride`. A native allocator
probe also samples live bytes while that projected array is held. On macOS the
probe reads the default malloc zone; on glibc it reads `mallinfo2`.

This measures the temporary projection being removed. It is **not** a
measurement of the candidate's peak heap, the full scheduler's peak, total app
RSS, or video/subtitle decode buffers. URL objects already owned by the input
are excluded from the reported element-buffer payload. Allocator deltas may
include runtime bookkeeping, and are reported separately from capacity bytes.
The candidate's output count and capacity are recorded as the bounded result.

## Validation and evidence

The dedicated workflow runs the isolated comparison and a separate macOS build
of the full application graph with thumbnail policy and scheduler regressions.
Source identity, commands, test completions, calibration, raw paired samples,
allocation inventory, and summaries are retained in its artifacts.

A result is publishable only after inspecting the actual completed run. Runtime
measurements and workflow links will be added here after validation. No
live playback, displayed-frame, energy, or user-interface improvement is inferred
from this construction benchmark.
