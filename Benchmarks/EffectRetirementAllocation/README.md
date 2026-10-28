# Effect retirement allocation research

This study targets the partial-match temporary dictionary built by
`PlaybackCore.settleEffects(for:)` when it retires a playback authority. The
baseline filters outstanding-effect records, then maps the filtered dictionary
to IDs. Swift 6.1.3 shares the original dictionary when every record matches and
returns an empty dictionary when none match; only partial matches construct a
new full-record table. The candidate examines each authority once by index, preserves empty and
all-match paths, and collects only IDs for partial matches before running the
existing removal/completion loop. It defers collecting a matching prefix until
the first nonmatch proves the selection is partial; only that prefix's keys
are revisited, without checking those authorities again.

The baseline is `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`. This is a separate
investigation from checkpoint folder-membership construction.

## Reproduce

On a host with Swift 6.1 or later:

```sh
python3 Benchmarks/EffectRetirementAllocation/run.py \
  --pairs 6 --target-ms 50 --output /tmp/effect-retirement-results
```

Use a new output directory. When the shared Kyoto queue is available, submit
that complete command through it as required by `AGENTS.md`. The hosted jobs
explicitly record Kyoto's absence and compile isolated packages serially.

## Correctness

The new regression suite drives the real reducer through source replacement,
pending-load supersession, stop, and successful/failed cancellation. It covers
exact authority equality across sessions, generations and revisions, survival
of application effects, late duplicate/unknown callbacks, state-copy isolation,
and Codable round trips. It also checks all 64 assignments of six records to
the retiring versus application authority, including their later callbacks.
Both baseline and candidate run the complete Core and
StateSpace test suites in debug and release.

The eager ID collection must finish before removals begin. A lazy dictionary
view could retain the original storage and cause copy-on-write during removal.
The candidate intentionally preserves the eager boundary.

## Measurements

Both variants compile complete production Core and StateSpace modules with the
real `MediaTrack.swift` dependency. There are no extracted declarations,
substitute reducers, or platform stubs. The runner records all source hashes and
rejects any production difference outside `PlaybackCore.swift`.

The fixture first performs real events to load A paused and prepare replacement
B through its open result. It then seeds checkpoint records using unused effect
and operation IDs. Populations are 0, 1, 8, 32, 512, and 4,096 records, with all,
alternating, or none belonging to A's retiring authority. The mixed population
is a synthetic authority-selection stress case, not an observed player workload.

Only the real `core.update` that accepts B's preroll completion is measured.
It commits B, retires A's matching effects, and preserves unrelated records.
Fixture creation, result consumption, canonicalization, encoding, and state
destruction are outside that event's window. Setup owners are released before
the timed update so they do not keep an extra copy of its dictionary.

The revised cohort also includes a sparse case with only the first seeded
record matching, for 24 workloads in total. The single-pass revision reserves
only the known matching prefix and then grows the partial ID array as needed.
It never reserves the total outstanding population for a sparse selection.

Six baseline/candidate pairs alternate AB/BA in fresh processes. Timing targets
50 ms of summed event time, with a cap on excessive setup work. Every timed event
contributes to a noninlined checksum. A separate untimed fixture verifies exact
outstanding records, completion membership, session state, allocator and event
counters, invariants and Codable round trips. Each pair must produce the same
production canonical digest; the otherwise-omitted pending-session field is
explicitly checked absent.

Linux additionally runs separate allocation processes. Their preload library
counts successful `malloc`, `calloc` and `realloc` requests on the measured
thread, enabled only around the synchronous reducer update. A standalone
self-test checks an empty window and three known requests totaling 225 bytes.
Timing processes explicitly omit the preload library.

Requested bytes measure cumulative allocation traffic, including a successful
reallocation's requested new size. They are not retained bytes, peak memory,
resident memory, allocator usable sizes, or object counts. Aligned allocation
APIs and frees are excluded. Native macOS runs do not use this Linux probe.

Dictionary iteration order may change, so the sparse completion-history Set
can take a different temporary allocation path. The measured totals cover the
complete reducer transition; individual byte differences are not all assigned
to the removed dictionary.

## Evidence and limits

The workflow retains source/test/driver snapshots, compiler and binary hashes,
test and command logs, calibration, every raw observation, semantic receipts and
summaries. Important records also appear as `EFFECT_TEST`,
`EFFECT_OBSERVATION`, `EFFECT_RESULT` and `EFFECT_MANIFEST` lines in the job log.

Linux component results do not establish macOS timing or allocation behavior.
These tests do not build the full media-player application or exercise live
playback, native renderer resources, UI latency, power or energy. Both versions
still scan outstanding effects and allocate the ID array; the asymptotic cleanup
complexity is unchanged.


## Rejected first implementation

The first experiment used eager `compactMap`. It passed all 113 Core/StateSpace
tests in each baseline/candidate debug/release configuration, but its controls
ruled it out. In the Linux 4,096-effect case with no matching authority, median
elapsed time increased from 74.87 to 353.66 microseconds (+377.3% paired change).
With all effects matching, median requested bytes increased from 166,664 to
265,136 (+59.1% paired change). Partial-match requested bytes fell substantially,
but those regressions made the simple rewrite unsuitable.

## Rejected counted-selection implementation

The second experiment counted matching authorities, reserved exactly that many
IDs, and scanned again to collect them. It passed the same 113 tests in all four
configurations. Mixed/4,096 requested bytes fell from 1,427,728 to 83,664 (94.1%)
and paired elapsed time fell 30.9%. However, the added sparse cases caught the
second scan's cost: sparse/512 elapsed time increased 36.8% and sparse/4,096
increased 58.2%, with all six pairs slower in both cases. This version was also
rejected.

The single-pass revision checks each authority once, retaining the indexed
projection and efficient all/none cases. All earlier observations are retained
as rejected cohorts; their improvements are not presented as final results.

The relevant standard-library fast paths are in
[Swift 6.1.3 NativeDictionary.swift](https://github.com/swiftlang/swift/blob/swift-6.1.3-RELEASE/stdlib/public/core/NativeDictionary.swift).
