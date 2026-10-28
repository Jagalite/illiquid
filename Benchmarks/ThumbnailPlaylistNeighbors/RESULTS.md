# Thumbnail playlist neighborhood: research results

## Finding and qualification

The scheduler can prepare the same thumbnail neighborhood without first copying
every playlist URL. The replacement searches the original `[FolderPlaylistItem]`
and copies only the selected window, bounded to nine URL values and nine distance
entries. It also returns immediately when there is no current video.

The portable experiment succeeded: all nine behavior tests passed against both
implementations in debug and release, and all 15 workload medians improved.
This is **Linux component evidence**. The full native macOS application graph,
scheduler integration, and macOS timing remain unqualified while the native
workflow is queued. The associated pull request is a draft for that reason.

## Revisions and reproducibility

| Item | Receipt |
| --- | --- |
| Original scheduler / baseline | [`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`](https://github.com/Jagalite/illiquid/commit/ea2ff568237e2667f7b1aeee67b11a44ebe95b72) |
| Measured candidate | [`0206a3d73b96ca8948a32961a31670ad6a1446c4`](https://github.com/Jagalite/illiquid/commit/0206a3d73b96ca8948a32961a31670ad6a1446c4) |
| Production code and test commit | [`917c8b48319f2fa431c603e2fd308f74eb9e9f52`](https://github.com/Jagalite/illiquid/commit/917c8b48319f2fa431c603e2fd308f74eb9e9f52) |
| Successful portable job | [Run 40637334797, job 122647222180](https://github.com/Jagalite/illiquid/actions/runs/40637334797/job/122647222180) |
| Native validation | [Run 40635554217](https://github.com/Jagalite/illiquid/actions/runs/40635554217); both jobs still queued at 2026-10-28 05:40 UTC |
| Measured host | Linux x86_64, glibc 2.39, 4 logical CPUs, Swift 6.4.1 |
| Experiment start | 2026-10-28 05:19:47 UTC |
| Working tree during measurement | Clean for the relevant source paths |

The later report/evidence commit does not change the measured production code,
tests, harness, or runner. The native run started from the production commit; the
next commit added only the independent portable workflow. The same production
source is under native validation.

The exact original emitted evidence is checked into
[`evidence/linux/`](evidence/linux/), so it survives the workflow's 14-day
artifact retention:

- [Summary](evidence/linux/summary.json): per-workload wall and CPU statistics.
- [Raw timed samples](evidence/linux/measurements.jsonl): all 180 measured rows,
  including exact result receipts, checksums, iterations, and ordering.
- [Manifest](evidence/linux/manifest.json): source revision, compiler, host, and method.
- [Test results](evidence/linux/tests.json): baseline/candidate debug/release outcomes and test counts.
- [Source receipts](evidence/linux/source-receipts.json): copied and generated inputs.
- [Build receipts](evidence/linux/build-receipts.json): executable paths and SHA-256 hashes.
- [Original CI job](https://github.com/Jagalite/illiquid/actions/runs/40637334797/job/122647222180): hosted compilation and test log; the log itself is not copied here.

See [README.md](README.md) for reproduction commands and the native workflow.

## Why this area

At the beginning of an eligible background pass,
`ThumbnailBackgroundScheduler.runPass` synchronously runs on the main actor.
Previously it formed `playlist.map(\.url)` before even checking whether a current
video existed, then found the anchor and copied at most four neighbors on each
side. A large folder therefore incurred a full URL-array construction for a
small scheduling input.

The new `ThumbnailPlaylistNeighbors` helper performs `firstIndex` directly on
the original item array. Once the anchor is found, it copies the clipped range
and builds the distance dictionary in one bounded loop. No full URL projection
is needed.

| Case | Previous work | Replacement work |
| --- | --- | --- |
| No current video | Project all n URLs, then return an empty neighborhood | Return immediately |
| First match near start | Project all n URLs, scan to the anchor, copy the window | Scan to the anchor, copy the window |
| Late or absent match | Project all n URLs and scan the relevant prefix or whole array | Scan the relevant prefix or whole array |
| Additional URL element storage | Full n-element projection plus small output | Small output of at most nine entries |

This preserves the existing URL equality, first matching anchor, clipped window,
playlist order, duplicate URL entries, and last-occurrence distance assignment
for repeated URLs within the window. Candidate assembly and downstream ranking
remain unchanged. The optimization does not add a cache, invalidation state, or
background concurrency.

## Experiment design

The runner extracts the original map, anchor, window, and distance blocks from
the pinned baseline scheduler and wraps them in the helper's interface. Only the
caller expression is replaced by the initializer parameter. The candidate uses
the checked-in helper directly.

Both variants use identical copies of the repository's real playlist item,
normalization, natural ordering, and thumbnail policy sources. They are built as
separate SwiftPM packages with `IlliquidCore`, `IlliquidApp`, and executable
modules. The executable accesses the app module through testable access; no
explicit cross-module optimization is enabled. The experiment measures the
helper boundary, not the full application.

The workloads cover 10, 10,000, and 100,000 playlist entries, with current nil,
first, middle, last, or missing. Fixture construction, an independently created
current query, ten warmup calls, and JSON serialization occur outside timing.
The timed loop includes result ownership and a consumed checksum; there is no
empty-loop subtraction.

Eight-call pilots calibrate each workload toward 30 milliseconds per sample,
within a one-to-one-million iteration range. Six pairs alternate baseline-first
and candidate-first order, rotate workload order, and launch every sample in a
fresh process. Both monotonic wall time and process CPU time are recorded.

The audit reconstructed expected ordered URLs and distance dictionaries for
every row, verified checksum units and iteration counts, checked all three AB
and three BA pairs per workload, and recomputed every wall/CPU summary from raw
rows. There were no discrepancies. Source hashes were independently calculated
and matched all nine measured source inputs, the original scheduler, the
extracted baseline wrapper, and the generated package manifest.

## Measured wall time

Times below are medians in **microseconds per construction** on the Linux host.
The reduction column is the **median of the six paired percentage reductions**,
so it need not equal the percentage calculated from the two displayed medians.

| Playlist entries | Current URL | Baseline µs | Candidate µs | Paired median reduction | Faster pairs |
| ---: | --- | ---: | ---: | ---: | ---: |
| 10 | nil | 0.169 | 0.015 | 91.1159% | 6/6 |
| 10 | first | 0.965 | 0.813 | 16.9808% | 6/6 |
| 10 | middle | 1.632 | 1.446 | 12.4576% | 5/6 |
| 10 | last | 1.065 | 0.879 | 19.4502% | 6/6 |
| 10 | missing | 0.224 | 0.080 | 64.4982% | 6/6 |
| 10,000 | nil | 135.887 | 0.015 | 99.9889% | 6/6 |
| 10,000 | first | 135.754 | 0.840 | 99.4175% | 6/6 |
| 10,000 | middle | 168.929 | 30.673 | 82.0408% | 6/6 |
| 10,000 | last | 203.707 | 60.530 | 70.1730% | 6/6 |
| 10,000 | missing | 183.218 | 44.391 | 75.8557% | 6/6 |
| 100,000 | nil | 1364.151 | 0.015 | 99.9989% | 6/6 |
| 100,000 | first | 1384.606 | 0.792 | 99.9430% | 6/6 |
| 100,000 | middle | 1735.283 | 313.466 | 81.7361% | 6/6 |
| 100,000 | last | 2195.419 | 686.772 | 68.6296% | 6/6 |
| 100,000 | missing | 1867.562 | 450.616 | 75.7633% | 6/6 |

All 15 workload medians improved. The candidate was faster in 89 of 90 paired
comparisons for both wall and CPU time. The one slower wall-time pair was the
10-item/middle workload, pair index 2: 1,578.79 ns baseline versus 1,629.07 ns
candidate, a 3.1851% increase. That workload still had five of six faster pairs
and a 12.4576% median paired reduction. Six pairs are not a formal statistical
confidence result.

The nil case's very small candidate time includes the empty result and checksum
loop. Treat it as a demonstration that the linear projection disappeared, not
as a reliable prediction of a user-visible nanosecond latency.

## Memory result

The portable harness measured `MemoryLayout<URL>.stride == 16`. At 100,000
playlist entries, the eliminated full projection represents:

```text
100,000 URL values × 16 bytes = 1,600,000 bytes = 1.526 MiB
```

This is a **structural element-payload estimate**, not a measurement of process
RSS, peak heap, allocation count, or application footprint. It excludes array
headers, capacity rounding, allocator overhead, URL backing objects, and the
existing input playlist. The replacement's URL array and distance dictionary are
bounded to nine entries each. The estimate uses the observed Linux URL layout;
the native platform must record its own layout.

The input playlist remains shared with the caller. This research does not claim
that the old array survived an `await`, that it kept unrelated metadata alive, or
that this change fixes a leak. Optimized ARC lifetimes were not measured.

## Correctness and remaining native validation

The same nine Swift Testing tests passed for the baseline and candidate in
debug and release: **nine distinct tests, 36 executions**. They cover empty,
nil, missing, singleton, boundary windows, repeated anchors, duplicate-distance
overwrites, exact URL identity, 256 deterministic differential cases, and
identical downstream candidate/ranking results for all thumbnail priorities
and several limits.

The separate macOS workflow is configured to:

1. Run the same isolated component checks and paired measurements using the
   repository's native macOS/Swift toolchain.
2. Prepare the pinned native SDK, build the full app graph, and run neighborhood,
   thumbnail policy, scheduling, cancellation, and lifecycle regression tests.

At the status recorded above, both native jobs were queued with no execution.
The portable result does not establish a full app build, native scheduler
integration, macOS performance, playback smoothness, decoding throughput, energy
use, or visible UI latency. Shared hosted-runner variation and compiler/platform
differences limit extrapolation. A late or missing current URL still requires a
linear scan; the measured improvement does not remove that remaining cost.

The proposed production change is small and behavior-preserving in the measured
component, but the PR remains a draft until native qualification is available.
