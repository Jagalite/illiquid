# Shuffled checkpoint identity projection

## Scope

The main-actor `PlaybackController.checkpointSession()` reconciles saved shuffle order whenever a checkpoint is captured. During ordinary playback, position changes of at least ten seconds trigger a checkpoint; pause and playlist edits can also capture one. On the pinned base `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`, this uses `PlaylistMutation.restoringOrder(...).map(\.id)`.

The checkpoint only needs IDs. The old expression builds a dictionary of complete playlist items, a current-ID array and a restored-item array, then normalizes every returned item's URL again in `map`. The candidate projects IDs directly with a set and ordered ID arrays. It computes each input ID once, emits surviving saved IDs, then appends new IDs in current order. Empty and singleton inputs avoid indexing work. It adds no persistent cache and does not change the full-item unshuffle operation.

Original playlist entries and their subtitle metadata still belong to the controller/checkpoint. Removing temporary containers does not free that live user data or imply an equal reduction in the player's resident memory.

## Correctness

`PlaylistOrderRestorationTests` applies its independent integer-label model to both full-item restoration and the new ID projection across 41,261 current-queue/saved-order combinations. Additional tests cover successive edits, decoded raw URL aliases, unsupported file authorities, distinct remote query strings, and exact UTF-8/JSON parity for canonically equivalent Unicode IDs. The set's removed stored member is emitted, preserving the current item's spelling rather than copying a possibly different saved spelling.

The native integration job compiles the complete application graph and runs the existing persisted-shuffle/relaunch controller regression alongside the focused playlist tests. The experiment does not qualify live UI frame timing, decoder throughput, energy use, or full-app peak memory.

## Reproduce

Follow `AGENTS.md`: submit builds through `/Volumes/seed1/Projects/kyoto/kyoto.py` when available. For example, submit the complete benchmark runner as one Kyoto job and inspect its completion/logs. The workflow checks for Kyoto before direct compilation; its ephemeral runners build serially in isolated directories when the queue is unavailable.

From a full checkout containing the pinned base commit, with Swift 6.1+ and Python 3:

```sh
bash Scripts/test-playlist-restoration.sh
bash Scripts/test-playlist-restoration.sh -c release
python3 Benchmarks/ShuffleCheckpointIdentity/run.py \
  --output /tmp/illiquid-shuffle-checkpoint-native
# Linux/glibc only: separate malloc-family allocation-request observations
python3 Benchmarks/ShuffleCheckpointIdentity/run.py \
  --output /tmp/illiquid-shuffle-checkpoint-linux --allocations
```

Output directories must be new. The runner preserves source hashes, compiler/platform metadata, exact commands, source snapshots, calibration, every observation and paired summaries. The base implementation is read from the pinned Git commit and renamed only for coexistence with the production candidate in the same executable. The four production model/utility sources are compiled as actual source files, without model stubs.

Timing uses optimized Swift, fresh processes and six alternating baseline/candidate and candidate/baseline pairs per workload. Both variants use the same calibrated iteration count. Fixtures, full byte-level parity, and warmup are outside the measured interval. Each macOS call drains its autorelease pool. The timed loop consumes output counts and endpoint byte lengths, and validates a checksum. All observations are retained; there is no speedup assertion in CI.

The four workloads are unchanged reversed order, removals plus new additions, duplicate current/saved IDs, and an empty saved order. Sizes are 1, 32, 1,000 and 10,000 base items; the duplicate workload has twice that many input items. Timing summaries are medians of per-process mean call times, not interaction latency percentiles.

Linux allocation observations use the existing `Benchmarks/NonDecodePerformance/allocmeter.c` in separate instrumented processes. It counts successful malloc/calloc/realloc requests and requested bytes, excludes aligned allocation APIs, and measures neither live/peak heap nor RSS. These figures must not be presented as native macOS allocation or resident-memory measurements.

## Results

Candidate validation is pending. The branch's workflow must complete before this change is proposed as a successful optimization. Measured results and stable CI links will be recorded here after qualification.
