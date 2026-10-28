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
current order. The checkpoint calls this helper directly.

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

Benchmark measurements and native qualification results will be recorded here
after their runs complete. No timing or heap reduction is asserted by the test
results alone.

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

The `Playlist checkpoint identity construction` workflow runs portable component
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
