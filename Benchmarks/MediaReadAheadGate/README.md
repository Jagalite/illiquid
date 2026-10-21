# Media read-ahead wakeup qualification

This experiment compares the actual `MediaReadAheadGate.swift` with its pinned
baseline from `a2de305c8dbcaa81aac1477df7c9a0017c14eae3`. The baseline's SHA-256
is checked before either implementation runs. Both implementations use the same
regression tests and benchmark driver.

```sh
python3 Benchmarks/MediaReadAheadGate/run.py all --output /tmp/read-ahead-results
```

Swift 6.1 or newer and Python 3 are required. The Foundation-only package runs on
Linux and macOS without FFmpeg, libass, or the complete app dependency graph.
The PR's existing native release workflow provides app integration coverage.

## What is measured

- `eof`: one reader waits for seek or close while the controller advances time.
- `future`: one reader waits for a cue beyond the configured read-ahead window.
- `active`: each advancing update admits its corresponding timestamp. This is
  the control for work that legitimately needs to resume.
- `idle`: updates with no reader; the controller/pacing overhead remains.
- `multi-eof`: four blocked readers, used only as an instrumented adversarial
  control for self-generated wakeups. Production currently has one subtitle
  reader per gate.

The default trace supplies 240 advancing positions over approximately two
seconds, paced at 120 updates per second. That is a synthetic observation trace,
not a claim that every playback session generates observations at that rate.
The four-reader control supplies 24 updates. Six uninstrumented pairs alternate
baseline/candidate order and scenario order. The script writes every raw row,
source/toolchain hashes, command receipts, exact behavioral receipts, and medians.
Timing is informational; there is no scheduler-sensitive timing pass threshold.

## Separate counting and timing builds

The counting build compiles `CountingCondition.swift`. This shadows the
unqualified `NSCondition` type with a forwarding wrapper around one real
Foundation condition. It counts broadcasts and wait returns while holding the
condition's existing lock. It adds no signals or waits. The production gate
source is copied unchanged. Its CPU results are not used for performance claims.

The timing build omits that wrapper and uses Foundation's `NSCondition` directly.
It measures process CPU, voluntary/involuntary context switches, and wall time
around paced position updates. Setup, instrumentation, close, and joins are
outside that interval. Process CPU includes the controller's sleep/update work;
small absolute differences and the `idle` control should be read accordingly.

`--check` on the counting executable adds deterministic registration barriers:
four diagnostic observers must actually be in timed condition waits before a
reader arrives; mixed finite/EOF readers must all be blocked before each update;
and a reset immediately followed by a threshold crossing is repeated 32 times.
The baseline and candidate must produce identical semantic receipts. Candidate
traces also require zero broadcasts when no reader can advance, and zero
self-generated broadcasts during a no-update mixed-reader hold.

## Scope

The runtime updates subtitle read-ahead after coalesced playback observations.
The gate is useful at EOF and across sparse future input; normal multiplexed
input often becomes eligible on each update and must continue waking. Audio and
demux EOF gates use the same class but do not receive periodic position updates.
This experiment does not measure complete-player CPU, battery, frame rate,
subtitle rendering quality, or physical-device power use.
