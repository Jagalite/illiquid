# Source-browser search match storage

This study compares compact matching-index storage with main
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`. It measures complete searches and
cached source-browser projections from already-loaded rows.

## Decision

The index/subscript experiment was rejected for native timing regressions.
The revised enumerated experiment retains a clear Linux allocation benefit,
with faster broad searches and slower cached sparse/no-match projections.
Its native macOS job is still queued, so native acceptance and a PR decision
remain pending. No native speedup is claimed for the revision.

## Why this area

A nonblank query first collects matching rows, then unions their identities and
explicit ancestor identities, then filters the input in its original order.
The input array remains alive throughout. Copying complete row values into the
temporary match array is unnecessary for the ID-union step.

The compiled `SourceTreeDisplayRow` stride is 320 bytes on both tested
platforms; an `Int` index occupies 8 bytes. Compact indices therefore use 97.5%
less element storage in that temporary array. At 100,000 matches the logical
element payload is 32,000,000 bytes versus 800,000 bytes, before capacity
rounding and allocator overhead. These are layout calculations, not measured
RSS or peak memory.

Rows contain value metadata and references to strings/arrays. The old temporary
buffer copies row values and retains referenced storage; it does not deep-copy
every string or nested array.

## Candidate history

The first candidate, `85b684d8557cf9997f93f933401310059f72041b`, collected
indices with `rows.indices.filter` and read `rows[index]` inside the predicate.
It reduced Linux allocation-requested bytes, but did not pass the native timing
check. The 100,000-row, two-level no-match search was slower in 11 of 12 pairs
across two native cohorts. Its median paired wall-time reductions were
-4.15% and -15.33%. Broad nested search was mixed (+3.96%, then -11.63%).

No-match search constructs no nonempty matching buffer and never enters the
ID-union loop. Its regression therefore cannot be explained by reduced match
storage. Traversal/code generation and host variability are possible causes;
this study does not establish a compiler-level cause.

The revised candidate, `07263b2793a7ba941d61cc6f9fa7880badb587bd`, uses eager
`rows.enumerated().compactMap`. It supplies each row directly to the predicate
and keeps the same `[Int]` output. The original predicate, short-circuit order,
set reservation, ancestor union, and final input-order filter are retained.

## Revised Linux results

For 100,000 media rows with two ancestor levels, direct search requested
**44.39% fewer bytes** and complete cached projection requested **31.48% fewer
bytes**. These are bytes requested by intercepted allocations, not allocation
counts. Primary direct-search request counts are almost unchanged:
306,040 versus 306,039.

Direct search measured a **10.51% median paired wall-time reduction** and cached
projection **6.83%**, each favorable in all six pairs with corresponding CPU
improvements. Cached sparse and no-match projection instead measured **2.48%**
and **1.73% more time**, unfavorable in all six pairs. Direct sparse/no-match
search is approximately unchanged. This is a workload-specific tradeoff.

The percentages below are medians of within-pair reductions, not reductions
computed from the two separately reported medians. Positive means less time or
fewer bytes; negative means more. Blank-path timings are controls, not gains.

| Case | Before median ms | After median ms | Paired wall reduction | Favorable pairs |
| --- | ---: | ---: | ---: | ---: |
| `search/1000/2/broad` | 1.926 | 1.923 | 0.06% | 3/6 |
| `search/10000/0/broad` | 18.615 | 18.108 | 2.53% | 6/6 |
| `search/10000/2/broad` | 20.265 | 19.863 | 2.10% | 6/6 |
| `search/100000/0/broad` | 280.304 | 250.281 | 10.57% | 6/6 |
| `search/100000/2/broad` | 304.180 | 271.078 | 10.51% | 6/6 |
| `search/100000/8/broad` | 357.164 | 329.380 | 8.71% | 6/6 |
| `search/100000/0/sparse` | 176.698 | 177.304 | -0.84% | 1/6 |
| `search/100000/2/sparse` | 191.570 | 191.189 | 0.22% | 3/6 |
| `search/100000/0/none` | 163.883 | 164.401 | -0.57% | 2/6 |
| `search/100000/2/none` | 170.454 | 168.899 | 0.20% | 4/6 |
| `search/100000/2/blank` | 0.000352 | 0.000360 | -1.23% | 1/6 |
| `search/10000/2/metadata` | 38.589 | 38.654 | -0.25% | 2/6 |
| `search/10000/2/unicode` | 23.022 | 22.766 | 1.24% | 6/6 |
| `project/100000/0/broad` | 412.030 | 382.219 | 6.25% | 6/6 |
| `project/100000/2/broad` | 445.645 | 415.410 | 6.83% | 6/6 |
| `project/100000/2/sparse` | 189.567 | 192.942 | -2.48% | 0/6 |
| `project/100000/2/none` | 168.882 | 171.802 | -1.73% | 0/6 |
| `project/100000/2/blank` | 0.007 | 0.007 | 0.64% | 3/6 |

Allocation measurements are a separate cohort:

| Case | Before requested bytes | After requested bytes | Paired byte reduction |
| --- | ---: | ---: | ---: |
| `search/1000/2/broad` | 1,466,439 | 827,583 | 43.57% |
| `search/10000/2/broad` | 22,460,263 | 12,236,703 | 45.52% |
| `search/100000/2/broad` | 184,239,975 | 102,451,055 | 44.39% |
| `search/100000/2/sparse` | 15,616,295 | 14,977,439 | 4.09% |
| `search/100000/2/none` | 12,240,252 | 12,240,252 | 0.00% |
| `search/10000/2/metadata` | 24,300,263 | 14,076,703 | 42.07% |
| `project/100000/2/broad` | 259,801,270 | 178,012,350 | 31.48% |
| `project/100000/2/sparse` | 16,386,646 | 15,747,790 | 3.90% |
| `project/100000/2/none` | 12,240,504 | 12,240,504 | 0.00% |

## Superseded native results

The full native timing record for the rejected index/subscript traversal is
shown here to retain the negative and mixed outcomes. Values are median paired
wall-time reductions; positive is favorable. These are **not results for the
enumerated revision**.

| Case | First native cohort | Repeat native cohort | Favorable pairs, total |
| --- | ---: | ---: | ---: |
| `search/1000/2/broad` | 0.48% | -2.23% | 5/12 |
| `search/10000/0/broad` | 9.53% | 0.78% | 7/12 |
| `search/10000/2/broad` | 1.94% | -3.92% | 4/12 |
| `search/100000/0/broad` | 1.20% | -1.97% | 6/12 |
| `search/100000/2/broad` | 3.96% | -11.63% | 5/12 |
| `search/100000/8/broad` | -0.20% | 2.28% | 6/12 |
| `search/100000/0/sparse` | -3.12% | -2.00% | 4/12 |
| `search/100000/2/sparse` | -0.70% | -5.58% | 5/12 |
| `search/100000/0/none` | 2.28% | -6.67% | 6/12 |
| `search/100000/2/none` | -4.15% | -15.33% | 1/12 |
| `search/100000/2/blank` | 3.85% | 4.21% | 8/12 |
| `search/10000/2/metadata` | 0.75% | 3.07% | 7/12 |
| `search/10000/2/unicode` | 0.87% | -0.25% | 7/12 |
| `project/100000/0/broad` | 1.08% | 7.81% | 9/12 |
| `project/100000/2/broad` | -3.29% | 4.48% | 7/12 |
| `project/100000/2/sparse` | 3.49% | -1.57% | 6/12 |
| `project/100000/2/none` | 1.82% | -1.60% | 6/12 |
| `project/100000/2/blank` | -2.86% | 7.70% | 5/12 |

## Revised native result

Pending GitHub's macOS runner for [run 40733770640](https://github.com/Jagalite/illiquid/actions/runs/40733770640).


## Correctness

The immutable, concrete zero-based Array keeps all enumeration offsets valid.
Every matching occurrence contributes its own ID and ancestors, even when IDs
are duplicated. The final filter preserves duplicate rows and original order.
Matching-folder behavior, metadata gating, Unicode/locale matching, excluded
kinds, the blank-query fast path, and cancellation points remain unchanged.

Both original implementations passed all nine existing test functions in debug
and release on Linux and macOS, including the independent native repeat.
The enumerated revision passed the same four baseline/candidate × debug/release
combinations on Linux. Its native checks are pending along with the queued job.

The existing nine-test suite covers duplicate IDs with distinct ancestors,
message and section ancestors, matching folders without descendant expansion,
metadata fields, Unicode, 32 seeded scenarios, visibility/cache/media-view
integration, and deterministic cancellation before search. No new behavior
tests that merely mirror the storage implementation were added.

## Protocol

The component harness compiles the complete production Filter and
ProjectionInput files plus exact portable declarations from AppModel and
SourcesSidebar. Shared support is identical for both compared builds. The
runner rejects a comparison if compiled sources differ anywhere other than
`SourceBrowserFilter.swift`, or if the harness, oracle, or package manifest
hashes differ.

Each uninstrumented timing cohort contains 18 workloads, six alternating AB/BA
pairs per workload, and 216 fresh-process observations. Each process warms up
once and runs adaptive iterations targeting 120 ms. Fixture construction,
baseline oracle, full result equality, and stable fingerprints are outside the
timed region. Wall time and process CPU time are both recorded. Linux is pinned
to one allowed CPU. Cases cover 1,000–100,000 media rows, ancestor depths 0/2/8,
broad/sparse/absent/blank queries, Unicode and metadata matching, and cached
actor projection.

Each Linux allocation cohort is separate from timing, with two balanced pairs
per workload and 72 observations. The glibc interceptor counts successful
malloc/calloc/realloc requests and requested bytes during the complete
operation. Requested bytes include temporary growth and are not live memory or
RSS. Instrumented timing is excluded from speed claims.

Every measurement checks exact rows against the pinned production baseline.
Projection checks also cover thumbnail candidates, media paths, counts, and
visibility-cache reuse. Receipts retain source, harness, compiler, binary and
oracle hashes. Both implementations use the same supporting declarations.

The initial native timing was noisy, so the native job was repeated with
identical sources. Both native cohorts are retained. The rerun API also exposes
the inherited Linux job under a new job ID, but its timestamps and data hashes
are identical; it is counted only once.

### Recorded environments

| Cohort | Host | Compiler |
| --- | --- | --- |
| Initial Linux timing/allocation | Intel Xeon Platinum 8573C, Linux 6.17/glibc 2.39 | Swift 6.4 |
| Both initial native cohorts | Apple M1 (Virtual), macOS 26.6.2 | Apple Swift 6.3.3 |
| Enumerated Linux timing/allocation | AMD EPYC 7763, Linux 7.0/glibc 2.39 | Swift 6.4.1 |

Baseline and candidate use the same host/toolchain within each cohort. The two
Linux experiments use different hosts and compilers; their absolute timings
must not be compared to establish traversal causality.

## Reproduction

Use the shared Kyoto queue when available, as required by AGENTS.md. The CI
workflow verifies its absence before serial builds in isolated temporary
packages. These component packages require no FFmpeg or SwiftUI runtime.

```sh
python3 Scripts/test-source-browser-search.py \
  --configuration release \
  --baseline-ref ea2ff568237e2667f7b1aeee67b11a44ebe95b72 \
  --output /tmp/search-storage-baseline-tests

python3 Scripts/test-source-browser-search.py \
  --configuration release \
  --output /tmp/search-storage-candidate-tests

python3 Benchmarks/SourceBrowserSearch/run.py \
  --baseline-ref ea2ff568237e2667f7b1aeee67b11a44ebe95b72 \
  --pairs 6 --target-ms 120 \
  --output /tmp/search-storage-timing

# Separate Linux/glibc allocation cohort.
python3 Benchmarks/SourceBrowserSearch/run.py \
  --baseline-ref ea2ff568237e2667f7b1aeee67b11a44ebe95b72 \
  --allocations --pairs 2 \
  --output /tmp/search-storage-allocations
```

Repeat the test commands with `--configuration debug` for the other build
mode. Output directories must be new or empty. The optional benchmark
`--baseline-ref` retains the old default, so the earlier search study remains
reproducible without changing its commands.

## Evidence and limits

The original and repeated native runs are preserved under
[evidence/index-storage/indices-v1](evidence/index-storage/indices-v1).
Each directory contains raw observations, summaries, and a receipt with host,
compiler, source/build hashes, and test receipts. The receipt records SHA-256
hashes for the sibling data files and the original emitted records.

The revised Linux results are preserved under
[evidence/index-storage/enumerated-v2/linux](evidence/index-storage/enumerated-v2/linux).
An independent audit recomputed every paired metric from all 216 timing
observations and 72 allocation observations, checked exact paired outputs, and
confirmed that only the production Filter differed between compared builds.

The workflow and complete logs are available in the
[initial run and native repeat](https://github.com/Jagalite/illiquid/actions/runs/40633256439)
and [enumerated revision run](https://github.com/Jagalite/illiquid/actions/runs/40733770640).
The committed raw observations and receipts do not depend on artifact retention.

These experiments do not measure physical typing, SwiftUI frame delivery,
filesystem discovery, media decoding, playback energy, or whole-player memory.
Linux allocation measurements apply to that runtime. Native timing applies to
the recorded macOS host and workload. Successful behavior tests are not live
UI qualification.
