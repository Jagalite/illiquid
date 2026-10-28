# Playlist restoration map memory

## Question and production change

`PlaylistMutation.restoringOrder` builds a temporary identity map before restoring
the saved order. The input array already owns the complete `FolderPlaylistItem`
values, so the map can store the index of each first occurrence instead of another
item value. It still computes each input identity once and uses the same current
order to append new entries. Dictionary removals continue to consume saved IDs
once; removed entries cannot reappear.

The array remains immutable, so its indices stay valid throughout the call.
The change does not imply that the old code deeply copied subtitle arrays.
It reduces dictionary value storage and the associated reference ownership work.
Both implementations still use O(U) auxiliary space and O(N + saved IDs) time.

This function runs when shuffle is disabled and in `checkpointSession()` while
shuffle is enabled. Component measurements below do not establish total player
memory, frame performance, or end-to-end checkpoint latency.

## Qualification

The baseline is the production source at commit
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`, with target blob
`ff86a4830377c695df8ac700cd0fdff194b4f778`. This is the already optimized
single-identity-pass implementation, not the earlier baseline from
`Benchmarks/PlaylistRestoration`.

Use the existing semantic suite, which includes an independent integer-label
oracle covering 41,261 queue/saved-order combinations, duplicate identities with
different metadata, Unicode/path aliases, remote query strings, removals,
additions, empty inputs, and current-item preservation:

```sh
bash Scripts/test-playlist-restoration.sh
bash Scripts/test-playlist-restoration.sh -c release
python3 Benchmarks/PlaylistRestorationMemory/run.py \
  --output /tmp/playlist-restoration-memory --pairs 8 --rounds 3
```

On a shared host with Kyoto, submit compilation through its queue as required
by `AGENTS.md`. The dedicated GitHub-hosted macOS job checks that Kyoto is absent
and logs that limitation before compiling directly and serially.

## Measurement design

The runner builds the actual four production Swift files with Swift 6, `-O`,
whole-module optimization, and warnings as errors. Baseline and candidate use
identical dependencies and fixtures. It verifies the frozen baseline blob and
retains source/binary hashes, compiler/platform metadata, build commands, all
raw observations, and summaries. Source hashes are checked again after execution.

Each pair uses fresh processes with alternating baseline/candidate order.
Fixture-construction temporaries and warm-up results are released before measurement.
All returned items, including subtitles and dates, must equal independently
constructed expected arrays. The fixture and expected arrays stay alive across
the two memory samples.

- **Memory:** in temporary source copies only, insert one C hook immediately
  before the result array is created, after the map and current-order array are
  fully populated. The hook reads `malloc_zone_statistics(NULL).size_in_use`
  across all allocator zones and stores only C integer fields. Subtract the
  pre-call live bytes from this checkpoint. Record map/order capacities and
  require identical container shapes within each pair.
- **Timing:** compile separate, uninstrumented copies. Time only the restoration
  call; fixture construction, warm-up, full-item comparisons, and returned-array
  destruction are outside the interval. Summarize the median of each process's
  three calls, then the median and range of eight process pairs.
- **Cases:** unchanged saved order, removal/addition edits, duplicate items with
  different metadata and duplicate/missing saved IDs, and an empty saved-order
  timing control. Sizes are 100, 10,000, and 100,000 distinct items. Duplicate
  cases contain twice as many input items. Empty saved order creates no map and
  therefore has no populated-map memory sample.

The memory metric is **live-heap delta at the populated-map checkpoint**. It is
not peak heap, RSS, allocation count, total call allocation, or application-wide
memory. The returned array has not been allocated at that checkpoint. Temporary
Foundation allocations can contribute to both variants. The benchmark injection
is checked for a single exact marker, is retained in the receipts, and is absent
from every production and timing source.

## Results

### Portable production-source validation

[Linux run 40637410006](https://github.com/Jagalite/illiquid/actions/runs/40637410006)
passed on Ubuntu 24.04, x86_64, with Swift 6.4 (`swift-6.4-RELEASE`).
The production code is identical to the primary candidate commit
`1d358535eaba91ac342794c2219129df3f027e17`. A separate validation commit
[a2237e438ce68e85c6c522b746ec57c27703105b](https://github.com/Jagalite/illiquid/commit/a2237e438ce68e85c6c522b746ec57c27703105b)
adds only benchmark portability support and its workflow: a Linux autorelease-pool
no-op, glibc allocator probe, and platform-aware compiler/receipt commands.
This preserved the queued macOS job while obtaining feedback from another runner.

- **22 tests in 4 suites passed** for candidate debug, candidate release, and
  frozen-baseline release, including the 41,261-case independent oracle.
- **168 fresh-process observations**, six alternating pairs per case, all
  passed complete-item equality checks. Timing processes measured three calls.
- The target source and dependencies remained byte-identical throughout the run.
  The working tree was clean. Source and binary hashes are retained.
- On this toolchain, `FolderPlaylistItem` has a 40-byte stride and `Int` has an
  8-byte stride. This describes the map value representation, not the total
  dictionary allocation.

#### Temporary allocator storage

These Linux numbers use `mallinfo2().uordblks + hblkhd`, which can include
allocator caches. They measure the populated-map delta from the warmed pre-call
baseline. They are not macOS live-heap, peak, RSS, or whole-player measurements.

| Distinct items | Scenario | Baseline bytes | Candidate bytes | Saved bytes | Reduction |
|---:|---|---:|---:|---:|---:|
| 100 | unchanged | 27,312 | 19,248 | 8,064 | 29.53% |
| 100 | edited | 27,184 | 19,120 | 8,064 | 29.66% |
| 100 | duplicates | 27,296 | 19,232 | 8,064 | 29.54% |
| 10,000 | unchanged | 2,301,264 | 1,776,976 | 524,288 | 22.78% |
| 10,000 | edited | 2,301,152 | 1,776,864 | 524,288 | 22.78% |
| 10,000 | duplicates | 2,301,504 | 1,777,088 | 524,416 | 22.79% |

All six repetitions of each memory case reported the same delta and matching
map/current-order capacities. At 10,000 distinct items the map change saved
512 KiB (512.125 KiB with duplicates), about 22.8% of this checkpoint delta.
The duplicate case has 20,000 input items and retains the first occurrence's
original subtitles and date.

#### Uninstrumented timing

| Distinct items | Scenario | Baseline ms | Candidate ms | Median change |
|---:|---|---:|---:|---:|
| 100 | unchanged | 0.487 | 0.470 | 3.36% lower |
| 100 | edited | 0.475 | 0.476 | 0.15% higher |
| 100 | duplicates | 0.906 | 0.906 | 0.05% higher |
| 100 | no-base | 0.447 | 0.445 | 0.46% lower |
| 10,000 | unchanged | 51.204 | 51.109 | 0.19% lower |
| 10,000 | edited | 51.186 | 51.367 | 0.35% higher |
| 10,000 | duplicates | 97.172 | 96.030 | 1.18% lower |
| 10,000 | no-base | 46.913 | 46.422 | 1.05% lower |

The timing differences are small and paired ranges overlap zero in every case.
The unchanged no-base control also varies. This evidence supports a temporary
memory reduction; it does not establish a runtime speedup or statistical
equivalence. Every raw value and the full ranges are retained.

#### Native macOS qualification

[macOS run 40636026411](https://github.com/Jagalite/illiquid/actions/runs/40636026411)
was queued when the portable evidence was recorded. No successful macOS result
is included in this dataset. Its dedicated workflow uses the native all-zone
probe, eight pairs, and sizes through 100,000 distinct items. Check that run and
the PR checks before interpreting the result as native qualification.

No full-player build, live playback, UI latency, decoder throughput, or total
process memory result is claimed by this component study.

### Retained evidence and reproduction

The [Linux evidence](evidence/linux/) contains raw JSONL, summary JSON, exact
compiler/source/binary receipts, and test result excerpts extracted from the
completed job log. The portable harness can be reproduced from validation commit
`a2237e438ce68e85c6c522b746ec57c27703105b` using:

```sh
python3 Benchmarks/PlaylistRestorationMemory/run.py \
  --output /tmp/playlist-restoration-memory-linux \
  --pairs 6 --rounds 3 --sizes 100 10000
```

The primary branch's runner remains the native macOS implementation. The
production optimization itself has no platform conditions.
