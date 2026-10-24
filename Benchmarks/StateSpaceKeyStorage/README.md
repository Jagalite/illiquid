# State-space canonical-key storage

This benchmark measures the bounded playback state-space **developer tool**.
It does not launch Illiquid, decode media, or measure player memory.

The baseline retains each large `PlaybackSearchStateKey` value both in the
`visited` dictionary and in a separate array used only by the final digest.
The candidate digests `visited.keys` directly. The avoidable storage is the
array's inline values, capacity, and associated ownership work; nested String
and Array payloads already share copy-on-write buffers.

## Run

Follow the repository's Kyoto build coordination instructions when the shared
queue is available. The runner uses fresh isolated SwiftPM packages and builds
the baseline and candidate serially.

```sh
python3 Benchmarks/StateSpaceKeyStorage/run.py --output /tmp/state-space-key-storage --pairs 6
```

The default caps are 1,000, 10,000, and 50,000 states, using the real `seek`
model's `ready-playing` seed and PR-like bounds with the nondeterministic time
budget disabled. The benchmark requires every cap cohort to reach its requested
state count. Each observation uses a new optimized executable process. Order
alternates AB/BA; use an even pair count for an exactly equal number of each
order. The default five pairs are three/two per cohort, with starting order
alternating across cohorts.

For a short exploratory run:

```sh
python3 Benchmarks/StateSpaceKeyStorage/run.py --output /tmp/state-space-prototype \
  --pairs 1 --caps 1000 --skip-controls
```

Linux supports a portable prototype with `mallinfo2`; native qualification
requires macOS. A zero or unavailable native allocator, resident-memory, or
footprint sampler fails the run. Existing state-space regression tests are run
separately with `Scripts/test-state-space-key-storage.py`.

## Exact sources and semantic parity

The runner stages complete, unmodified `IlliquidPlaybackCore` and
`IlliquidPlaybackStateSpace` modules, plus their only `IlliquidCore` dependency,
the exact production `MediaTrack.swift`. It pins the baseline to
`4abf4b44f13386ccd04f1ce4ad0e756255ca4d14`. Only
`PlaybackStateSpaceExplorer.swift` may differ between production source sets.
Source, harness, and executable SHA-256 receipts are retained; source integrity
is checked again after the run. No production search implementation is copied
into the harness.

Every pair compares the complete result summary, oracle, graph, failures, and
predecessors. It also compares every public field of every returned node,
including the full core state, environment, retained late results, ghost state,
sequence, and depth. JSON is only a transport: the comparator decodes Swift
values and uses their typed equality. This preserves Array order and compares
Sets and Dictionaries by value despite randomized hash iteration.

Eight extra control pairs cover all six independent models at depth two, a
seed-only result, and an injected failure. The latter constructs the actual
production artifact, minimizes its witness, and replays the failure. Paired
artifacts and replay results must agree. No JSON encoding, receipt comparison,
or replay happens inside the timed search.

Full control receipts are retained compressed in `control-receipts/`.
Large cap receipts are streamed one node at a time during comparison, hashed,
and removed after exact equality succeeds. `comparisons.jsonl` retains their
sizes, SHA-256 hashes, compared node/edge/predecessor/failure counts, and search
summaries. They can be regenerated from the pinned source and harness receipts.

## Memory and timing boundaries

`beforeSearch` is sampled after the sampler and clocks have been initialized.
The existing synchronous progress callback samples after each fully completed
BFS layer while search-local storage is live. A cap may stop in a partial layer;
there is no callback for that partial layer or for the final digest. Accordingly
the maximum progress allocator/RSS/footprint is a **sampled lower bound**, not
the whole-search peak.

Immediately after `run` returns, the harness samples `getrusage` peak RSS before
allocating any JSON encoder or receipt. This process high-water mark includes
the final digest and local-container destruction, as well as process startup.
This matters because the candidate keeps `visited` available through the
digest, while an optimizer could release the baseline dictionary earlier.

`afterSearchWithResultAlive` holds the complete returned result alive. Both
search-local key collections are already gone, so that endpoint is an expected
control, not the main evidence for the optimization. It is not a leak test.

Darwin live bytes use `malloc_zone_statistics(NULL).size_in_use` across zones.
Current RSS and physical footprint use `TASK_VM_INFO`; the process high-water
mark uses `getrusage`. Linux's footprint field is zero and explicitly unavailable.
Wall and process CPU times include search, callback sampling, final digest,
and search-local teardown. Their scope excludes all semantic serialization,
comparison, artifact construction, and replay. Seed-only timings are clock and
startup overhead and should not be reported as speed improvements.

`observations.jsonl` holds every raw memory sample and timing. `summary.json`
reports medians plus the minimum, median, and maximum paired baseline-minus-
candidate differences. Positive differences mean lower candidate cost; negative
differences remain visible. Results qualify this developer search workload only.
