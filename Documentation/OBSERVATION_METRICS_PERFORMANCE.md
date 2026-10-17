# Runtime observation accounting performance

## Result and qualification status

The selected target is the native runtime's observation metrics ledger. Its
per-source counts change on every audio, video, clock, and related observation.
This investigation starts from integrated `main` at
`68274d1b09dcc866296321a5a8858efc297c4f19` and does not reuse earlier PR gains.

Linux qualification found 78–90% lower component time across request workloads.
Native macOS qualification is pending the PR checks. No whole-player performance
measurement has been made.

## Cause and change

`RuntimeObservationMetricsSnapshot` previously stored a dictionary with seven
possible keys. `RuntimeObservationMetricsLedger.recordRequest` increments one
key for every observation. `RuntimeObservationCoalescer.snapshot()` returns a
value that `NativePlaybackRuntime` retains in `lastObservationMetrics`. On the
next mutation, the dictionary must preserve that older snapshot, including its
previous per-source values.

`RuntimeObservationSourceCounts` now stores the seven optional integer counters
inline. Exhaustive switches select a source. The representation preserves
absent keys, explicit zero, optional/default lookup, lazy default evaluation,
inout updates, equality, and independent value copies. The aggregate total uses
the same counters without constructing a temporary collection.

The ledger's request/delivery calculations and the entire coalescer are
unchanged. The patch changes no cadence, observation suppression, callback
ordering, synchronization, decode, presentation, or diagnostics values.

## Method

The [runner and harness](../Benchmarks/ObservationMetrics/README.md) compile the
actual complete observation region twice, once from the pinned baseline and
once from the candidate, using `-O -whole-module-optimization -swift-version 6`.
Each benchmark pair uses identical deterministic requests and checksums, with
alternating process order. The baseline's previous publication stays alive
across the next mutation. Both shared and unshared storage cases are measured.

The timed unit is one observation request, including amortized delivery and
publication work. Separate cases measure snapshot reads and an unchanged loop
control. Independent semantic checking and fixture generation are untimed.
The fixture is not an observed distribution of events from a playback trace.

### Linux qualification

Host: AMD EPYC 9V74, x86_64 Linux, Swift 6.3.2. Six paired rounds, **4,000,000
operations per process**, 84 raw observations. Medians, with no control subtraction:

| Workload | Baseline ns/op | Candidate ns/op | Reduction |
| --- | ---: | ---: | ---: |
| One request per publication | 136.11 | 29.73 | 78.2% |
| Four requests per publication | 64.38 | 8.06 | 87.5% |
| Sixteen requests per publication | 47.29 | 4.93 | 89.6% |
| Sixteen requests without retained publication | 37.72 | 4.73 | 87.5% |
| Four requests, 64 retained snapshots | 76.62 | 13.47 | 82.4% |
| Snapshot lookup control | 28.49 | 1.80 | 93.7% |
| Unchanged loop control | 1.42 | 1.68 | -18.4% |

All six pairs improve in each request workload. The unchanged loop control is
noise-sensitive and receives no performance interpretation. Raw timing ranges,
paired reductions, source hashes, compiler commands, and test logs are
[retained with this report](PerformanceEvidence/ObservationMetrics/linux).

Both variants pass all five metrics tests in debug and release. The cloud Linux
host intermittently traps inside libdispatch while inspecting `/proc` thread
state in the pre-existing asynchronous coalescer tests; this reproduced on the
unchanged baseline. Final Linux runs explicitly use `--ledger-only-tests`.
Asynchronous coalescer qualification remains a native macOS gate, with no runtime
shims or altered concurrency tests.

### Native macOS qualification

Pending the PR's native component and app integration jobs.

## Correctness

The regression suite compares the production implementation with a real
dictionary and an independent event-journal oracle. It checks all source counts,
presence, scheduled/coalesced/delivered/follow-up values, both delay maxima, and
retained snapshots. It covers 10,000 mixed events and explicit unsigned time
wrap cases.

The first candidate's direct defaulted setter did not evaluate the default when
assigning to a missing key. Dictionary does evaluate it in that case. The oracle
test caught the difference; a `get`/`_modify` accessor now preserves that behavior,
including writeback after a throwing inout operation.

Native qualification also includes the existing concurrent coalescer tests,
presentation-time observation tests, and diagnostics message formatting.

## Limits and tradeoffs

This saves tens of nanoseconds in a bookkeeping component. The relative speedup
does not establish an appreciable change in total playback CPU or battery use.
The experiment does not count allocator calls or attribute full-app CPU samples.

The measured inline snapshot size/stride grows from **56 to 160 bytes**; the
ledger grows from **81/88 to 185/192 bytes** (size/stride). The fixed representation
removes the counter dictionary's shared heap storage, but total retained memory
was not measured. The 64-snapshot workload explicitly includes larger inline
storage copies. Snapshot lookup timings alone do not establish copy cost.

Adding a new observation source requires updating the exhaustive switches and
total, with the all-cases oracle providing coverage. Overflow policy is unchanged:
the integer counters and their total still use checked `Int` arithmetic.
