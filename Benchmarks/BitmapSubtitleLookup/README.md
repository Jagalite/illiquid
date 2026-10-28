# Independent bitmap subtitle pruning validation

This study independently validates the production change in
[PR #157](https://github.com/Jagalite/illiquid/pull/157). The follow-up PR adds
benchmark tooling and evidence only; the production implementation and regression
tests are inherited unchanged from that PR.

## Current candidate

`BitmapSubtitleTimeline.prune(before:)` must retain the final display set at
or before the cutoff. The candidate uses the first few timestamps to detect
zero or one removable entry without searching backward through future events.
Larger retirements retain the original reverse search. Array removal, byte
accounting, lookup, generation, revision, memory limits, leases and copy-on-write
behavior are preserved.

The adopted production commit is `79d9c9091b5eb4bb94b532fc9f7da9740778532d`.
Its timeline blob is `3871aa14a9443ba8b6eda67b31b4170d59b32645` and SHA-256 is
`e9664552e9b8d7dc5ea5200fec94a4fd7a2744be361df757688bfbeca01f0800`. Evidence below explicitly identifies which candidate
was measured; the earlier no-op-only results must not be attributed to this
combined zero/one-entry implementation.

## Experiment selection

An initial shared binary search for lookup and pruning passed all correctness
tests, but its small-window and near-tail controls regressed. At 128 entries,
first-event lookup improved from 69.30 to 32.41 ns, while penultimate lookup rose
from 11.76 to 31.68 ns. Latest-event lookup also regressed by roughly 1–2 ns.
The broader candidate was rejected. Timing, calibration, environment and test
records for that run are retained in
[evidence/exploratory-binary](evidence/exploratory-binary). Its candidate source
and driver are pinned by commit `6f9d096153d9085d7cc2b64ecd1ced145f3dda68`
and the recorded SHA-256 hashes.

A narrower no-op-only guard then improved full-window no-op pruning by about
94%, but one cohort's 128-entry rolling mutation control was 1.53% slower by
paired median. A longer fixed-affinity confirmation did not reproduce that
small slowdown; both cohorts remain visible below. The original observations
are in [evidence/portable](evidence/portable). A concurrent implementation in
PR #157 extends the guard to a single retirement, also eliminating the reverse
search on that mutation path. This study adopts that implementation for independent
qualification rather than proposing a duplicate production change.

## Production context

`SubtitlePipeline.renderedFrame` looks up bitmap events under its lock after its
same-millisecond/geometry cache check. `MediaSession.subtitleDemuxLoop` prunes
main and Picture in Picture pipelines before processing each selected subtitle
packet. Bitmap pruning has no extra five-second throttle. The default read-ahead
window is 30 seconds, and the pruning cutoff is 30 seconds behind playback.
Consequently a timeline may contain both recent history and future events.

The hard limits are 128 events and 32 MiB of pixel data per timeline. The benchmark
occupancies are synthetic coverage of that range; they are not measurements of
typical subtitle traffic. A 128-entry window is possible only while its payloads
also fit the byte limit.

## Reproduce

Requires macOS, Swift 6.1+ and Python 3.10+. No FFmpeg, libass, media fixtures or
application launch is needed. Follow the repository's Kyoto build coordination
when that queue is available. The isolated GitHub-hosted macOS runner has no
Kyoto project and compiles these components directly.

```sh
python3 Benchmarks/BitmapSubtitleLookup/run.py --tests-only \
  --output /tmp/illiquid-bitmap-lookup-tests
python3 Benchmarks/BitmapSubtitleLookup/run.py \
  --pairs 8 --target-ms 80 --max-sample-ms 1500 \
  --output /tmp/illiquid-bitmap-lookup-timing
```

Use an empty output directory per attempt and run one benchmark at a time.

The frozen baseline is the complete production timeline from commit
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`, including the earlier insertion
optimization. Its SHA-256 is verified before building. Both variants compile the
complete timeline and memory-budget sources and the exact `ASSRenderedRegion`
declaration extracted from `LibassContext.swift`. Geometry, `Data` and leases use
their real types. The optimized production module is compiled separately from
the benchmark driver, so its implementation cannot specialize to fixture values.

## Protocol and validation

Twenty-eight workloads cover first, middle, penultimate, latest and missing
lookups at 1/8/32/128 entries; repeated no-op pruning before or within the first
event; and rolling prune/insert/query streams at 2/8/32/128 entries. Static lookup
and prune cases perform 32 operations per iteration. Stream results are per
transition, including one prune, insertion and lookup. The receipt records those
operation counts explicitly. Timestamp spacing is 30 seconds divided by window
size, keeping a filled window within the default look-ahead span. The first
event starts at 60 seconds so missing-event and prune cutoffs remain positive.
Penultimate lookup deliberately selects an empty clear event. The stream's
operation ratio is synthetic and does not model rendering or packet cadence.

The same driver exercises both variants. Payload setup and complete result
verification occur outside timing. It consumes timed results in a checksum and
checks complete timeline receipts, including timestamp bit patterns, payloads,
generation, revision and retained bytes. Baseline and candidate receipts and
checksums must agree for every pair.

The runner defaults to eight fresh-process pairs alternating baseline/candidate
order. Each pair uses the same iteration count and fixture seed. Calibration
defaults to 80 ms on the faster variant, bounded by an estimated 1.5 seconds on
the slower variant. The independent combined-candidate workflow uses twelve
pairs, a 250 ms target, and one allowed CPU via taskset. Every actual timing
sample is retained. No control time is subtracted.

The output includes raw measurements, calibration records, test logs, source and
binary hashes, compiler commands, and host details. The workflow also uploads
the complete output as an artifact and emits the review files as exact JSON
strings in the job log for durable review capture.

The same ordering and memory-budget tests run against both sources in debug and
release with compiler warnings treated as errors. Added boundary tests cover
empty and 1/2/3/7/8/31/32/127/128-entry windows; every event's immediately preceding,
exact, and immediately following representable timestamps; NaN and infinities;
pruning from pristine value copies; finite, indefinite and clear events. Existing
tests cover independent randomized oracle comparisons, signed zero, out-of-order
delivery, replacement, capacity, stale generations and real lease lifetimes.

## Portable validation

The same component suite and benchmark can run on Linux with an explicit flag:

```sh
python3 Benchmarks/BitmapSubtitleLookup/run.py --portable --tests-only \
  --output /tmp/illiquid-bitmap-prune-portable-tests
python3 Benchmarks/BitmapSubtitleLookup/run.py --portable \
  --pairs 8 --target-ms 80 --max-sample-ms 1500 \
  --output /tmp/illiquid-bitmap-prune-portable-timing
```

Portable staging makes only the unavailable CoreGraphics imports conditional in
the complete timeline, extracted region support, and driver. Foundation supplies
the geometry types; the timeline and memory-budget algorithms are unchanged.
The manifest retains original and staged source hashes, the compiler and host,
and an explicit execution-scope label. The optimized production module remains
separate from the driver. Baseline and candidate receive identical adaptations.

Linux results validate this scalar pruning change on that platform. They do not
qualify macOS timing, application integration, renderer behavior, or memory use.
PR #157's native workflow provides the separate macOS qualification.

## Results and limits

### Combined candidate: existing PR #157 run, independently audited

The [successful upstream Linux job](https://github.com/Jagalite/illiquid/actions/runs/40637503390/job/122647747237)
measured the exact combined implementation at
`79d9c9091b5eb4bb94b532fc9f7da9740778532d`, against the pinned current-main
baseline, on x86_64 with Swift 6.4. These are existing PR #157 measurements
retrieved and independently audited, not a new independent execution.

| Upstream workload | Baseline median ns/op | Candidate median ns/op | Paired median reduction | Faster pairs |
| --- | ---: | ---: | ---: | ---: |
| No-op prune, 128 events | 55.685 | 3.425 | 93.85% | 8/8 |
| One-entry retirement + insert + lookup, 8 events | 134.360 | 131.064 | 1.85% | 8/8 |
| One-entry retirement + insert + lookup, 32 events | 171.879 | 157.075 | 8.60% | 8/8 |
| One-entry retirement + insert + lookup, 128 events | 397.086 | 329.812 | 17.22% | 8/8 |
| Centered one-entry stream, 128 events | 352.124 | 292.160 | 17.19% | 8/8 |

All 24 test declarations in two suites passed against baseline and candidate
in both debug and release with warnings treated as errors. The audit reproduced
the summaries for all 464 observations across 29 cases and eight pairs, checked
balanced order, exact UInt64 checksums and complete-state receipt hashes, matched
original and staged sources to the adopted production code, and checked all
600 recorded command exit statuses.

[Durable upstream evidence](evidence/bounded-upstream) includes raw measurements,
calibration, original manifests, staged component sources, test logs, commands
and provenance. This cohort uses the existing `BitmapSubtitleTimeline` driver
and its fixtures. Do not pool its absolute times with the separate
`BitmapSubtitleLookup` cohorts: the drivers, workloads, compiler versions and
hosted runner instances differ. Percentages are medians of within-pair ratios,
not ratios of the displayed medians.

### Combined candidate: independent longer run

[Run 40640508556](https://github.com/Jagalite/illiquid/actions/runs/40640508556)
is executing the exact same production bytes with the independent 28-case
driver at `a2e39e141a073688e058f354a15093d2dd98ae31`. It uses twelve balanced
pairs, a 250 ms target and fixed CPU affinity. Its completed results will be
recorded separately; no performance claim above depends on that pending run.

### Exploratory Linux run: no-op-only guard

[Run 40638864454](https://github.com/Jagalite/illiquid/actions/runs/40638864454)
passed on Ubuntu 24.04 / x86_64 with Swift 6.4.1. The measured commit is
`df13d4df368d0e59a861d000e80a177a0e36bcad`; this cohort measured the no-op-only guard, not the combined production
implementation now inherited from PR #157. The later merge deliberately changes
the production candidate and ordering tests, while preserving this cohort.

| No-op pruning workload | Baseline median ns/call | Candidate median ns/call | Paired median reduction | Faster pairs |
| --- | ---: | ---: | ---: | ---: |
| prune-first-1 | 2.075 | 1.796 | 14.04% | 7/8 |
| prune-first-8 | 3.575 | 1.803 | 48.84% | 8/8 |
| prune-first-32 | 9.366 | 1.776 | 80.61% | 8/8 |
| prune-first-128 | 31.915 | 1.792 | 94.43% | 8/8 |
| prune-missing-32 | 8.812 | 1.764 | 79.97% | 8/8 |
| prune-missing-128 | 32.591 | 1.827 | 94.42% | 8/8 |

The 8-, 32-, and 128-entry no-op paths improved in every pair. At 128 entries
the saving is about 30 ns per call. The singleton saving is much smaller and
one of its eight pairs was slower.

| Mutation control (prune + insert + lookup) | Baseline median ns/step | Candidate median ns/step | Paired median time change |
| --- | ---: | ---: | ---: |
| stream-2 | 80.179 | 80.590 | +0.05% |
| stream-8 | 84.275 | 84.245 | -0.03% |
| stream-32 | 110.752 | 110.321 | -0.46% |
| stream-128 | 225.305 | 228.510 | +1.53% |

Positive mutation-control changes mean more time. Percentages are medians of
within-pair ratios, so they need not equal ratios of the displayed medians.
The 128-entry stream was about 3.2 ns slower by the difference of medians and
1.53% slower by paired median; six of eight pairs were slower. A large outlier
is retained, and does not by itself explain the median. The longer confirmation below did not reproduce this small slowdown.
The initial observation is retained rather than being discarded or explained
away by the outlier; it is not established as a reproducible regression.
Lookup implementation is unchanged; its small before/after movements are
controls, not improvements attributed to this patch.

All 23 tests in two suites passed against baseline and candidate in both debug
and release, with warnings treated as errors. All 448 observations across
28 cases and eight pairs matched full receipt hashes and exact integer
checksums. An independent recomputation checked all reported medians, balanced
AB/BA order, successful command receipts, and production/test/runner hashes.

Durable records: [manifests, tests, commands, calibration, raw observations and
summary](evidence/portable). The workflow artifact also retains full per-case
receipts for its configured retention period.

### Exploratory no-op-only guard: longer confirmation

[Run 40639637094](https://github.com/Jagalite/illiquid/actions/runs/40639637094)
completed successfully at `f90d8206300e015202e09fb5a98becaf53fee4d6`.
It measured the old no-op-only candidate, not PR #157's combined fast path.
Twelve balanced pairs used a 250 ms target and one allowed CPU on an AMD EPYC
7763 hosted runner, with Swift 6.4.1. All 144 observations across six cases
matched exact integer checksums and full receipt hashes.

| Exploratory confirmation | Baseline median ns/op | Candidate median ns/op | Paired median reduction | Faster pairs |
| --- | ---: | ---: | ---: | ---: |
| lookup-latest-128 | 17.023 | 16.908 | 1.00% | 8/12 |
| prune-first-128 | 55.430 | 3.769 | 93.20% | 12/12 |
| stream-2 | 124.313 | 123.600 | 0.78% | 6/12 |
| stream-8 | 140.019 | 140.301 | 0.14% | 7/12 |
| stream-32 | 176.613 | 174.292 | 0.93% | 10/12 |
| stream-128 | 393.983 | 391.334 | 0.61% | 12/12 |

The large no-op improvement reproduced. The initial small stream-128 slowdown
did not: this cohort was 0.61% faster by paired median. Small lookup movements
are unchanged-code controls. These data do not establish a repeatable mutation
penalty or benefit for the old guard. Both cohorts are retained, with no pooled
statistics and no discarded observations. The confirmation did not rerun the
regression tests already completed for those exact inputs.

[Durable confirmation evidence](evidence/exploratory-noop-confirmation) includes
CPU/affinity details, source hashes, raw measurements, calibration, commands,
summary and audit provenance.

### Native qualification and scope

[PR #157's qualification run](https://github.com/Jagalite/illiquid/actions/runs/40637503390)
has a successful Linux component job; its native macOS job was still queued
when this report was prepared. macOS timing and full-player integration are
not established by the portable runs.

These are warm component measurements. They do not measure real no-op frequency,
lock contention, decoding, GPU rendering, frame rate, whole-player CPU, memory
footprint, or energy. Without real call-frequency data, the no-op saving and
mutation-path cost cannot be converted into an aggregate playback speedup.
All timed rolling mutations retire exactly one entry. Bulk-retirement latency
was not measured, though its correctness is exercised by the regression suite.
Successful pruning still shifts the retained array and releases removed owners.
