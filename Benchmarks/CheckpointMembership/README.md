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

## Results

Measurement and native qualification are in progress. Results and reproduction
commands will be added after the experiment completes.
