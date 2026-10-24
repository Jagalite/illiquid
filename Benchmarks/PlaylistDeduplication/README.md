# Playlist deduplication memory research

## Problem and change

`PlaylistMutation.deduplicated` used `filter` to build a replacement item array
even when every identity was already unique. This helper is called by
`PlaybackSessionRecord.init`, session decoding, folder discovery, prepared-open
construction, append operations, and the empty-base-order restoration path.
`PlaybackCheckpoint.record()` constructs a session record on the persistence
writer queue; normal progress updates request a checkpoint after a ten-second
position change. Avoiding a replacement array therefore also avoids repeated
element-buffer allocation and element retain/release traffic during saving.

The candidate still checks the same normalized identities in one pass. It
allocates duplicate-removal output only when the first repeated identity appears,
then copies the unique prefix and retains the first complete item for each later
identity. An ordinary unique playlist returns the existing array. Swift's
copy-on-write array semantics keep independently mutated values independent.

Returning an input unconditionally would introduce a retention regression for
playlists reduced from a large size. The candidate therefore returns an empty
array for empty input and compacts unique arrays when their capacity exceeds
64 slots and their count is below half their capacity. It shares normal geometric
growth capacity and small buffers. The compaction path starts with a new array,
reserves the live count, and appends the items; `Array(existingArray)` would not
guarantee a separate compact buffer.

The change removes neither identity normalization nor the temporary identity
`Set`. URLs and subtitle arrays already share their referenced storage; this is
an item-buffer improvement, not a deep-copy saving. The coalescing persistence
writer retains only its current write and latest pending request, so savings are
per constructed record, not an accumulating history of checkpoints.

## Reproduce

The frozen baseline is commit
`6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635`. It must be present in the local Git
history; CI checks out full history. The candidate uses the current worktree.

```sh
python3 Benchmarks/PlaylistDeduplication/run.py \
  --pairs 6 --target-ms 40 --output /tmp/playlist-deduplication
```

Use a new or empty output directory. The run retains a manifest, source snapshots,
compiler/test logs, commands, calibration, every observation, and a summary. Its
source and binary hashes identify exactly what was measured. Failure leaves
completed evidence available and marks the summary as failed. Build products are
kept separately from the retained text evidence.

```sh
# Behavior only: both revisions, debug and release.
python3 Benchmarks/PlaylistDeduplication/run.py \
  --mode tests --output /tmp/playlist-deduplication-tests

# Short experiment-mechanics check, not the reported six-pair study.
python3 Benchmarks/PlaylistDeduplication/run.py \
  --mode benchmark --quick --pairs 2 \
  --output /tmp/playlist-deduplication-smoke
```

Swift 6.1 or newer, bundled Swift Testing, Python 3.9 or newer, and a C compiler
are required. The allocation probe supports macOS and glibc Linux. No external
Swift package, native codec dependency, filesystem media scan, or real media
fixture is needed.

## What is compiled and tested

Both variants compile the real `FolderPlaylist`, `PlaylistMutation`,
`NaturalFilenameOrdering`, `NormalizedFileURL`, and `MediaSource` files. The
complete `PlaybackSessionRecord` type is copied verbatim from the beginning of
`PlaybackSessionStore.swift`, ending at a checked protocol boundary. This excludes
the unrelated disk store and macOS signposting without replacing record logic
with a model or stub. The runner rejects changes to the five unchanged dependency
files between the baseline and candidate.

The same six test files run against both variants in debug and release:

- New deduplication tests cover first-occurrence order and metadata, URL aliases
  decoded without normalization, fallback identities, duplicate positions,
  overreserved arrays reduced to empty/singleton/small playlists, and independent
  mutation of snapshots. Sixty-four mixed inputs use a separate first-index oracle.
- New session-record tests cover construction, duplicate saved-item decoding,
  snapshot independence, and stable JSON round trips.
- Existing mutation, shuffle-order restoration, folder-playlist, and natural
  filename-order tests protect the surrounding behavior.

For measurement, each variant is compiled with `-O -whole-module-optimization`
and Swift 6 into a separate dynamic `IlliquidCore` module. The identical driver
is compiled separately, without cross-module optimization; production entry
points are not `@inlinable`. A non-inlined driver factory calls either the actual
deduplication helper or the actual session-record initializer.

## Measurement method

The full study covers 36 workloads across those two entry points:

- Unique inputs with 0, 1, 32, 1,000, 10,000, or 50,000 items.
- Sparse unique inputs with 0, 1, 32, or 1,000 items in storage reserved for
  at least 50,000 entries, exercising the compaction fallback.
- 1,000- and 10,000-entry inputs with an early duplicate, a final duplicate,
  four repeated cycles of identities, or all entries sharing one identity.

Fixtures and an independent first-occurrence oracle are built before sampling.
Later duplicate occurrences have different subtitle/date metadata. The driver
checks full output values and deterministic all-field fingerprints, including
session metadata, before and after timing. Every timed result contributes to a
checked checksum. Baseline/candidate pairs must agree on output count, fingerprint,
and checksum.

The primary memory measurement holds **one returned array or session record**
alongside its existing input. Nested `withUnsafeBufferPointer` calls observe
whether the nonempty result and input share element storage. Additional element
storage is zero when shared, otherwise `result.capacity * item stride`. This
excludes array allocation headers, nested objects, the identity set, and temporary
work. Candidate qualification checks storage sharing for ordinary unique inputs,
bounded capacity for sparse inputs, and zero capacity for empty output; correctness
tests rely on values rather than pointer identity.

As supporting evidence, a C probe samples live allocator statistics immediately
before and after constructing the retained result. It uses glibc
`mallinfo2().uordblks + hblkhd` on Linux and the default malloc zone's `size_in_use`
on macOS. These counters include allocator bookkeeping/caches and do not measure
RSS or all process memory. In particular, a small allocation served from glibc's
thread cache can leave this counter unchanged. Treat element-storage observations
as the primary result. Darwin autorelease pools drain temporary Foundation objects
before these samples. The measured result is released before timing starts.

Timing measures repeated construction and disposal with a prebuilt input. Each
observation runs in a fresh process; baseline-first and candidate-first order
alternate across six pairs. Baseline-only calibration increases a shared iteration
count toward 40 ms, capped at 100,000 iterations, and is excluded from the summary.
The same count is used by both variants. Every retained pair is reported; there
is no timing threshold or outlier deletion. Tiny fast paths can have submillisecond
candidate loops and should not support precise speedup claims.

## Results and limits

The Linux study completed **34 tests in six suites** in each of the four
baseline/candidate × debug/release configurations. All **432 measured observations**
(36 workloads × six pairs × two variants) passed complete output parity and the
storage checks. Calibration observations are separate.

For both the helper and session-record initializer, every ordinary nonempty unique
candidate result shared its input array. The additional element capacity was:

| Unique items | Baseline additional element storage | Candidate additional element storage |
| ---: | ---: | ---: |
| 32 | 1,280 bytes (1.25 KiB) | 0 |
| 1,000 | 40,960 bytes (40 KiB) | 0 |
| 10,000 | 655,360 bytes (640 KiB) | 0 |
| 50,000 | 2,621,440 bytes (2.5 MiB) | 0 |

The measured item stride was 40 bytes. At 50,000 items the baseline output capacity
was 65,536 elements. The candidate reused the existing input, which had capacity
50,072 on this host. Supporting allocator measurements for that helper case were
2,621,680–2,621,776 additional bytes for baseline and 192–288 bytes for candidate;
the latter are allocator effects, not a second item buffer.

The sparse inputs had capacity 50,072, but candidate results with 0, 1, 32, and
1,000 live items had capacities 0, 1, 32, and 1,000 respectively. None retained
the original oversized buffer. Duplicate-containing inputs retained the expected
first complete items; their result storage remained compact or used ordinary
array growth capacity.

Large-input timing medians were mixed:

| Entry point | Items | Baseline | Candidate | Candidate time change |
| --- | ---: | ---: | ---: | ---: |
| Deduplication helper | 1,000 | 4.374 ms | 4.349 ms | −0.6% |
| Deduplication helper | 10,000 | 48.395 ms | 46.809 ms | −3.3% |
| Deduplication helper | 50,000 | 250.367 ms | 275.374 ms | +10.0% |
| Session record initialization | 1,000 | 4.499 ms | 4.453 ms | −1.0% |
| Session record initialization | 10,000 | 46.020 ms | 48.868 ms | +6.2% |
| Session record initialization | 50,000 | 251.788 ms | 254.099 ms | +0.9% |

These are six-pair observations on a shared host, with overlapping ranges. They
do **not** establish a general throughput improvement or prove the regressions
are solely noise. Twelve of the 36 workloads had higher candidate medians; the
32-item helper case was 15.2% slower (0.142 to 0.164 ms). The 50,000-item helper
case's slower median is also retained and reported explicitly. Memory sharing was consistent across every observation;
the normalized-identity scan still dominates larger calls. Full timings,
including sparse and duplicate controls, are in [`summary.json`](evidence/linux/summary.json).

The final local evidence is under [`evidence/linux`](evidence/linux/). The manifest
identifies the shared Linux host and Swift compiler; this is component research,
not an app playback profile. The focused GitHub workflow repeats the experiment
with native Foundation on macOS 26 and retains its complete evidence as an artifact.

To keep the repository compact, committed command receipts and observations use
gzip, and the unedited process logs and source snapshots are in `logs.tar.gz`
and `sources.tar.gz`. The runner itself emits the uncompressed files. Decompress
a receipt with `gzip -dc observations.jsonl.gz`, or extract
the archives from their evidence directory to restore the logged relative paths.

The Linux study used the exact preserved [`runner.snapshot.py`](evidence/linux/runner.snapshot.py)
before explicit macOS SDK selection was added. The current runner selects the
active Xcode SDK with `xcrun` and passes it to Swift and C compilation on Darwin;
Linux build commands and measurement behavior are unchanged. The evidence's
original source snapshots, manifest hashes, and observations remain unchanged.

These measurements do not establish total player RAM, encoding/I/O performance,
timeline smoothness, frame rate, or native playback behavior. The supported claim
is elimination of a separate item array for ordinary unique playlists while
preserving compact results for heavily overreserved input.
