# Playback checkpoint identity research

## Question and acceptance criteria

`PlaybackCheckpoint.record()` checks whether the current source belongs to its
playlist before retaining the collection folder. The baseline repeats the
source URL's lexical/Unicode normalization for every visited local item, and
does the same work when the checkpoint has no collection folder. The candidate
reuses that invariant identity within the call and skips an irrelevant lookup
when the folder is absent.

The experiment measures the **complete production `record()` call**, including
the unchanged session-record constructor and playlist deduplication. It does
not measure JSON encoding, disk writes, queue scheduling, or playback rendering.

Acceptance criteria, declared before timing:

- Native macOS median wall and process CPU time must improve by at least 15% on
  1,000- and 10,000-entry late-hit and missing-source workloads, with and without
  a collection folder. At least 7 of 8 paired observations must improve for each
  primary workload and metric.
- Empty, singleton, small-playlist, early-hit, and remote-source controls must
  have no repeatable median slowdown greater than 10%. A noisy control is rerun
  separately and all observations retained rather than silently discarded.
- Baseline and candidate must emit identical complete sorted-key session JSON
  for the workload fixtures after replacing only the clock-derived `updatedAt`
  value with a fixed timestamp. The original timestamp must fall within its
  call's wall-clock bounds. Regression tests must pass on both arms.

The pinned baseline is `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`. Only
`Sources/IlliquidPlayer/Player/PlaybackCheckpointWriter.swift` may differ among
the compiled production sources. Source, harness and executable hashes, commands,
raw measurements, calibration, output hashes and timing distributions are
retained. Measurements run serially in fresh processes, with alternating AB/BA
pair order, identical iteration counts within each pair and fixture creation
outside the measured interval. Production code and the driver use separate
modules to prevent the driver from replacing the measured work.

## Reproduction

When the shared Kyoto queue is available, submit the following command through
`/Volumes/seed1/Projects/kyoto/kyoto.py`. Otherwise use an isolated build directory
and run the command directly, with no competing build or benchmark workload:

```sh
python3 Benchmarks/CheckpointIdentity/run.py --output /tmp/checkpoint-identity --run-tests
```

`--quick` reduces the workload matrix and pair count for exploratory runs.
`--enforce-performance` makes CI fail unless the full native cohort, all four
baseline/candidate debug/release test runs, and the declared timing gates pass.
Native macOS compilation uses complete, unmodified production support files.
The portable Linux check substitutes only a disabled `LifecyclePerformance`
diagnostic flag because `os.signpost` is unavailable; no measured record or
identity code is extracted or rewritten. Linux results are supporting evidence,
not the native performance qualification.

Results and qualification boundaries are recorded in `RESULTS.md` after the
experiment completes.
