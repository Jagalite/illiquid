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

Hosted results will be recorded here after qualification completes.
