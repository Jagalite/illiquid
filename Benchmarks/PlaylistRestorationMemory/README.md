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
Fixtures and warm-up results are constructed and released before measurement.
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

Native validation is pending. The isolated branch workflow will record measured
results before this research is proposed as a successful optimization.
