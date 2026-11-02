# EOF read-ahead notification research

## Question and change

Can a finished subtitle input remain asleep while the playback clock advances?
`MediaSession.subtitleDemuxLoop` parks at EOF with
`subtitleReadAhead.wait(until: nil, generation: activeGeneration)`.
`NativePlaybackRuntime.consumeRuntimeObservation` continues forwarding
advancing playback time to that gate.

The baseline broadcasts on every advancing update. An EOF wait cannot become
admissible through clock progress: it needs generation invalidation or closure.
The candidate counts timestamped waiters under the existing condition lock and
broadcasts from `update` only when at least one is blocked. Clock recording,
timestamp admission, reset, close, and the blocked-reader diagnostic are unchanged.

The baseline is the complete production file from
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`. Its SHA-256 is checked before running.
The candidate is the complete current production file. Neither is rewritten,
instrumented, or replaced with a model.

## Reproduce

Requires Swift 6.1+ and Python 3.10+ on macOS 26 or Linux.

```sh
python3 Benchmarks/ReadAheadEOF/run.py --output /tmp/read-ahead-eof
python3 Benchmarks/ReadAheadEOF/run.py --tests-only --output /tmp/read-ahead-eof-tests
```

Use a fresh output directory for every attempt. When the repository's Kyoto queue
is available, submit the intended Python command through it as required by
`AGENTS.md`. Hosted runners lack that local queue and build isolated packages
serially; the product package and its shared `.build` are not used.

## Protocol

Both variants run the same behavioral tests in debug and release. They are built
as separate production modules, without cross-module optimization of the driver.
The optimized driver creates an actual blocked reader thread and waits for the
gate's readiness handshake before sending updates.

Each case has six fresh-process pairs, alternating AB/BA order, with three seconds
of paced observations per process. The EOF cases receive advancing clock updates
at 24, 60, or 120 Hz. These are representative requested update rates, not a
measurement of delivered observation frequency in the application.

Two controls use the same 120 Hz producer pacing: EOF idle sends no updates;
timed update must admit its reader on the final update before the gate is closed.
Ticks, final position, and admission results must agree across variants. Every
observation is retained. No timing threshold determines correctness.

The reader samples CPU time on its own synchronous thread before and after the
production wait. Linux also records that thread's voluntary/involuntary context
switches. macOS uses Mach cumulative thread CPU and reports reader switch counts
as unavailable. Both platforms separately report process CPU and process context
switches, which include producer sleeps and runtime coordination. Scheduling
counts are not exact counts of condition notifications.

The runner retains all command/test logs, raw observations, summaries, input and
binary hashes, compiler and host details, and completion status. Absolute deadlines
avoid accumulating pacing drift, and overslept ticks remain visible in each row.

## Scope and limitations

This measures the gate with one blocked EOF reader and no timestamped readers,
matching the subtitle demux EOF path. It does not measure whole-player CPU,
battery life, video decoding, rendering, or an end-to-end playback workload.

Mixed EOF/timestamped waiters still share notifications. The preexisting
broadcast before entering each wait can also wake other readers; this change
does not alter that separate multi-reader behavior. Reader CPU includes initial
registration and final retirement as well as wake-and-repark work.

## Results

The [confirmation Linux job](https://github.com/Jagalite/illiquid/actions/runs/40639383250/job/122653701946)
passed on `4b65a472b061d4fb48d846f95aa5c90af27c682c`, including all mandatory Git
metadata probes, a clean worktree, and source-integrity checks. The host was
Linux x86_64 with four allowed CPUs and Swift 6.3.2. All 12 tests passed for
baseline and candidate in both debug and release.

Median reader CPU time per three-second observation:

| EOF clock updates | Baseline | Candidate | Reduction | Reader voluntary switches, baseline → candidate |
| --- | ---: | ---: | ---: | ---: |
| 24 Hz | 2.043 ms | 0.044 ms | 97.84% | 72 → 1 |
| 60 Hz | 4.675 ms | 0.040 ms | 99.14% | 180 → 1 |
| 120 Hz | 8.344 ms | 0.042 ms | 99.49% | 360 → 1 |

The switch counts were identical across all six repetitions in each variant.
All 60 observations passed semantic checks; none overslept by a full update
interval. No sample was discarded.

The idle control stayed at one reader voluntary switch in both versions.
Its CPU medians were 0.0409 and 0.0405 ms, with overlapping ranges. The timed
120 Hz control stayed at 360 switches and still admitted the reader on the final
update. Its CPU median increased from 8.123 to 8.389 ms (+3.28%); baseline
7.018–8.820 ms and candidate 7.572–8.678 ms ranges overlap. This does not establish
zero timed-reader overhead or a statistically resolved timing regression.

The absolute EOF saving at 120 Hz is 8.30 ms of one reader's CPU over three
seconds. The large percentage describes unnecessary worker activity, not a
percentage improvement in total player CPU or battery life.

### Earlier run

The [initial Linux job](https://github.com/Jagalite/illiquid/actions/runs/40637896358/job/122649008784)
tested the same production gate, baseline, C instrumentation, harness and tests
at `0de1f18fe46c1a24e7e45aca0ef2f21fc48404a8`. Its 60 observations and all four
debug/release test runs also passed:

| EOF clock updates | Baseline reader CPU | Candidate reader CPU | Reduction |
| --- | ---: | ---: | ---: |
| 24 Hz | 1.643 ms | 0.041 ms | 97.50% |
| 60 Hz | 4.223 ms | 0.038 ms | 99.09% |
| 120 Hz | 8.429 ms | 0.037 ms | 99.56% |

Its switch counts matched the confirmation run exactly: 72/180/360 → 1 for EOF,
1 → 1 for idle, and 360 → 360 for the timed control. Idle CPU medians were
0.0410 → 0.0422 ms; timed CPU was 8.023 → 7.970 ms (−0.67%), both with overlapping
ranges. There were no full-interval oversleeps in either cohort.

### Evidence and provenance

`evidence/linux-initial` and `evidence/linux-confirmation` preserve all 120 raw
observations, summaries, source/binary hashes, command receipts, completion
records and the eight test logs. Full command logs are also available in each
workflow artifact.

The initial container's optional Git metadata probes failed because Git saw
different checkout ownership. Their error text and nonzero statuses remain in
the evidence. The checkout log independently identifies that tested commit;
`provenance.json` records this qualification. The runner now scopes Git trust to
this one explicit checkout for each probe and requires the probes to succeed.
The confirmation run passed every command and records its exact commit and a
clean working tree.

The initial workflow setup attempt failed before compilation because the Swift
container did not include Python. That dependency was installed before either
reported measurement cohort.

The macOS job was still queued when this report was written. No macOS CPU,
playback, or energy result is claimed. The source under test is unchanged by
this report and evidence-only commit.
