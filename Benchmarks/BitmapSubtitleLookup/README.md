# Bitmap subtitle hybrid lookup research

## Status

Qualification is in progress. This branch does not yet establish a performance
improvement. The native macOS and explicit portable Linux runs are separate
experiments, and their results must be reported separately.

- Native experiment: [run 40639454368](https://github.com/Jagalite/illiquid/actions/runs/40639454368)
  at commit `1e0979032bba0857d15d79391249e1ccbbd639bf`.
- Portable experiment: [run 40641025640](https://github.com/Jagalite/illiquid/actions/runs/40641025640)
  at commit `82e9576eeae9a41cfeda959e78aae7f77484c8da`.
- [Initial portable setup attempt](https://github.com/Jagalite/illiquid/actions/runs/40640400590)
  failed before compilation because Git rejected the container checkout's
  ownership. The workflow now trusts only its exact `GITHUB_WORKSPACE` path.
  That attempt produced no test or performance results.

## Question

Bitmap subtitles retain display sets in timestamp order. Rendering selects the
latest start at or before the requested time, then checks its duration. The
current implementation scans backward through all later buffered events.

A plain binary-search experiment previously recorded regressions for short
windows and near-tail queries:
[existing experiment](https://github.com/Jagalite/illiquid/commit/06df96d43c6c5b6219aecd0ee9ad132e514b0a4b).
This candidate tests a different lookup policy:

- Preserve the reverse lookup for at most eight entries.
- For larger windows, inspect the last four timestamps first.
- If those four events are all in the future, find the predecessor by an
  upper-bound binary search in the earlier prefix.
- Apply the original duration check to the selected event. An expired event
  cannot resurrect an older subtitle; an explicit empty display remains a clear.

The four-entry suffix and eight-entry small-window boundary are experimental
choices. In particular, a query with four future entries pays for both searches.
The benchmark includes that crossover rather than assuming it is harmless.

The production patch changes only `BitmapSubtitleTimeline.composition(at:)`.
The runner rejects other changes to the timeline against baseline
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`.

## Reproduce

Build through the shared Kyoto queue when it is available, as required by the
repository's AGENTS.md. The hosted jobs explain its absence before direct,
serialized builds in their isolated checkouts.

Native macOS, Swift 6.1 or newer:

```sh
python3 Benchmarks/BitmapSubtitleLookup/run.py \
  --pairs 8 --target-ms 240 --output /tmp/bitmap-subtitle-lookup
```

Explicit portable Linux mode, using the real Swift Foundation geometry types:

```sh
python3 Benchmarks/BitmapSubtitleLookup/run.py \
  --portable-linux --pairs 8 --target-ms 240 \
  --output /tmp/bitmap-subtitle-lookup-portable
```

Use a new output directory for each attempt. `--tests-only` runs the four
baseline/candidate test configurations and complete-output comparisons without
timing. The GitHub portable job uses the official `swift:6.3.2-noble` image.

## Correctness and source fidelity

Both variants compile the complete production timeline and memory budget, plus
the exact `ASSRenderedRegion` declaration from `LibassContext.swift`. Native
mode uses CoreGraphics directly. Portable mode removes only exact unconditional
CoreGraphics import lines from compile copies; it uses Foundation's actual
geometry types and provides no replacement structs or APIs. Receipts record
original and compiled hashes, removed line numbers, and platform mode.

The existing timeline-ordering and budget-accounting suites, plus the new
lookup suite, run on baseline and candidate in both debug and release.
Coverage includes exact and adjacent timestamp boundaries, nonfinite queries,
both signed-zero replacement orders, finite expiry, empty clears, replacements,
out-of-order insertion, independent copies, pruning, reset, lease identity, and
extreme finite arithmetic.

A separate forward-selection specification checks complete lookup snapshots,
including every pixel byte and all composition fields. Full traces must agree
between implementations before any timing begins.

## Measurement

There are 60 workloads. Occupancies 0, 1, 2, 5, 8, 9, 32, and 128 cover before-first,
near-first, middle, penultimate, newest, and after-newest queries. Larger windows
also cover three, four, and five future events. Three frozen synthetic windows
place the query between roughly 30 seconds of history and 30 seconds of lookahead.
These are representative positions to test, not measured user-traffic frequencies.

Each workload rotates sixteen distinct finite query times through the same
preconstructed timeline. Fixture construction, verification, insertion, pruning,
JSON encoding, and serialization are outside timing. Every invocation performs
4,096 warmup lookups.

The optimized production library and driver are compiled separately. Each
observation runs in a fresh process; eight pairs alternate baseline/candidate
and candidate/baseline order. Each variant is calibrated independently to at
least 240 ms of both process CPU and monotonic wall time. Every final observation
must exceed 60 ms on both clocks. A short sample fails qualification and remains
in the evidence; no sample is silently removed.

The emitted checksum consumes returned timestamps, duration, geometry, region
metadata, pixel endpoints, and lease presence. Reported times therefore include
lookup, result consumption, call/ARC, and loop overhead. They are not isolated
timestamp-comparison latency. Compare variants within each workload, since
different query positions can return different amounts of subtitle data.

## Evidence and acceptance

The output retains source/compiler/library/binary identities, exact compiled
copies, complete regression logs and semantic traces, calibration, all raw
observations, paired summaries, command receipts, and explicit completion or
failure status. The workflow uploads these artifacts even on failure.

Acceptance requires correct complete output and useful measured improvement
without material regressions in the small-window, tail, or crossover controls.
Large before-first or middle-window percentages alone are insufficient.

The timeline is bounded to 128 entries by default. Absolute nanoseconds matter.
Neither a Linux component result nor a successful synthetic native run establishes
whole-player CPU, visible responsiveness, frame rate, subtitle latency, energy,
or memory savings. Actual occupancy and delivered lookup rates remain unmeasured.
