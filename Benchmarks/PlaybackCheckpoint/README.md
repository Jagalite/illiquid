# Playback checkpoint membership

The [research report](../../Documentation/PLAYBACK_CHECKPOINT_PERFORMANCE.md)
distinguishes the measured first candidate from the revised candidate awaiting
its final native qualification. The PR remains a draft while that run is queued.

This experiment measures the complete production `PlaybackCheckpoint.record()`
and the same operation followed by sorted-key JSON encoding. The checkpoint
already captures a playlist index; a validated hit avoids scanning preceding
items and repeatedly normalizing the source URL. A missing or stale index still
falls back to membership lookup, with one cached source identity. A nil folder
does not need membership work because the saved folder is necessarily nil.

## Reproduce

Use macOS 26, Xcode, and Python 3.10 or later. No FFmpeg, libass, media files,
network downloads, app launch, or user-preference changes are required.

```sh
python3 Benchmarks/PlaybackCheckpoint/run.py \
  --pairs 16 --target-ms 200 --output /tmp/playback-checkpoint
python3 Benchmarks/PlaybackCheckpoint/run.py \
  --mode summarize --output /tmp/playback-checkpoint
```

The output directory must be new or empty. `--mode tests` runs semantic tests
only; `--mode benchmark` builds the measurement binaries and checks their full
output before timing. Repeat `--case` to select exact workloads, such as
`record-last-1000` and `encode-last-1000`. A new benchmark cohort needs an even
`--pairs` count of at least two. No noisy timing threshold decides correctness.

When the shared Kyoto queue is available, submit the complete command through
it as required by `AGENTS.md`, then inspect the job's status and logs. Hosted
GitHub runners do not have that queue; the workflow reports this explicitly and
uses serial, isolated component builds. No `.build` directory is shared between
variants.

## Exact source and correctness

The frozen baseline is the full checkpoint writer at
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`. Its original path, Git blob and SHA-256
are pinned in `baseline/manifest.json`; the runner rejects altered bytes. The
candidate is the current production file. Both compile against one common,
separately optimized `IlliquidCore` library containing eight complete production
files, including the real record initializer, deduplication, URL normalization,
and session-store implementation. Production files are never extracted or
rewritten, and no framework or model substitutes are used.

The identical driver imports each separately optimized `IlliquidPlayer` module
through `@testable import`. There is no cross-module optimization. Debug and
release Swift Testing runs exercise both versions with the new checkpoint tests
and existing session-record tests. The checkpoint suite compares complete
records and exact serialized bytes with the original membership predicate,
including 224 deterministic combinations of playlists, source URLs and indices.
Other cases cover decoded lexical/Unicode aliases, invalid authorities,
credentials and ports, duplicate metadata, malformed enum labels, nonfinite
positions, and snapshot independence. An index is never trusted as proof of
file identity, and the saved index is not silently repaired.

## Workloads and measurement

Twenty-six cases cover two scopes across thirteen fixtures: empty, singleton,
32 entries with the first selected, 1,000 entries with middle/last selection,
10,000 entries with first/last selection, and 1,000-entry missing-index,
stale-index, out-of-range-index, absent-source, remote-source and nil-folder
controls. The 10,000-entry cases are scaling stress tests. Every item has a
timestamp; one in sixteen has two subtitle URLs. The 32-entry case includes
saved shuffle identities. All URLs are synthetic and no files are accessed.

Fixtures, source normalization during fixture construction, the original-policy
oracle, output verification, two warmup operations, hashing and JSON receipts
are outside both measurement clocks. The record scope includes the complete
real record initializer, including playlist deduplication. The encoding scope
also creates a fresh `JSONEncoder` with `.sortedKeys`, as the atomic store does.
It excludes the store lock, directory creation and atomic disk write. The real
initializer still reads `Date()`; the driver fixes `updatedAt` for exact byte
comparison (inside timing only for the encoding scope).

Each sample uses a fresh process. A constant-cost, non-inlined checksum consumes
every result, and the last full record and encoded output are validated after
timing. Before measurement, both variants must produce byte-identical complete
JSON for every workload. Every timed receipt is checked against those sizes,
output fingerprints and checksum counts.

The runner calibrates iteration counts against the baseline and uses the same
count for both variants. It collects adjacent baseline/candidate pairs,
alternates AB/BA order, reverses case traversal on alternate rounds, and retains
every sample. Wall time uses `DispatchTime`; process CPU uses
`CLOCK_PROCESS_CPUTIME_ID`. Summarization rejects missing, duplicate, reordered
or incomplete observations, and reports medians, ranges and every paired ratio.
Run on an otherwise idle host without concurrent builds or benchmarks.

## Evidence and limits

The output contains source snapshots, exact commands and return codes, compiler
and library hashes, complete compressed verification records, test logs, raw
observations and summaries. The workflow uploads these receipts and emits a
compact review bundle in its logs. Build products and generated outputs stay
outside source control; curated evidence can be retained under `evidence/`.

These are native Foundation component measurements, not playback throughput,
frame timing, energy, UI latency, or end-to-end persistence durability results.
The existing record initializer and JSON encoding still traverse the playlist;
the complete operation remains O(n). The optimization removes repeated
membership work without adding a cache or changing saved data. Full application
builds and physical playback qualification are separate from this harness.
