# Effect retirement allocation research

This study targets the temporary dictionary built by
`PlaybackCore.settleEffects(for:)` when it retires a playback authority. The
baseline filters complete outstanding-effect records into a new dictionary and
then maps that dictionary to IDs. The candidate collects matching IDs eagerly
with `compactMap`, then runs the existing removal/completion loop.

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
and Codable round trips. Both baseline and candidate run the complete Core and
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
