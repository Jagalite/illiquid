# Playback checkpoint membership follow-up research

## Question

Can playback checkpoints avoid repeated work after an index miss while returning
the same complete session record?

`PlaybackCheckpoint.record()` runs on the coalescing persistence writer's queue.
The controller requests a checkpoint during playback and lifecycle transitions;
ordinary progress checkpoints are gated by a ten-second position change. The
original membership predicate normalizes both each visited playlist URL and the
unchanging current-source URL. It performs that scan even if there is no
collection folder to preserve. The captured playlist index is not used to answer
the membership question.

The final candidate retains PR #140's early source-identity validation, skips
the membership check when the folder or playlist is absent, and verifies the
item at a valid captured index.
A mismatching, missing, or out-of-range index falls back to a playlist scan.
Singletons go directly to their one-item scan, avoiding a repeated comparison
when the hinted item does not match.
The fallback skips an item already checked by the indexed probe. A lazy-source
alternative was rejected after the malformed-input controls regressed.
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

Original-main reference: `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`.

Primary incremental reference:
`2620d561d11c9a7d9396d3b455424a10a6dddcd7`, the pinned implementation in
[concurrent PR #140](https://github.com/Jagalite/illiquid/pull/140).
That proposal already verifies the captured index, skips folderless scans, and
reuses the source key. It is stacked on
[PR #124](https://github.com/Jagalite/illiquid/pull/124), whose normalized linear
scan was inspected at `9f21c84bbe097984642c8fc08b7c8c1fd31a6c41`.
Both appeared while this research was running. This follow-up is stacked on
PR #140 and attributes the principal index shortcut to that proposal. Its
incremental changes are avoiding the separate singleton probe and skipping an
already-probed item during fallback.
The overlapping original-main improvements are not additive or a new claim.

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

The original-main study's premeasurement target was at least a 15% median paired
reduction in both wall and CPU time for the 1,000- and 10,000-item middle/late
indexed workloads. That hypothesis is superseded as a novel contribution because
PR #140 already implements the indexed shortcut.

Before the first comparison against PR #140, the narrowed target was at least a
15% median paired reduction in both wall and CPU time for `single-absent` and
`unsupported-unicode-1`. These targets are informed by the earlier exploratory
findings; they are not presented as the original hypothesis. The ordinary
matching-index workloads are now unchanged-path controls. A repeatable increase
greater than both 10% and 5 microseconds per record in any control requires
investigation. Controls include unsupported source authorities with unsupported
playlists and a Unicode singleton, because lazy source rejection can add work
on malformed input. These are research decision criteria, not noisy timing
assertions for routine CI. Small statistically unclear differences must be
reported as inconclusive.

That first comparison at `29de8634` met both targeted improvements but failed the
malformed-input controls, so lazy source preparation was removed. Before the
fresh final-source cohort, the retained target is at least a 15% median paired
wall and CPU reduction for `single-absent`; the other 25 workloads are controls,
including the now-abandoned `unsupported-unicode-1` target. The same regression
investigation threshold applies. This is an explicitly narrowed follow-up to a
rejected experiment, not a claim that all earlier hypotheses were confirmed.

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
  --baseline-ref 2620d561d11c9a7d9396d3b455424a10a6dddcd7 \
  --pairs 8 --target-ms 100 --output /tmp/checkpoint-membership
```

The output directory must be new or empty. The selected baseline must be present
in local Git history. Omitting `--baseline-ref` selects the original-main reference
for historical reproduction; this comparison and the native workflow explicitly
select the pinned PR #140 implementation. Swift 6.1 or newer with bundled Swift Testing and Python
3.9 or newer are required. On macOS the runner records and explicitly selects
the active Xcode SDK. CI uses macOS 26 and Xcode 26.6.

`--quick` retains every semantic test and complete-record comparison but measures
six workloads with two pairs and a 20 ms target; it is a mechanics check, not the
confirmatory study. `--tests-only` skips timings. Production sources, tests, driver,
compiler flags, toolchain information, binary hashes, command output, calibration,
every observation, and summaries are retained under `OUTPUT/evidence/`.

The portable and native workflow jobs run the full experiment on the research branch and manual
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

The first direct PR #140 comparison at `29de8634` passed all correctness checks
and measured 416 observations across 26 workloads. `single-absent` improved by
35.04% paired wall/CPU and `unsupported-unicode-1` by 98.02%, but the lazy-source
proposal was rejected. With an invalid source and 1,000 unsupported playlist
items, it performed an unnecessary membership pass and increased wall/CPU time
by about 31%. With an invalid source and one raw Unicode item, median wall time
rose from 0.855 to 10.978 microseconds (1,142.67% paired increase). The baseline
rejects the source before touching that item, and singleton deduplication already
returns without normalizing it. The lazy proposal introduced that normalization.
The ordinary 10,000-item last-match control also showed an adverse 11.28% paired
wall result and is retained without exclusion. None of this rejected cohort's
improvements are attributed to the final eager-source implementation.

Fresh final-source measurements and native qualification are in progress.
No macOS performance or application-validation result is claimed while its jobs
are queued.
