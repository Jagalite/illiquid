# Shuffled checkpoint identity projection

## Scope

The main-actor `PlaybackController.checkpointSession()` reconciles saved shuffle order whenever a checkpoint is captured. During ordinary playback, position changes of at least ten seconds trigger a checkpoint; pause and playlist edits can also capture one. On the pinned base `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`, this uses `PlaylistMutation.restoringOrder(...).map(\.id)`.

The checkpoint only needs IDs. The old expression builds a dictionary of complete playlist items, a current-ID array and a restored-item array, then normalizes every returned item's URL again in `map`. The candidate projects IDs directly with a set and ordered ID arrays. It computes each input ID once, emits surviving saved IDs, then appends new IDs in current order. Empty and singleton inputs avoid indexing work. It adds no persistent cache and does not change the full-item unshuffle operation.

Original playlist entries and their subtitle metadata still belong to the controller/checkpoint. Removing temporary containers does not free that live user data or imply an equal reduction in the player's resident memory.

## Correctness

`PlaylistOrderRestorationTests` applies its independent integer-label model to both full-item restoration and the new ID projection across 41,261 current-queue/saved-order combinations. Additional tests cover successive edits, decoded raw URL aliases, unsupported file authorities, distinct remote query strings, and exact UTF-8/JSON parity for canonically equivalent Unicode IDs. The set's removed stored member is emitted, preserving the current item's spelling rather than copying a possibly different saved spelling.

The native integration job compiles the complete application graph and runs the existing persisted-shuffle/relaunch controller regression alongside the focused playlist tests. The recurring-checkpoint regression removes and appends entries while shuffled, advances playback past the normal checkpoint threshold, and reads the actual atomic session store before shutdown to verify the saved base order, complete playlist, selected item, position and pause state. Native execution of this added regression remains pending until the integration job passes. The experiment does not qualify live UI frame timing, decoder throughput, energy use, or full-app peak memory.

## Reproduce

Follow `AGENTS.md`: submit builds through `/Volumes/seed1/Projects/kyoto/kyoto.py` when available. Submit the complete benchmark runner as one Kyoto job, include `--kyoto-job` in that queued command, and inspect its completion/logs. The flag asserts that the whole runner is executing inside the queue; it is not a direct-build override. The workflow checks for Kyoto before direct compilation; its ephemeral runners build serially in isolated directories when the queue is unavailable.

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

Output directories must be new. The runner preserves source hashes, compiler/platform metadata, exact commands, source snapshots, calibration, every observation and paired summaries. The baseline `PlaylistMutation` enum is extracted from the pinned Git commit and renamed only for coexistence with the production candidate in the same executable. Both use the unchanged shared playlist model enums; the manifest hashes both the original baseline file and the extracted compiled enum. The four production model/utility sources are compiled as actual source files, without model stubs.

Timing uses optimized Swift, fresh processes and six alternating baseline/candidate and candidate/baseline pairs per workload. Both variants use the same calibrated iteration count. Fixtures, full byte-level parity, and warmup are outside the measured interval. Each macOS call drains its autorelease pool. The timed loop consumes output counts and endpoint byte lengths, and validates a checksum. All observations are retained; there is no speedup assertion in CI.

The four workloads are unchanged reversed order, removals plus new additions, duplicate current/saved IDs, and an empty saved order. Sizes are 1, 32, 1,000 and 10,000 base items; the duplicate workload has twice that many input items. Timing summaries are medians of per-process mean call times, not interaction latency percentiles.

Linux allocation observations use the existing `Benchmarks/NonDecodePerformance/allocmeter.c` in separate instrumented processes. It counts successful malloc/calloc/realloc requests and requested bytes, excludes aligned allocation APIs, and measures neither live/peak heap nor RSS. These figures must not be presented as native macOS allocation or resident-memory measurements.

## Results

### Linux component qualification

Measured production candidate: `b70bb638879a58a37ac8ffd9e02a27286c342fc6`.
[Successful Linux job](https://github.com/Jagalite/illiquid/actions/runs/40635553505/job/122641568130),
Swift 6.2.1, x86_64 Linux/glibc 2.35. All 25 focused tests passed, including
the independent 41,261-case ordering model and exact UTF-8/JSON tests.

| Base items | Workload | Baseline ms/call | Candidate ms/call | Time reduction | Baseline requested bytes/call | Candidate requested bytes/call |
|---:|---|---:|---:|---:|---:|---:|
| 1 | unchanged | 0.0154 | 0.0072 | 53.5% | 4,876 | 2,310 |
| 1 | edited | 0.0155 | 0.0072 | 53.7% | 4,876 | 2,310 |
| 1 | duplicates | 0.0231 | 0.0159 | 31.2% | 7,138 | 4,716 |
| 1 | no-base | 0.0072 | 0.0071 | 0.3% | 2,310 | 2,310 |
| 32 | unchanged | 0.5094 | 0.2672 | 47.6% | 155,584 | 76,664 |
| 32 | edited | 0.5118 | 0.2699 | 47.3% | 155,584 | 76,664 |
| 32 | duplicates | 0.7512 | 0.5172 | 31.1% | 228,104 | 149,184 |
| 32 | no-base | 0.4817 | 0.2560 | 46.8% | 147,984 | 76,120 |
| 1,000 | unchanged | 16.4783 | 8.7716 | 46.8% | 4,956,800 | 2,434,360 |
| 1,000 | edited | 16.4078 | 8.6091 | 47.5% | 4,999,448 | 2,455,684 |
| 1,000 | duplicates | 24.4212 | 16.6549 | 31.8% | 7,275,360 | 4,752,920 |
| 1,000 | no-base | 15.3699 | 8.1469 | 47.0% | 4,719,816 | 2,418,328 |
| 10,000 | unchanged | 169.5279 | 89.2931 | 47.3% | 50,827,504 | 25,165,336 |
| 10,000 | edited | 174.0364 | 93.5208 | 46.3% | 50,890,168 | 25,196,668 |
| 10,000 | duplicates | 252.2784 | 172.1982 | 31.7% | 74,778,888 | 49,116,720 |
| 10,000 | no-base | 160.7521 | 84.8195 | 47.2% | 48,591,968 | 25,005,304 |

Timing and allocation columns come from separate processes. The duplicate
workload contains twice the base item count. The singleton with an empty saved
order is a control: both paths already evaluate exactly one identity, and its
0.3% timing difference is treated as unchanged.

For 10,000 unique items with a saved order, measured time fell from 169.53 ms
to 89.29 ms (47.3%). Successful malloc-family requests fell from 540,031 to
270,030, and requested bytes fell from 50,827,504 to 25,165,336 (50.5%).
Those bytes are cumulative allocation traffic during a call, not memory
retained by the player. The duplicate-heavy workload still normalizes every
input item and improves less (31.7% time, 34.3% requested bytes).

[`evidence/linux-summary.json`](evidence/linux-summary.json) and [`evidence/linux-observations.jsonl`](evidence/linux-observations.jsonl)
retain every summary and raw observation from this successful run. The 256
observations comprise 192 uninstrumented timing processes and 64 separate
allocation processes. Summary medians were independently recomputed from the
retrieved raw rows, and all groups contain the expected AB/BA pairs.

### Native qualification

The macOS Foundation timing/debug/release job and full application-graph
integration are pending in [the same workflow run](https://github.com/Jagalite/illiquid/actions/runs/40635553505).
No native timing, native allocation, live UI or whole-app footprint result is
claimed from the Linux data.

### Evidence provenance

[`evidence/provenance.json`](evidence/provenance.json)
records the exact commit, run, job, and artifact IDs. The Actions artifact also
contains compiler/source receipts, command logs, source snapshots and calibration;
the checked-in raw measurements and source hashes remain available after that
temporary artifact expires. Initial setup attempts were corrected before the
retained dataset; no timed observations were discarded from this successful run.

The implementation was independently reviewed for ordering, current-ID spelling,
normalization semantics, caller scope and measurement fairness. Review exposed a
singleton-only Unicode test that did not reach the set path; the retained tests
cover both singleton and multi-item inputs.
