# External subtitle association memory

This component experiment compares two temporary arrays in the original
`ExternalSubtitleMatcher` with a streaming candidate visitor and direct indexed
mutation of existing dictionary values during final subtitle sorting. The
candidate removes both the collected candidate IDs and `Array(result.keys)`.
Both variants compile the **complete, unmodified production matcher**, `MediaFileSupport`
and `NaturalFilenameOrdering` into a separate optimized `IlliquidCore` module.
There are no private-access edits, allocator hooks in production, or model
implementations of the matching algorithm.

## Linux result — 2026-10-24

The final change reduced the sampled allocator high watermark of a complete
external-subtitle association by **1.35–4.75%** across the affected workloads.
With 32,768 media inputs, the broad-prefix case saved **263,008 bytes**
(about 0.25 MiB), while dense, exact and unrelated cases each saved
**524,336 bytes** (about 0.50 MiB). Empty-subtitle controls were unchanged at
every size. These are additional live allocator-accounted bytes above the
prepared input fixture, sampled at cancellation polls and after return.
The 4,096- and 32,768-media workloads are stress fixtures, not claims about
typical folder sizes.

The experiment used Swift 6.3.2, Linux x86-64/glibc 2.39, an Intel Xeon
Platinum 8573C host and CPU affinity 0. Other tasks shared the host; affinity
did not reserve that CPU. Source commit
`a8d950d6c1a1d22381fc7debee7b12632ec65a18` was measured against the pinned
baseline. The matcher SHA-256 was
`6a18f9eeee002ef2d578545aa6b7e443fa51d16f3ec5d7211dc45ae8ae6753b1`.

All **480 measured observations** passed: 20 workloads × six balanced pairs
× two variants × two measurement modes. Every complete association mapping
was also compared in separate fresh verification processes. All 20 canonical
mappings were byte-identical, and cancellation-poll counts agreed in every
memory pair. For each variant/workload, all six memory observations had
identical sampled-peak and post-return byte totals.

### Complete memory matrix

These are sampled peak allocator **growth** medians in bytes, with input URLs
already alive. They do not measure every-allocation peak or macOS player RSS.

| Media | Workload | Baseline bytes | Candidate bytes | Saved bytes | Reduction |
| ---: | --- | ---: | ---: | ---: | ---: |
| 64 | broad | 40,160 | 38,256 | 1,904 | 4.74% |
| 64 | dense | 24,832 | 23,760 | 1,072 | 4.32% |
| 64 | exact | 66,752 | 65,680 | 1,072 | 1.61% |
| 64 | unrelated | 39,328 | 38,256 | 1,072 | 2.73% |
| 64 | empty | 4,480 | 4,480 | 0 | 0.00% |
| 512 | broad | 305,664 | 300,704 | 4,960 | 1.62% |
| 512 | dense | 175,472 | 167,232 | 8,240 | 4.70% |
| 512 | exact | 332,256 | 324,016 | 8,240 | 2.48% |
| 512 | unrelated | 304,800 | 296,560 | 8,240 | 2.70% |
| 512 | empty | 26,096 | 26,096 | 0 | 0.00% |
| 4,096 | broad | 2,439,760 | 2,406,128 | 33,632 | 1.38% |
| 4,096 | dense | 1,387,664 | 1,322,080 | 65,584 | 4.73% |
| 4,096 | exact | 2,466,272 | 2,400,688 | 65,584 | 2.66% |
| 4,096 | unrelated | 2,438,896 | 2,373,312 | 65,584 | 2.69% |
| 4,096 | empty | 202,032 | 202,032 | 0 | 0.00% |
| 32,768 | broad | 19,429,552 | 19,166,544 | 263,008 | 1.35% |
| 32,768 | dense | 11,029,792 | 10,505,456 | 524,336 | 4.75% |
| 32,768 | exact | 19,456,000 | 18,931,664 | 524,336 | 2.69% |
| 32,768 | unrelated | 19,428,688 | 18,904,352 | 524,336 | 2.70% |
| 32,768 | empty | 1,586,464 | 1,586,464 | 0 | 0.00% |

### Independent CPU and wall-time observations

CPU medians generally favored the candidate, but paired ranges varied
substantially. The unchanged empty-subtitle path also moved in both directions;
at the largest size its paired CPU changes ranged from −50.6% to +161.5%.
This shared-host run therefore does **not** establish a general CPU speedup.
The measured memory reduction is the principal result.

Each time column is the median milliseconds per complete association, including
result-count consumption and destruction. `Δ` is the median of paired
`candidate / baseline − 1` changes; it can differ from the ratio of the two
independently calculated medians. Negative values mean less time. The CPU range
is the minimum/maximum paired change across six pairs. Timings use no allocator
sampling and equal iteration counts chosen to target at least 100 ms of process
CPU work based on the faster pilot; observed durations can vary with host load.

| Media | Workload | Baseline CPU ms | Candidate CPU ms | Paired CPU Δ | Paired CPU range | Paired wall Δ |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 64 | broad | 0.652 | 0.559 | -11.51% | -46.4% to +1.5% | -9.87% |
| 64 | dense | 0.529 | 0.517 | -4.55% | -20.0% to +7.3% | -4.93% |
| 64 | exact | 0.617 | 0.611 | -0.72% | -47.1% to +6.2% | -0.74% |
| 64 | unrelated | 0.580 | 0.580 | -0.46% | -5.1% to +37.9% | -0.79% |
| 64 | empty | 0.024 | 0.022 | -5.75% | -14.6% to +3.7% | -14.62% |
| 512 | broad | 4.823 | 4.545 | -6.40% | -38.2% to -1.5% | -16.68% |
| 512 | dense | 3.969 | 3.713 | -6.73% | -12.4% to -2.1% | -6.10% |
| 512 | exact | 4.520 | 4.150 | -5.92% | -13.2% to -0.4% | -5.90% |
| 512 | unrelated | 4.510 | 4.170 | -7.53% | -26.5% to +16.9% | -8.28% |
| 512 | empty | 0.177 | 0.178 | +1.64% | -8.8% to +19.1% | +1.63% |
| 4,096 | broad | 38.501 | 36.296 | -6.59% | -11.7% to +9.1% | -6.61% |
| 4,096 | dense | 36.268 | 32.951 | -3.03% | -27.2% to +19.5% | -2.79% |
| 4,096 | exact | 38.499 | 39.291 | +1.75% | -9.1% to +137.1% | +2.84% |
| 4,096 | unrelated | 40.552 | 35.602 | -10.65% | -14.0% to -2.6% | -11.56% |
| 4,096 | empty | 1.785 | 1.737 | -2.12% | -30.6% to +2.6% | -0.86% |
| 32,768 | broad | 436.392 | 424.452 | -8.26% | -27.6% to +17.3% | -18.90% |
| 32,768 | dense | 368.505 | 327.701 | -8.06% | -23.3% to +19.4% | -34.78% |
| 32,768 | exact | 439.674 | 384.388 | -9.78% | -48.7% to +7.8% | -8.21% |
| 32,768 | unrelated | 416.468 | 372.877 | -12.21% | -47.8% to +65.6% | -12.98% |
| 32,768 | empty | 28.981 | 26.859 | -2.59% | -50.6% to +161.5% | -15.09% |

### Qualification and retained evidence

- The same four regression suites passed **38 tests** against baseline and
  candidate sources in both debug and release, with warnings treated as errors.
  These are component tests; their execution durations are not benchmark data.
- The [test qualification receipt](evidence/linux/tests/qualification.json)
  records compiler options, source/test hashes and all four completed configurations.
- The [independent audit](evidence/linux/independent-audit.json) checks the
  source provenance, receipt arithmetic, semantic parity and reported results.
- [Summary](evidence/linux/summary.json),
  [raw observations](evidence/linux/observations.jsonl),
  [calibration](evidence/linux/calibration.json),
  [source and host manifest](evidence/linux/manifest.json),
  [CPU-affinity observation](evidence/linux/host-affinity-observation.json), and
  [full-output verification receipts](evidence/linux/verification.json) retain
  the measurement and reproduction details. Compressed full mappings and exact
  compiled sources are in the corresponding evidence subdirectories.

The initial visitor-only candidate was rejected as a useful complete-call
memory result: at 32,768 broad-prefix inputs its sampled peak fell by only
864 bytes, and dense inputs were unchanged. Removing the candidate list moved
its bottleneck to `Array(result.keys)` in final sorting. The final change
removes that second temporary array too. The
[visitor-only evidence](evidence/rejected-visitor-only/README.md) is retained
separately; its one-iteration timing smoke is not used for performance claims.

These Linux component measurements do not qualify macOS playback or establish
a reduction in the complete player’s footprint. The dedicated
[native workflow](../../.github/workflows/subtitle-candidate-memory.yml)
repeats the component tests and measurements on macOS. Its initial
[run 40102603521](https://github.com/Jagalite/illiquid/actions/runs/40102603521)
was queued and native qualification remained **pending** at this report update.
That workflow does not exercise the full player, UI or live playback.

## Reproduction

### Current supporting-source regressions

Pull-request CI uses `--regression-only` after the existing debug and release
matcher regression suites. It verifies every full association against the
fixture oracle and compares the complete outputs for both variants at all
configured sizes and scenarios, including empty and unrelated controls. No
memory or timing measurements run in this mode.

The baseline matcher remains pinned and hash-checked. Both variants use the same
single capture of current `MediaFileSupport.swift` and
`NaturalFilenameOrdering.swift`; the candidate matcher is captured at the same
time. This covers changes to either shared dependency without presenting them
as a reproduction of the historical performance study.

```sh
python3 Benchmarks/SubtitleCandidateStreaming/run.py \
  --regression-only --output /tmp/subtitle-candidate-regressions
```

Manifests and the regression summary label the source policy and lack of
performance measurements. Every compiled file has a retained snapshot, origin,
source revision, SHA-256, Git blob hash and comparison with the historical hash;
checkout/status records distinguish dirty current inputs. Historical files
(including `--baseline-dir` inputs) must still match every pinned hash before
support substitution. Failures retain a failed manifest. `--prepare-only` and
`--memory-only` cannot be combined with this mode.

Default, push and manual runs keep strict historical dependency guards and all
memory, cancellation-poll and timing checks. Reproduce those measurements in a
compatible checkout: dependency drift still fails. Existing `--verify-only`
does not relax the guards. All immutable evidence, including rejected results
and runner snapshots, remains unchanged.

### Historical measurements

Requirements: Swift 6.1+, Python 3, and either macOS or Linux with glibc 2.33+.
No package dependencies are fetched. Follow repository build coordination
instructions, and avoid concurrent builds/tests during formal timing.

```sh
python3 Benchmarks/SubtitleCandidateStreaming/run.py \
  --output /tmp/illiquid-subtitle-candidate-streaming \
  --sizes 64,512,4096,32768 --pairs 6 --target-ms 100
```

Short build and parity smoke, with insufficient timing samples for performance
conclusions:

```sh
python3 Benchmarks/SubtitleCandidateStreaming/run.py \
  --output /tmp/illiquid-subtitle-candidate-smoke \
  --sizes 64,512 --pairs 2 --iterations 1
```

`--swift` selects the toolchain; preserve the `swift` executable symlink name.
`--cpu` optionally selects one available Linux CPU. `--prepare-only` only
stages/builds, and `--verify-only` adds full association verification without
measurement. `--memory-only` verifies outputs and samples memory without timing
or calibration processes. `--baseline-dir` accepts preserved baseline files from an earlier
run when Git history is shallow; every file must match its pinned SHA-256.

## Workloads and correctness

The baseline is main at `4abf4b44f13386ccd04f1ce4ad0e756255ca4d14`. The two support
files must remain byte-identical to the historical baseline in default mode.
Every compiled production
file and common harness source is preserved with its SHA-256 and Git blob hash.
The runner records host/compiler details, build commands, binary hashes and
all raw observations.

Each size contains uniquely numbered `Shared.Series.Episode…` media filenames:

- **Broad:** one `Shared.Series.en.srt` subtitle visits the broad matching
  subtree. All scores tie, so no subtitle is associated.
- **Dense:** distinct `Shared.Series.00000000p.x265.mkv` media names lose their
  resolution/codec qualifiers and share one terminal node. The generic subtitle
  ties again; this controls for the different pending-stack and terminal-array
  behavior compared with a wide descendant subtree.
- **Exact:** three language subtitles match the middle media file. Reversed
  inputs must produce the expected ordered subtitle array.
- **Unrelated:** one subtitle has no matching token prefix.
- **Empty:** no subtitles; the established empty-inventory path remains active.

A fixture oracle verifies every original media key, subtitle URL and subtitle
ordering without using the production scoring or normalization functions.
Separate fresh verification processes serialize the full associations; their
canonical records must be byte-identical across variants and are retained as
compressed JSON. Each measurement also validates the complete result and emits
a deterministic digest. Memory pairs require identical cancellation-poll
counts, while dedicated regression tests qualify cancellation outcomes.

## Memory measurement

Memory and timing are independent experiments. Every observation starts a new
process. A tiny real association warms runtime paths and the sampling callback.
Input URL arrays are constructed before the initial reading and held alive
through the experiment. A callback passed through the public `isCancelled`
parameter samples allocator-accounted live storage at **every cancellation
poll** and always returns false. A final reading occurs after `associate`
returns, with its output still alive. Result verification and JSON construction
occur only after all readings.

The primary metric is the largest sampled live-byte reading minus the initial
reading. The post-return growth, cancellation-poll count and index of the
largest callback sample are reported too.
The maximum includes the post-return reading; `maximumSamplePoll` identifies
the largest **callback** sample specifically, even if the post-return reading
is larger.

- Linux: `mallinfo2().uordblks + mallinfo2().hblkhd`, including mmap allocations.
- macOS: `malloc_zone_statistics(NULL, …).size_in_use`.

**This is a sampled allocator high watermark, not the true every-allocation
peak.** Short allocations wholly between cancellation polls can be missed.
Allocator rounding, caches and runtime activity can affect readings. The
measurement covers the complete association call, including its index and
output dictionary; it is not an exact object-size calculation, process RSS,
whole-player footprint, or accumulating-leak claim.

The removed arrays are transient. Large broad-prefix inputs exercise candidate
collection; exact and no-match inputs still exercise final result sorting.
Empty-subtitle inputs bypass both affected stages and serve as an unchanged
control. Do not infer a uniform reduction across ordinary directories from
stress-query results.

## Independent timings

Timing processes do not sample heap statistics. They use a constant-false
cancellation callback in both variants and perform two warmup associations.
The measured loop includes complete association, result-count consumption and
result destruction. Input setup, full validation and JSON encoding are outside
the bracket. Monotonic wall and process CPU clocks are recorded.

Fresh calibration processes choose one equal iteration count per workload,
targeting the requested **process CPU** duration for the faster pilot, so both
variants aim to perform at least that much CPU work. Subsequent fresh-process
observations run in sequential balanced AB/BA pairs. Results retain medians,
minima, maxima and paired percentage changes; no timing threshold is hidden in
the runner. Report regressions or noisy controls explicitly. These timings do
not establish whole-player playback, UI or filesystem responsiveness.
