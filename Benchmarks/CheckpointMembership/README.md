# Playback checkpoint membership research

## Question

Can playback checkpoints avoid redundant playlist membership work while returning
the same complete session record?

`PlaybackCheckpoint.record()` runs on the coalescing persistence writer's queue.
The controller requests a checkpoint during playback and lifecycle transitions;
ordinary progress checkpoints are gated by a ten-second position change. The
original membership predicate normalizes both each visited playlist URL and the
unchanging current-source URL. It performs that scan even if there is no
collection folder to preserve. The captured playlist index is not used to answer
the membership question.

The candidate skips the membership check when the folder or playlist is absent,
normalizes the source once, and verifies the item at a valid captured index.
A mismatching, missing, or out-of-range index falls back to a playlist scan.
Singletons go directly to their one-item scan, avoiding a repeated comparison
when the hinted item does not match.
The index is only a hint: it never independently proves membership, and the
saved index is not changed. No persistent cache or new ownership is introduced.

Record construction still invokes the existing playlist deduplication routine.
This experiment measures that complete construction, not just the faster
membership predicate. JSON encoding, disk writes, coalescing, UI work, and other
history stores are outside the timing interval.

The timed loop also includes bounded scalar-output checks, checksum consumption,
record disposal, and a per-call autorelease pool on macOS. These costs are shared
by both implementations. Complete output validation and fixture construction
happen outside the timer. Absolute results describe this instrumented component
workload, not the entire persistence queue.

## Frozen comparison and qualification plan

Baseline: `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`.

Only `Sources/IlliquidPlayer/Player/PlaybackCheckpointWriter.swift` differs
between the two implementations. Both use identical current supporting Core
sources and the same tests and driver. The staging manifest records source and
executable hashes. The complete checkpoint source is compiled into a separate
`IlliquidPlayer` module; the driver cannot inline its implementation.

The staged Core module includes the complete production `PlaybackSessionRecord`
and `PlaybackSessionStoring` declarations. The unrelated disk-store implementation
is excluded at a checked source boundary. There are no replacement record,
normalization, deduplication, or playlist implementations.

Before evaluating timings, require:

- Baseline and candidate to pass the same semantic tests in debug and release.
- Exact complete-record parity, with only the intentionally fresh `updatedAt`
  timestamp set to a fixed value after checking that it falls within the call's
  time bounds.
- Coverage of valid and stale indices, nil and extreme indices, duplicate
  identities with different metadata, lexical and Unicode aliases, malformed
  source/URL combinations, unsupported authorities, absent sources, no folder,
  remote sources, empty playlists, and snapshot independence.
- Every timing observation to retain and check its result, with all observations
  preserved, including slow samples.

The confirmatory native study uses eight balanced baseline/candidate pairs per
workload in fresh processes, with warm-up and calibration outside the reported
samples. Each pair uses the same iteration count, sized to measure the faster
implementation for a useful interval. Wall and process CPU time are reported
separately. Workloads include ordinary 32-item playlists and larger 1,000- and
10,000-item collections, early/middle/late membership, index fallback, absent
membership, and unchanged-path controls.

The premeasurement target is at least a 15% median paired reduction in both wall
and CPU time for the 1,000- and 10,000-item middle/late indexed workloads. Inspect
first-item, singleton, empty, and remote-source controls for regressions; a
repeatable increase greater than both 10% and 5 microseconds per record requires
investigation. These are research decision criteria, not noisy timing assertions
for routine CI. Small statistically unclear differences must be reported as
inconclusive.

Native app integration separately builds the app/test graph and runs checkpoint
and coordinator regression suites using the repository's pinned native SDK.
Component tests, app integration, and live UI/playback qualification are distinct.
No FPS, energy, whole-player responsiveness, or storage-I/O claim follows from
this benchmark.

## Reproduce

Use the repository's Kyoto queue when available, as specified in `AGENTS.md`.
With an isolated toolchain/runner where that queue is unavailable:

```sh
python3 Benchmarks/CheckpointMembership/test_harness.py
python3 Benchmarks/CheckpointMembership/run.py \
  --pairs 8 --target-ms 100 --output /tmp/checkpoint-membership
```

The output directory must be new or empty. The pinned baseline must be present
in local Git history. Swift 6.1 or newer with bundled Swift Testing and Python
3.9 or newer are required. On macOS the runner records and explicitly selects
the active Xcode SDK. CI uses macOS 26 and Xcode 26.6.

`--quick` retains every semantic test and complete-record comparison but measures
six workloads with two pairs and a 20 ms target; it is a mechanics check, not the
confirmatory study. `--tests-only` skips timings. Production sources, tests, driver,
compiler flags, toolchain information, binary hashes, command output, calibration,
every observation, and summaries are retained under `OUTPUT/evidence/`.

The native workflow runs the full experiment on the research branch and manual
invocation. PR runs use the short timing cohort and repeat semantic qualification.
A separate job builds the full release app and tests checkpoint, coordinator,
playlist, and session behavior.

## Results

The first complete Linux cohort compared the baseline with `3e0af482` using
320 observations across 20 workloads. All primary indexed middle/last groups
improved in all eight CPU and wall pairs, but the `single-absent` control crossed
the predeclared regression investigation gate: median paired increases were
63.33% / 11.30 microseconds wall and 48.68% / 6.71 microseconds CPU. Its valid but
nonmatching index caused a second normalization of the only playlist item during
fallback. The candidate was revised so singletons go directly to one comparison.
The adverse cohort is retained as exploratory evidence, and a fresh complete
cohort is required for the revised production source.

The revised measurements and native qualification are in progress. No macOS
performance or application-validation result is claimed while its jobs are queued.
