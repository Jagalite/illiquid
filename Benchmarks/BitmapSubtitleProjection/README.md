# Bitmap subtitle region projection

`NativeBitmapSubtitleComposition.renderedRegions(in:forcedOnly:)` transforms
bitmap subtitle regions into display coordinates. The baseline first builds a
filtered region array even when `forcedOnly` is false and every region passes.
The candidate shares the existing input array in that case and maps it directly.
Forced-only selection still filters before the same projection arithmetic.

The production change is two lines in `BitmapSubtitleTimeline.swift`. It leaves
timeline lookup/insertion, pixel bytes, region order, coordinate arithmetic,
stride, bitmap size, color flags, and memory-lease sharing unchanged.

## Status and decision

**Draft research PR: the ordinary projection path improves on Linux; native
macOS qualification is pending.** The measured production source, tests, and
harness correspond to commit `0b82a8d7a05eda7aac79d2ee9ec5f08f26144f79`.
Later report/evidence changes do not change the measured code.

The primary Linux thresholds and exact-output checks passed. The complete
acceptance criterion is not declared satisfied: forced-only controls remain
variable, empty ordinary projection has a small repeatable absolute cost, and
native macOS integration/performance results are not yet available. Review
these tradeoffs and the native results before marking this PR ready.

The dedicated [native qualification run](https://github.com/Jagalite/illiquid/actions/runs/40635619040)
was queued when this report was finalized. It separately runs component
correctness/performance and full app-graph bitmap/Picture-in-Picture integration
tests on `macos-26`. A queued job is not a passed test or a native timing result.

## Recorded Linux results

Host: AMD EPYC 9V74, x86_64 Linux, Swift 6.3.2, optimized production module
compiled separately from the driver. This is a shared execution environment;
CPU frequency and competing workloads were not controlled.

The complete campaign contains **520 observations: 26 workloads, ten paired
comparisons each, and both variants per pair**. Ordinary one-, two-, and
four-region cases are the primary workloads; 16/64 are scaling probes. These
fixtures are not a measured distribution of real subtitle tracks.

Times are median process CPU nanoseconds per complete projection plus result
consumption/release. Percentages are **median paired reductions**; they are not
the ratio of the two independently calculated medians. Positive reduction means
faster and negative reduction means slower.

| Input regions, ordinary selection | Baseline ns | Candidate ns | Paired CPU reduction | Faster CPU pairs |
|---:|---:|---:|---:|---:|
| 1 | 133.77 | 86.60 | 36.05% | 10/10 |
| 2 | 235.37 | 124.44 | 47.12% | 10/10 |
| 4 | 307.07 | 155.49 | 48.77% | 10/10 |
| 16 | 903.79 | 448.81 | 45.45% | 10/10 |
| 64 | 2895.44 | 1978.77 | 35.87% | 10/10 |

All 50 ordinary nonempty comparisons were faster in both CPU and wall time.
For 1/2/4 regions, the differences between CPU medians are approximately
47/111/152 ns per changed projection. These are small component savings; the
pipeline caches unchanged bitmap output. No whole-player CPU, FPS, resident
memory, allocation-count, or energy improvement was measured.

### Adverse controls and bounded follow-up

The complete campaign found an empty ordinary projection increase from
12.74 to 14.79 ns (21.41% median paired CPU increase; 9/10 pairs slower).
It also found a `forced-some-64` increase from 1,558.23 to 1,697.81 ns
(12.77% median paired increase; 7/10 pairs slower). Neither result was dropped.

A single post-hoc follow-up, with its plan recorded before measurement, reused
the exact tested binaries. It retained all **200 observations** from 20 balanced
pairs of five workloads and raised the CPU calibration target to 500 ms.
Four workloads reached at least 450 ms in calibration; empty output hit the
10-million-iteration cap at 115.81 ms. The original campaign remains the primary
report and is not replaced by this selected follow-up.

| Follow-up workload | Baseline ns | Candidate ns | Paired CPU reduction | Paired wall reduction | Faster CPU pairs |
|---|---:|---:|---:|---:|---:|
| unforced-0 | 12.89 | 15.63 | -16.67% | -14.61% | 3/20 |
| forced-some-64 | 1521.31 | 1568.21 | +1.64% | +3.73% | 11/20 |
| forced-all-64 | 3028.33 | 3207.90 | -4.11% | -5.48% | 7/20 |
| forced-none-64 | 55.10 | 48.73 | +14.01% | +15.44% | 15/20 |
| unforced-2 | 206.38 | 106.14 | +43.18% | +43.14% | 20/20 |

The two-region ordinary improvement repeated in all 20 pairs. The original
forced-some-64 slowdown did not repeat consistently: the follow-up median paired
CPU reduction was 1.64%, with 11/20 pairs faster. This does **not** establish
forced-path neutrality; the forced-all-64 follow-up was 4.11% slower by the same
paired statistic. Both cohorts and every observation are retained.

Empty ordinary projection remained roughly 2–3 ns slower. Inspection of the
existing optimized binaries found an additional source-array retain/release
on this path, a plausible cause of its small fixed cost. The forced key path
is lowered to a direct Boolean field test, with no key-path construction or
projection calls. Generated function layout and register allocation differ,
so assembly alone cannot settle the forced-only timing question.

### Complete primary matrix

`some` selects alternating forced flags (`index % 2 == 0`); `all` and `none`
select all or no flags. Zero-count variants intentionally share empty behavior.
Every negative result is shown below. Full paired ratios and absolute CPU/wall
medians are in [linux-summary.json](evidence/linux-summary.json).

| Workload | Baseline CPU ns | Candidate CPU ns | Paired CPU reduction | Paired wall reduction | Faster CPU pairs |
|---|---:|---:|---:|---:|---:|
| unforced-0 | 12.74 | 14.79 | -21.41% | -23.00% | 1/10 |
| forced-all-0 | 12.25 | 12.38 | +0.07% | -1.71% | 5/10 |
| forced-some-0 | 12.36 | 13.23 | -4.93% | -5.02% | 1/10 |
| forced-none-0 | 13.96 | 15.41 | -9.91% | -8.42% | 2/10 |
| unforced-1 | 133.77 | 86.60 | +36.05% | +37.21% | 10/10 |
| forced-all-1 | 119.85 | 115.02 | +6.60% | +7.16% | 7/10 |
| forced-some-1 | 111.14 | 138.05 | -4.21% | -15.80% | 5/10 |
| forced-none-1 | 14.54 | 14.80 | -5.85% | -8.34% | 3/10 |
| unforced-2 | 235.37 | 124.44 | +47.12% | +47.50% | 10/10 |
| forced-all-2 | 228.67 | 229.67 | -7.98% | -9.40% | 4/10 |
| forced-some-2 | 130.02 | 142.75 | -7.39% | -4.21% | 5/10 |
| forced-none-2 | 15.72 | 13.64 | +4.49% | -3.79% | 6/10 |
| unforced-4 | 307.07 | 155.49 | +48.77% | +48.71% | 10/10 |
| forced-all-4 | 293.13 | 320.32 | -6.79% | +0.62% | 5/10 |
| forced-some-4 | 215.90 | 215.07 | -0.90% | -4.50% | 5/10 |
| forced-none-4 | 14.03 | 14.42 | -6.07% | -6.59% | 3/10 |
| unforced-16 | 903.79 | 448.81 | +45.45% | +45.80% | 10/10 |
| forced-all-16 | 828.72 | 808.59 | -0.95% | +1.29% | 5/10 |
| forced-some-16 | 445.27 | 505.99 | -1.27% | +1.62% | 5/10 |
| forced-none-16 | 20.73 | 21.99 | +2.29% | +0.93% | 5/10 |
| unforced-64 | 2895.44 | 1978.77 | +35.87% | +35.81% | 10/10 |
| forced-all-64 | 3414.59 | 2945.18 | +6.78% | +1.04% | 6/10 |
| forced-some-64 | 1558.23 | 1697.81 | -12.77% | -14.14% | 3/10 |
| forced-none-64 | 69.39 | 43.45 | +38.71% | +39.28% | 10/10 |
| invalid-zero | 9.44 | 8.10 | +11.70% | +12.02% | 9/10 |
| invalid-nan | 8.67 | 9.30 | -3.09% | -4.47% | 3/10 |

### Correctness and independent review

Both variants passed **32 tests in three suites in debug and release** (four
successful runs). All **208 complete input/output receipts** were byte-identical.
The follow-up rechecked those receipts using the unchanged binaries. This is
component qualification, not a successful full macOS app build.

An independent audit recomputed all 52 primary CPU/wall summaries with exact
integer/Fraction arithmetic, checked all 260 pairs, checksums, calibration,
command-log hashes, source/binary hashes, and the correspondence to the remote
source commit. A second independent audit verified all 100 follow-up pairs,
all ten follow-up CPU/wall summaries, receipts, logs, and unchanged binaries.
A separate assembly review inspected the existing binaries;
it did not rebuild or change the measured source.

In the primary campaign, twenty workloads reached the requested calibration
threshold. Six hit the ten-million-iteration cap first: `unforced-0`,
`forced-none-0`, `forced-none-1`, `forced-some-0`, `invalid-zero`, and `invalid-nan`.
Their achieved fastest calibration intervals ranged from 85.15 to 130.00 ms.
These limits are recorded in the raw calibration receipts.

## Reproduce

Requires Swift 6.1 or newer and Python 3.11 or newer. Run builds through Kyoto
when available, as required by `AGENTS.md`. Otherwise explain that limitation
and use serial builds in an isolated checkout. Run one timing campaign at a time.

```sh
python3 Benchmarks/BitmapSubtitleProjection/run.py \
  --pairs 10 --target-ms 150 --output /tmp/bitmap-subtitle-projection
```

The output directory must be new or empty. `--mode test` runs both production
variants' unit tests in debug and release, builds optimized modules, and checks
complete input/output parity without timing. `--mode benchmark` skips unit tests
but still checks complete output parity before measuring. `SWIFTC` and `SWIFT`
select another toolchain. Caches, temporary files, and build products stay under
the output directory; `HOME` is unchanged.

## Sources and correctness

The frozen baseline is the full timeline source from
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`. The baseline and shared dependency
hashes are pinned in `baseline/manifest.json`; the runner rejects mismatches.
Each variant compiles the complete production timeline and memory-budget files
and the exact `ASSRenderedRegion` declaration extracted from `LibassContext`.
No behavior is mocked. Native builds retain the original imports. On Linux,
only `import CoreGraphics` is removed because real Foundation geometry types
are available there; Linux execution does not establish native macOS timing.

The production module is optimized separately from the driver, with
`-enable-testing` exposing existing internal APIs. There is no cross-module
optimization or copied production projection implementation in the driver.
The final source, driver, tests, compiler, and binary hashes are retained.

The ten new regression functions cover exact pixel bytes/order, ordinary and
forced selection, anisotropic scaling and translation, fractional dimensions,
original bitmap size and stride, empty results, invalid canvas dimensions,
existing nonfinite geometry behavior, repeated calls, value-copy independence,
and shared lease lifetime. Existing timeline ordering and budget accounting
tests run in the same isolated package against both variants in debug/release.

The optimized driver compares 208 complete input/output fixtures: 26 scenarios,
four viewports, and present/absent leases. Receipts include complete bitmap
bytes, floating-point bit patterns, canvas/viewport geometry, forced flags,
output fields, and lease-sharing observations. Timed processes also perform
untimed field/lease checks and emit consumed result checksums; every pair must
agree on its workload, count, warm-up, and output checksum.

## Measurements and decision

Twenty-six timing workloads cover 0, 1, 2, 4, 16, and 64 input regions, with
ordinary selection and forced-only all/some/none patterns, plus zero/NaN canvas
controls. Small ordinary region counts are the primary workloads; 16/64-region
cases are scaling probes, not claims about typical subtitle complexity.

The timed boundary includes complete projection calls, consuming representative
returned fields, and releasing the output arrays. Fixture/pixel/lease creation,
full-output serialization, and correctness checks are outside timing. No pixel
decoding, GPU upload, rendering, or pipeline locking is timed.

Calibration targets at least 90% of the requested process CPU interval in both
variants, subject to 12 attempts and ten million iterations. Achieved intervals
and stopping reasons are recorded. Both variants then use the same fixed count
for each workload in ten fresh-process AB/BA pairs, interleaved across rounds.
All probes and observations are retained. CPU and wall-time summaries report
absolute medians, paired ratios, and faster-pair counts; no outliers are removed.

The research acceptance criterion is at least a 10% median paired CPU reduction
with at least 8/10 faster pairs for ordinary 1/2/4-region projection, exact output
parity, and no repeatable material regression in forced-only/empty controls.
Timing is evidence for review, not a noisy percentage-based CI gate. Native
qualification independently repeats the comparison and builds the full app
graph with bitmap/Picture-in-Picture integration tests.

`SubtitlePipeline` caches unchanged bitmap output. This function runs under its
lock when the bitmap event, timeline revision, or display geometry changes.
Results therefore describe changed-region projection, not an improvement on
every video frame. Absolute savings, small controls, and platform scope matter;
no whole-player CPU, frame-rate, resident-memory, or battery claim is made.

## Evidence

- [Primary summary](evidence/linux-summary.json), [independent primary audit](evidence/linux-audit.json).
- [Focused follow-up summary](evidence/control-summary.json), [independent follow-up audit](evidence/control-audit.json).
- [Assembly review](evidence/assembly-review.json).
- [Evidence index and SHA-256 checksums](evidence/index.json).
- [Complete compressed evidence](evidence/linux-x86_64-20261028.tar.gz).

The archive retains the complete primary and follow-up receipts, all commands
and logs, raw calibration/measurement rows, input source snapshots, compiler and
binary hashes, independent audits, assembly inspection, and the earlier
exploratory projection pilot. The pilot is not used for the acceptance claim.
Reproducible build products and caches are excluded. No timed observations were
trimmed or selectively removed from any retained campaign.

The primary manifest preserves the original precommit worktree state. Its
source hashes and the independent remote Git-blob comparison establish its
correspondence to the published source commit; the manifest was not rewritten
to pretend the benchmark ran after publication.

Native CI artifacts are `bitmap-subtitle-projection-native` and
`bitmap-subtitle-projection-integration`. They retain native logs and receipts
for review when the jobs run; they were not available at report finalization.
