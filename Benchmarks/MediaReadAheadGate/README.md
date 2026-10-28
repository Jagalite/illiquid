# Media read-ahead wakeup qualification

This study requalifies the unmerged read-ahead experiment from
[`2bea445`](https://github.com/Jagalite/illiquid/commit/2bea445f23e65f238ca46539fa2b63169f1ffebb)
against current main
[`ea2ff56`](https://github.com/Jagalite/illiquid/commit/ea2ff568237e2667f7b1aeee67b11a44ebe95b72).
The frozen baseline is byte-for-byte identical to the gate at that main commit
(Git blob `10374be342abef4546031d6edd988566b31a62b0`). The runtime change,
regression suite, condition wrapper, and threaded driver are reused from that
earlier experiment. This branch updates provenance, requires complete test
receipts, and repeats validation with the current app graph.

[RESULTS.md](RESULTS.md) records the successful fresh Linux qualification,
all paired measurements and controls, and separately labeled historical native
evidence. Current macOS component and app integration checks remain pending;
the earlier native run is not a current-head integration result.

## Reproduce

Swift 6.1 or newer and Python 3.10 or newer are required. The component package
runs on Linux and macOS without FFmpeg, libass, or the full app dependency graph.

```sh
python3 Benchmarks/MediaReadAheadGate/run.py all --pairs 6 \
  --updates 240 --interval-us 8333 --output /tmp/read-ahead-120hz
python3 Benchmarks/MediaReadAheadGate/run.py benchmark --pairs 6 \
  --updates 120 --interval-us 16667 --output /tmp/read-ahead-60hz
python3 Benchmarks/MediaReadAheadGate/run.py benchmark --pairs 6 \
  --updates 60 --interval-us 33333 --output /tmp/read-ahead-30hz
```

Output directories must not already exist. Use the shared Kyoto queue for builds
when available, as described in `AGENTS.md`. The isolated hosted runners do not
have that queue and compile serially.

## Workloads

- `eof`: one reader waits for seek or close while the controller advances time.
- `future`: one reader waits for a cue beyond the configured read-ahead window.
- `active`: every update admits the next timestamp. This is the control for
  notifications that must still occur.
- `idle`: the same paced updates without a reader.
- `multi-eof`: four blocked readers, used only as an instrumented adversarial
  control for self-generated notifications. Production currently has one
  subtitle reader per gate.

Each standard workload supplies approximately two seconds of updates. The
cadences are synthetic input traces; actual coalesced playback observation
frequency is not measured. The position advances by 1/120 second per update in
every trace, so the 30/60 Hz runs vary notification pacing without changing
admission arithmetic. The four-reader control uses at most 24 updates.

Six uninstrumented fresh-process pairs alternate baseline/candidate order and
scenario order. Every raw sample is retained. There is no scheduler-sensitive
timing pass threshold, control subtraction, or discarded sample.

## Separate counting and timing builds

Both builds compile the actual production gate source unchanged. The baseline's
SHA-256 is checked before compilation.

The counting build includes `CountingCondition.swift`, which shadows the
unqualified `NSCondition` name with a forwarding wrapper around one real
Foundation condition. Counters are accessed under that condition's existing
lock. The wrapper introduces no signals, waits, or extra locks in the gate.
Its CPU measurements are not used for performance claims.

The timing build omits that wrapper and uses Foundation's `NSCondition`
directly. It measures process CPU, voluntary/involuntary context switches, and
wall time around paced updates. Setup, counter reads, close, and joins are
outside the interval. CPU includes controller pacing and update work. Counter
deltas end at the end of the update loop; the last signaled reader may still be
runnable, so wait-return counts are observations, not a guaranteed notification
delivery count.

The counting executable's `--check` adds actual condition-wait barriers: four
diagnostic observers must already be waiting before a reader arrives; mixed
finite/EOF readers must be blocked before each threshold crossing; and a reset
immediately followed by an update is repeated 32 times. Semantic receipts must
match. The candidate must generate no broadcasts in EOF, far-future, no-reader,
and multiple-EOF update intervals, or during a mixed-reader hold without updates.

Both variants also run the same 15-test regression suite in debug and release.
The runner requires a nonempty completion receipt with the full expected count.
Tests cover rounded and overflowed lookahead boundaries, mixed readers, stale
generations, observer registration, consecutive updates, same-generation reset,
close, and reset/update races.

## App integration and scope

The workflow also builds the current release app/test graph with the pinned
native SDK and runs the gate suite plus the two existing gate regression tests.
This is separate from component measurements and must have its own passing
receipt.

Only the subtitle gate receives playback-position updates. Audio and demux EOF
gates share the class but do not receive these periodic updates. Normal packets
that become eligible on each update must continue waking. The current reader
predicate, lookahead arithmetic, generation checks, and reset/close behavior
remain unchanged.

These measurements do not establish whole-player CPU, battery, frame-rate,
subtitle-rendering, or physical-device power improvements. Live playback and
UI qualification are outside this component study.
