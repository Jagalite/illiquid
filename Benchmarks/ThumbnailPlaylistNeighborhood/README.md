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

## Results: portable Swift qualification, 2026-10-28

[Portable workflow run](https://github.com/Jagalite/illiquid/actions/runs/40635929066)
completed successfully at `ffe49b5905aa5aa6444b5b1db2035f4dda6f801e`.
Host: x86-64 Linux, glibc 2.39, Swift 6.4. These are **Linux component results**;
they do not establish native macOS timing or full-application qualification.

All six behavior tests passed on both baseline and candidate in both debug and
release (24 test executions). All 12 timed workloads matched the independent
oracle and each other's exact URL order and distances across eight paired runs.

| Playlist size / selection | Baseline median, µs | Candidate median, µs | Paired wall-time reduction | Faster pairs |
| --- | ---: | ---: | ---: | ---: |
| 0 / none | 0.0302 | 0.0266 | 11.7% | 8/8 |
| 1 / head | 0.2565 | 0.2965 | -15.4% | 0/8 |
| 32 / head | 1.53 | 0.6275 | 58.5% | 8/8 |
| 32 / middle | 2.40 | 1.12 | 52.6% | 8/8 |
| 32 / tail | 1.89 | 0.9780 | 48.2% | 8/8 |
| 1000 / middle | 21.29 | 6.93 | 67.1% | 8/8 |
| 1000 / missing | 22.34 | 9.15 | 59.1% | 8/8 |
| 100000 / none | 1346.21 | 0.0250 | 99.998% | 8/8 |
| 100000 / head | 1330.38 | 0.6093 | 99.954% | 8/8 |
| 100000 / middle | 1997.26 | 652.13 | 67.6% | 8/8 |
| 100000 / tail | 2860.63 | 1440.42 | 50.1% | 8/8 |
| 100000 / missing | 2273.61 | 926.15 | 59.2% | 8/8 |

The large-list tail and missing-selection cases also improved in all eight CPU
and wall-time pairs. The direct scan's larger item stride did not erase the
benefit of removing the projection in this environment. Search is still linear.

For 100,000 items, the separate projection inventory measured a 100,000-element
URL buffer with a 16-byte stride: **1,600,000 bytes (1.53 MiB) of element payload**.
The live glibc allocator delta during that isolated projection was 1,600,048
bytes. The candidate returned zero to nine URLs, with capacities matching those
counts on this host. These measurements support removing the large temporary
projection; they are not a measurement of overall application memory savings.
For small neighborhoods that cover the entire playlist, the inventory must not
be interpreted as net saved storage: the old projection can also supply the
returned neighborhood.

The measured tradeoff is the singleton case: roughly **0.2565 → 0.2965 µs** per
construction, a paired 15.4% increase (about 40 ns). This occurs once per library
pass, whose idle interval is measured in seconds. This small absolute cost is retained as an explicit tradeoff.

Full summaries, timing samples, source hashes, and test counts are retained in
[evidence/linux-summary.json](evidence/linux-summary.json) and
[evidence/linux-manifest.json](evidence/linux-manifest.json). Detailed command
logs and exported source packages are in the workflow artifact.

### Native qualification remains pending

The [macOS workflow](https://github.com/Jagalite/illiquid/actions/runs/40635264617)
was queued when these results were recorded. Both its component benchmark and
full release application/scheduler test job must complete before marking the PR
ready for merge. The queued native code revision is
`21a6412280a62f9c7bf06dc60568a59309a3c087`; the portable run adds only a Linux
workflow to that revision. No production or benchmark source changed between
them.

No live playback, displayed-frame, energy, or user-interface improvement is
inferred from this construction benchmark.
