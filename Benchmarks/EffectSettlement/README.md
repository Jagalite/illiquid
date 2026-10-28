# Effect settlement: whole-core comparison

This experiment removes one temporary dictionary from source retirement in
`PlaybackCore.settleEffects(for:)`. The existing implementation filters the
outstanding-effect dictionary into another dictionary, then maps that dictionary
to IDs. The candidate gathers matching IDs with `compactMap` and keeps the
existing removal/completion loop.

The production diff is limited to that expression. Gathering IDs before removal
remains necessary because the source dictionary is mutated by the loop.

## Status and scope

This directory contains the protocol and executable qualification harness.
A successful optimization is claimed only if the saved tests, semantic parity,
and predeclared timing gate pass. Raw observations and a manifest are uploaded by
the workflow; a failed gate remains a useful negative result.

Measurements cover a complete production `PlaybackCore.update` transition on
Ubuntu with Swift 6.2.4 in release mode. They do not establish macOS playback,
decoder, frame-rate, end-to-end memory, or energy improvements. No allocation
traffic or byte savings are reported. The source-level change demonstrably
removes the intermediate filtered dictionary; completed-history operations and
the final ID array still allocate as required.

## Why the complete transition matters

Completion of a pending replacement's `awaitPreroll` result retires outstanding
effects for the old committed authority, records completion, installs the new
session, produces a UI snapshot, and checks production invariants. All of that
work is inside the timer. Timing only a toy dictionary expression would miss the
cost and ownership behavior of the real transition.

The completed-effect history is an exact contiguous prefix plus a sparse Set,
not a bounded FIFO. The old filtered dictionary and the new ID array can visit
matching IDs in different orders. Both must produce the same completed
membership, prefix, and sparse membership. Transient compaction/allocation work
can differ with order, which is another reason to measure the whole update and
retain normal randomized Swift hashing.

## Workloads and ownership

Every fixture starts with a new `PlaybackCore` and uses public event reduction:

1. Load and preroll an initial paused source.
2. Issue N pause commands, leaving their real `applyRate` effects outstanding.
3. Load a replacement and complete its `openSource` result.
4. Time the complete replacement `awaitPreroll` result.
5. Validate the resulting state outside the timer.

N = 0, 1, 8, and 64 are ordinary workloads. N = 4096 is separately labeled
stress and never used to rescue a failed ordinary-workload result. Each pause
command runs production invariant checks during setup, so stress setup is
quadratic; it intentionally uses only two measured transitions per process.

Fixtures are independently created before each timed batch. No prepared core or
state template is copied into the timed path, and no external state snapshot
keeps its dictionary storage shared. Stored effect contexts contain identifiers;
they do not retain a copy of the outstanding dictionary. Batch capacity is
bounded to at most 256 fixtures and approximately 16,384 outstanding targets.
Stress uses one fixture per batch.

One complete warmup fixture runs outside the timers in every process. Timers
wrap only the loop that calls `core.update` and stores each returned transition
in an existing fixture slot. Fixture creation, result validation, canonical
encoding, and destruction occur outside both timers. The small identical driver
loop and clock-reading overhead are included. Process CPU time is the primary
metric; monotonic wall time is also saved.

## Correctness gates

The runner stages the actual source files unchanged, following
`Benchmarks/CompletedEffectHistory`:

- The real `MediaTrack.swift` dependency and every playback-core source.
- Every playback state-space source and both complete corresponding test suites.
- The same new effect-settlement tests against baseline and candidate.
- The same benchmark harness against both implementations.

No platform shim, replacement state machine, or production-source transformation
is involved. Baseline is pinned to
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`. Tests run serially in baseline
release, candidate debug, and candidate release configurations with warnings
treated as errors.

Before timing, both binaries emit complete canonical final states, transitions,
and late-duplicate dispositions for all five sizes. Each size also has a mixed
authority variant: three earlier-generation pause effects survive a completed
seek and must remain byte-for-byte value-equal as outstanding records after the
current generation is retired. Fields omitted by `PlaybackCanonicalState`
are included explicitly in the verification wrapper. Parsed JSON must compare
exactly between baseline and candidate.

Every timed fixture additionally checks accepted disposition, no new effects,
committed paused replacement, no pending session, no invariant violations, exact
outstanding-record equality, and exact completed-ID membership. Regression
tests check prefix/sparse behavior and all four settlement call paths, including
pending-load supersession and successful cancellation. Late duplicate results
must stay duplicates; unrelated authority records must survive retirement.

## Paired protocol and predeclared success rule

The runner uses eight fresh-process pairs per workload, alternating baseline /
candidate and candidate / baseline. Four pairs run each order. Every process has
normal randomized Swift hashing. Raw timings, order, pair index, checks, and
iteration counts are retained.

Excluded pilot processes determine one iteration count shared by baseline and
candidate for each ordinary workload, targeting at least 40 ms aggregate CPU
time using the faster pilot. Counts are frozen before the eight measured pairs.
Every ordinary measured observation must contain at least 20 ms CPU time.
Calibration caps are explicit in `run.py`; falling short fails qualification
rather than silently relaxing the duration gate. Stress always uses two
iterations and has no minimum-duration gate.

The experiment succeeds only if all correctness gates pass and:

- At N = 8 and N = 64, the median of the eight paired candidate/baseline CPU
  ratios is at most 0.95, with the candidate faster in at least six pairs.
- At N = 0 and N = 1, the median paired CPU ratio is at most 1.05.
- Every ordinary observation meets the 20 ms duration requirement.

The 5% control tolerance is a declared noise allowance, not proof that no
regression of any size exists. Wall-time distributions and all individual ratios
are reported for review. CPU frequency, contention, and allocator/hash variation
remain practical limitations of hosted CI. These are component results from a
single toolchain/runner; broader playback claims require native measurement.

Thresholds must not be changed after looking at results to make a failed
experiment pass. A follow-up protocol must disclose the previous result.

## Reproduce and inspect evidence

On the Ubuntu CI runner, where the repository's shared Kyoto queue is
unavailable, builds and tests run directly in isolated package directories and
are serialized:

```sh
python3 Benchmarks/EffectSettlement/run.py --output /tmp/illiquid-effect-settlement
```

Use a fresh empty output directory. The script requires a Swift 6 toolchain,
Python 3.10 or later, Git, and access to the pinned baseline commit. CI pins
Swift 6.2.4. `--tests-only` runs builds, all test gates, and exact semantic parity
without repeating timing pairs.

If `/Volumes/seed1/Projects/kyoto/kyoto.py` is available, submit the entire
runner through that queue, adding `--kyoto-submitted` to the runner arguments.
Inspect the submitted job, logs, and wait result before describing validation
as complete. The flag records that the caller already used the queue; it does
not enqueue a job. The script refuses an unqueued direct run when Kyoto exists.
This portable test target does not run or qualify the app's UI tests.

Evidence files include:

- `manifest.json`: commit IDs, compiler, platform, worktree status, unchanged
  source hashes, generated manifest hash, harness hashes, and executable hashes.
- `commands.jsonl` and named logs: complete build/test/benchmark invocations,
  captured output, exit status, and elapsed command time.
- `verification.json`: complete baseline and candidate semantic outputs.
- `calibration.json`: excluded pilots and frozen iteration counts.
- `observations.json`: every measured fresh-process observation.
- `summary.json`: per-transition medians, paired ratios/ranges, and the
  unchanged success gate's result.

The workflow publishes the evidence even on failure and emits numbered plain
JSON chunks in the Actions log, with each file's SHA-256 receipt. These chunks
can be reconstructed without downloading a binary artifact. Keep those artifacts
with any subsequent PR; a green compiler run alone is not the performance
qualification.
