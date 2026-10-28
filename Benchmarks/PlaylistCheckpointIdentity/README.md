# Shuffled checkpoint identity construction

## Question

Can a shuffled playback checkpoint preserve its saved base order without
reconstructing complete playlist items and normalizing their URLs again?

The comparison starts at main commit
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`. In
`PlaybackCoordinator.checkpointSession`, the old operation is:

```swift
PlaylistMutation.restoringOrder(items, ids: savedIDs).map(\.id)
```

The coordinator is on the main actor. Position updates that move at least ten
seconds from the last checkpoint, pause changes, and playlist edits can reach
this operation while shuffle is enabled. The resulting identities are saved in
the playback checkpoint so disabling shuffle or restoring a session can recover
the intended base order.

## Change and ownership

`PlaylistMutation.restoringIdentityOrder` computes each current identity once,
keeps its first occurrence in a set and an ordered identity array, consumes
surviving saved identities in saved order, then appends new identities in their
current order. The checkpoint calls this helper directly. Empty and singleton
playlists return before allocating lookup storage.

The existing item-producing `restoringOrder` is unchanged. Disabling shuffle
continues to use that operation and retains complete first-item metadata.

For a nonempty saved order with `n` input entries and `u` unique survivors, the
old checkpoint evaluates the computed `.id` property `n + u` times. The new
operation evaluates it `n` times. A unique playlist therefore changes from
`2n` to `n` URL normalizations. It also avoids a dictionary whose values contain
complete playlist items and the temporary restored item array. The live playlist
and the submitted persistence snapshot still retain their items; this is a
reduction in temporary work, not removal of those owners.

Swift string equality can match canonically equivalent strings with different
UTF-8 representations. Saved matches append the current member returned by
`Set.remove`, preserving the first current item's exact identity bytes rather
than substituting the saved spelling.

## Qualification status

The focused suite passed 30 tests in five suites in both debug and release on
Linux with Swift 6.3.3. The eight new tests include 2,635 small differential cases
against the frozen original operation and independently authored identity labels,
as well as a 2,048-item shuffled playlist, URL aliases decoded without the
normalizing initializer, unsupported and remote URLs, exact Unicode byte
preservation, and repeated checkpoints followed by metadata-preserving unshuffle.

## Measured result

The final cohort measures commit
`3e4967f09b29e25db3a5b3a4f475b18e0304fc98` on Linux x86_64, AMD EPYC 9V74,
Swift 6.3.3, with inherited affinity to logical CPUs 0–8. The inputs are synthetic
in-memory playlists; timings include the identical all-output UTF-8 checksum
consumption and result release in both variants.

**Unique playlists of 10–10,000 entries used 47.18–50.71% less wall time.** Every
nonempty target workload except the effectively unchanged no-base singleton
favored the candidate in all eight pairs. Process CPU reductions closely track
the wall-time reductions.

Values are medians of eight per-process mean times, in **microseconds per
operation**. Signed changes use the unrounded medians; negative means less time.
The paired distributions and ranges remain in the raw records.

| Workload | Baseline µs | Direct IDs µs | Wall change | CPU change | Faster wall pairs |
| --- | ---: | ---: | ---: | ---: | ---: |
| `empty` | 0.042 | 0.037 | -11.34% | -11.19% | 8/8 |
| `singleton_no_base` | 4.386 | 4.387 | +0.01% | +0.37% | 5/8 |
| `singleton_saved` | 9.121 | 4.433 | -51.41% | -51.43% | 8/8 |
| `unique_10` | 106.750 | 56.387 | -47.18% | -47.20% | 8/8 |
| `unique_100` | 945.736 | 472.232 | -50.07% | -50.05% | 8/8 |
| `unique_1000` | 9,958.965 | 4,909.232 | -50.71% | -50.61% | 8/8 |
| `unique_10000` | 100,680.336 | 51,698.814 | -48.65% | -48.44% | 8/8 |
| `edited_10000` | 109,601.128 | 57,532.195 | -47.51% | -47.51% | 8/8 |
| `duplicates_10000` | 59,657.315 | 45,402.745 | -23.89% | -23.62% | 8/8 |
| `no_base_10000` | 102,013.672 | 53,310.221 | -47.74% | -47.73% | 8/8 |
| `remote_1000` | 735.148 | 532.058 | -27.63% | -27.62% | 8/8 |
| `unicode_1000` | 13,627.518 | 7,556.122 | -44.55% | -44.58% | 8/8 |
| `restoration_control_1000` | 8,939.841 | 9,351.229 | +4.60% | +3.82% | 3/8 |

The unchanged item-restoration control measured **4.60% higher wall time** and
**3.82% higher CPU time**, with the candidate faster in only three of eight pairs.
This unfavorable control is retained; the study makes no universal speedup or
no-regression claim. The no-base singleton is effectively unchanged at
4.3863 → 4.3868 µs. The empty-input difference is about 4.8 ns and is not a
material playback benefit.

All **208** final timing observations are retained. The shortest observed wall
sample was **170.357 ms**, and the shortest CPU sample was **170.365 ms**, exceeding
the 60 ms gate. Every measured process passed output/checksum validation; the
separate differential corpus verified 52 timed fixtures plus 2,644 additional
cases, for **2,696 complete byte comparisons** per variant.

### Initial experiment and singleton adjustment

The initial complete cohort at `4b0e4a57b12819417e0d315ee44cb529661e6609`
constructed a Set for a singleton with no saved order. That case had a +6.87%
wall-median change (+3.46% CPU), with mixed paired results. Source inspection
identified unnecessary lookup storage, so the final helper returns the single
identity directly. Tests and the entire 208-observation protocol were rerun.
The initial cohort is preserved separately and is not used for the final table.

### Retained evidence and native gate

- [Readable final statistics](evidence/linux-x86_64-20261028/results.json)
- [Test source/command receipt](evidence/linux-x86_64-20261028/validation.json)
- [Independent final audit](evidence/linux-x86_64-20261028/audit.json)
- [Bundle inventory and hashes](evidence/linux-x86_64-20261028/index.json)
- [Complete final receipts](evidence/linux-x86_64-20261028/final-receipts.json.gz)
- [Superseded initial receipts](evidence/linux-x86_64-20261028/initial-receipts.json.gz)

Each gzip file expands to JSON with a `files` map. Every entry contains its
relative name, SHA-256, and exact UTF-8 contents, including raw observations,
calibration, command stdout/stderr, source snapshots, and completion/parity
records. Binary executables and compiler caches are omitted; their hashes and
build commands are retained. The final bundle also includes both test logs and
the validation receipt. The test provenance receipt was recorded after the run
and states that limitation explicitly.

The [Linux CI component job](https://github.com/Jagalite/illiquid/actions/runs/40640656872/job/122657762096)
also passed its debug/release tests, parity checks, and full benchmark. **Native
macOS qualification remains queued** in
[workflow run 40640656872](https://github.com/Jagalite/illiquid/actions/runs/40640656872).
The local tests and measurements above completed; no native timing, full native
app-test execution, or live playback qualification is claimed. The PR remains
draft until native results can be reviewed.

## Experiment scope

The benchmark compiles complete production copies of `NormalizedFileURL`,
`NaturalFilenameOrdering`, `FolderPlaylist`, and `PlaylistMutation` with identical
optimized Swift flags. The baseline uses the pinned main implementation; the
candidate uses the new identity helper. Both return ordered string identities.
There are no replacements for Foundation URL handling or playlist types.

Fixture construction, URL preparation, warmup, and full output checks are outside
the timed operation. Fresh processes alternate baseline/candidate order. The
receipts retain calibration, wall and process CPU observations, output checksums,
source and executable hashes, and the full protocol. Small and empty inputs,
duplicate-heavy and edited playlists, missing saved orders, remote/Unicode
identities, and an unchanged restoration operation provide boundary cases and
controls alongside large local playlists.

Timing is for in-memory checkpoint identity construction. It excludes persistence
encoding and disk writes, decoding, rendering, and physical user interaction.
The experiment does not measure allocator requests, live or peak heap, whole-app
RSS, or end-to-end UI latency. Native macOS timings and the full application test
graph are separate qualification gates from portable component results.

## Reproduce

Use Swift 6.1 or newer, Python 3, and a Git checkout containing the baseline
commit. Use a new output directory for each cohort. Follow the repository's Kyoto
build queue rule when the queue is available; the Linux workspace used for the
initial tests had no Kyoto installation.

```sh
bash Scripts/test-playlist-restoration.sh
bash Scripts/test-playlist-restoration.sh -c release
python3 Benchmarks/PlaylistCheckpointIdentity/run.py \
  --pairs 8 --target-ms 150 --output /tmp/playlist-checkpoint-identity-new
```

The `Playlist checkpoint identity performance` workflow runs portable component
checks and a separate macOS benchmark/app regression job. The macOS filter also
covers playlist restoration, identity lookup, session records, and the playback
coordinator's shuffle persistence behavior.

## Concurrent restoration work

[PR #152](https://github.com/Jagalite/illiquid/pull/152) changes the item-producing
restoration lookup from complete items to indices. This study changes the
checkpoint's identity-only operation and leaves that restoration method intact.
The index lookup still returns items before checkpoint code maps their computed
identities, so it does not remove this second normalization pass. Measurements
in this study compare with the stated main commit; they do not combine results
from the concurrent PR.
