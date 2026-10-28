# Playback checkpoint preparation

This study measures complete `PlaybackCheckpoint.record()` calls. It compares
the production checkpoint writer at `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`
with a focused change to that file. Results and retained receipts are added
after qualification; the existence of this runner is not a performance result.

## Why this work occurs

`PlaybackController` captures a checkpoint when playback position moves at
least ten seconds from the last checkpoint, and on operations including pause,
playlist changes, source commitment, and shutdown. A serial persistence writer
constructs the record before saving it. The work measured here is on that
background writer, not the main actor.

Opening several individual files and appending files create playlists without
a collection folder. Previously, record construction still scanned these
playlists to determine whether the source belonged to the collection. The
answer could not affect the saved folder because the supplied folder was nil.
For playlists with a folder, the scan normalized the same source URL for each
supported item visited.

The change skips the membership scan for absent folders and empty playlists.
When a scan is needed, it prepares the valid source identity once and compares
each visited item's identity with that key. A missing identity never matches
another missing identity. Source URL validation, the original supplied folder,
item order and metadata, saved index, shuffle IDs, schema, position sanitization,
and timestamp construction retain their existing contracts.

`PlaybackSessionRecord` still deduplicates the playlist. Both arms include this
unchanged work. The change introduces no persistent cache, filesystem lookup,
new concurrency, or serialization format.

## Reproduce

Run from a checkout containing the baseline Git object, using Swift 6.1 or
later. The package's macOS deployment boundary remains macOS 26. Follow the
repository's `AGENTS.md`: submit builds to Kyoto when available, and serialize
builds sharing a build directory. The dedicated GitHub workflow handles that
queue check on its hosted runner.

```sh
python3 Benchmarks/PlaybackCheckpointPreparation/run.py \
  --output /tmp/checkpoint-preparation-results --pairs 6 --target-ms 250
```

The output directory must be new or empty. Dependencies are included in the
repository; these component packages need neither FFmpeg nor the full app.
For a mechanics check, add `--quick --pairs 2 --target-ms 25`. This excludes
10,000-item timing cells and uses shorter observations; it is not the final
measurement protocol. `--tests-only` and `--skip-tests` select a phase.

## Source isolation and correctness

The runner pins full-file SHA-256 hashes for seven baseline production files.
Only `PlaybackCheckpointWriter.swift` changes between the two arms. Both use
the same current core sources, regression tests, bridge, and driver. A changed
unrelated dependency is rejected, rather than silently broadening the study.

Six Foundation core inputs provide the actual playlist, URL, source, and
session-record implementation. `PlaybackSessionStore.swift` is cut at a checked
boundary after the **complete `PlaybackSessionRecord` and `PlaybackSessionStoring`
declarations**. Its unused disk-store class and macOS signposting dependencies
are outside this experiment. The full checkpoint source is compiled unchanged;
no replacement production declarations are used.

Identical tests run against baseline and candidate in debug and release. The
checkpoint suite exercises raw and relative URLs, encoded dot segments,
localhost and rejected authorities, NFC/NFD Unicode, duplicate metadata, nil
folders, malformed source enum cases, and stale saved indices. It includes
1,190 small-playlist comparisons of every record field and sorted-key JSON
bytes with the original pipeline. Independent fixture labels check membership
as well. Each constructor samples its own clock; only `updatedAt` is aligned
for byte comparisons, and a separate test bounds it by the call's start/end.

Before timing, separate executables emit complete canonical records for all
58 workload fixtures. The runner requires byte-identical output. Every timed
process independently checks the complete fixture before and after measurement,
normalizing only the sampled timestamp. Unicode fixtures must retain distinct
raw source/item URL spellings with equal normalized identities.

## Measurement protocol

Each arm builds optimized `IlliquidCore` and `IlliquidPlayer` libraries, then
compiles the identical driver separately. A small non-inlinable bridge exposes
the internal checkpoint constructor without changing its production visibility.
No cross-module optimization is enabled. Variant-specific loader paths prefer
the recorded libraries over inherited research paths; dependency and command
receipts retain the resolution setup.

There are 58 workload cells:

| Fixtures | Playlist sizes |
| --- | --- |
| Folder: first, middle, last, missing source | 0, 1, 32, 1,000, 10,000 |
| No folder: first, last, missing source | 0, 1, 32, 1,000, 10,000 |
| Remote source with a supplied folder | 0, 1, 32, 1,000, 10,000 |
| Long Unicode source alias, with and without a folder | 1, 32, 1,000 |
| Unsupported source; all unsupported playlist items | 1, 32, 1,000 |
| Duplicate items, with and without a folder | 1, 32, 1,000 |

Fixture construction, complete semantic checking, and serialization occur
outside timing. The measured loop includes full record creation, its unchanged
deduplication, a small result checksum, and record destruction. Darwin drains
an autorelease pool for each operation in both arms. Each process warms two
calls before measurement. `Date()` remains part of the production call.

Calibration runs both variants, starting with one call, and selects a common
iteration count targeting 250 ms of CPU time in the faster arm. At most three
calibration trials are used, with a one-million-iteration cap. Actual durations
are retained; the target is not a guarantee for every observation. Six fresh
process pairs per cell alternate baseline-first and candidate-first order.
Both `CLOCK_PROCESS_CPUTIME_ID` and monotonic elapsed time bracket the same work.
No timing overhead is subtracted and no measured observations are discarded.

Absolute values are medians of per-process average costs. Paired percentage
reductions are the median of `100 * (1 - candidate / baseline)` across six
pairs; they need not equal the percentage calculated from the two displayed
absolute medians. The summary retains ranges, every paired reduction, and the
number of pairs favoring the candidate for both clocks. CI has no noisy timing
pass/fail threshold.

## Interpretation limits

These are in-memory component measurements with synthetic playlists. They
exclude JSON encoding, atomic disk writes, writer-queue coalescing, media
decoding, UI layout, and playback rendering. They do not establish a whole-player
CPU, frame-rate, energy, memory, shutdown-latency, or storage-throughput gain.

First-item matches, empty playlists, and remote sources have little or no
membership work to remove. An all-unsupported playlist can incur one additional
source normalization in the candidate. Those controls remain in the evidence.
Native app integration is checked separately by the repository's existing
restoration/native lifecycle workflow when a PR is opened.

## Evidence layout

The output retains the manifest, complete production and compiled sources,
tests and harness snapshots, binary hashes, full command logs, compressed
verification output, calibration, every observation, and a statistical summary.
The runner rechecks source and executable hashes between pairs and at completion.
Build directories are reproducible and are omitted from the compact CI artifact.
