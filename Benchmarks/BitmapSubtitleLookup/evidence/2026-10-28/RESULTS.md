# Bitmap subtitle hybrid lookup — qualification outcome (2026-10-28)

**Decision: REJECTED — do not open a performance pull request for this candidate.**
The candidate's four-cue suffix scan followed by binary search improves certain far-from-tail
lookups but introduces material regressions in plausible buffered and near-tail cases.
The production change was restricted to `BitmapSubtitleTimeline.composition(at:)`.

## Results and controls

Baseline `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`;
candidate `1e0979032bba0857d15d79391249e1ccbbd639bf`.
The qualified native job used **Apple M1 (Virtual), macOS 26.6.2, Apple Swift 6.3.3,
SDK 26.5**. CPU data below are medians in **ns per completed lookup**, not frame times.
Positive changes mean the candidate is slower; 8/8 means all eight paired measurements
favored the candidate.

| Native macOS workload | Baseline ns | Candidate ns | Change | Candidate faster pairs |
| --- | ---: | ---: | ---: | ---: |
| `window_128_before_first` | 90.31 | 33.82 | -62.55% | 8/8 |
| `window_128_near_first` | 199.52 | 153.78 | -22.92% | 8/8 |
| `window_32_before_first` | 25.89 | 20.66 | -20.20% | 8/8 |
| `window_32_middle` | 124.02 | 138.62 | +11.77% | 1/8 |
| `stream_history30_ahead30_32` | 121.54 | 140.75 | +15.80% | 0/8 |
| `window_128_tail_minus_4` | 116.10 | 137.45 | +18.39% | 1/8 |
| `window_128_tail_minus_5` | 75.44 | 81.04 | +7.43% | 0/8 |

The full native matrix contains 60 workloads; the candidate is slower in 34
on CPU median. Particularly relevant failures: `stream_history30_ahead30_32`
is 15.80% slower (0/8 pairs faster); `window_128_tail_minus_4` is 18.39%
slower (1/8 faster), and `window_128_tail_minus_5` is 7.43% slower (0/8 faster).
These regressions outweigh the large before-first gains for an unproven query mix.

The independent Linux Foundation experiment (Swift 6.3.2, x86_64 AMD EPYC 9V74)
also contains 60 workloads, with 34 slower on CPU median. Examples:
- 128-entry before-first: **65.13% faster**, all 8 pairs.
- 32-entry before-first: **34.18% faster**, all 8 pairs.
- 128-entry five-future-event near-tail: **12.26% slower**, 0/8 pairs faster.
- 32-entry five-future-event near-tail: **5.48% slower**, 0/8 pairs faster.

Linux and macOS absolute times are **not pooled or compared**. This is component
research, not an estimate of whole-player CPU, frame rate, latency, memory, or energy
savings. Actual subtitle timeline occupancy and query-position frequency remain
unmeasured. The default timeline is bounded to 128 entries.

## Correctness and independent raw-sample audit

Each platform completed all **28 tests** for baseline debug, baseline release,
candidate debug, and candidate release. **3,050 complete-output cases** matched,
including region bytes, timing, geometry, clears, expiry and lease state.
Each platform produced **960 observations** = 60 workloads × 8 alternating
baseline/candidate pairs × 2 variants. In a separate audit of both
`measurements.jsonl` files:

- All 60 workloads had exactly 16 observations; no missing pairs.
- Pair ordering was correctly alternating AB/BA.
- First/last complete result snapshots and cycle checksums matched within each pair.
- All recorded CPU and wall durations exceeded the 60 ms minimum. The native
  minima were **199.121 ms CPU / 199.615 ms wall**, and Linux
  **235.659 ms CPU / 235.692 ms wall**.
- Every baseline and candidate CPU median and all median paired ratios
  recalculated from raw timing records to the reported summary within rounding.
  No observations were excluded.

The emitted `summary.json` files retain all 60 workloads and eight paired
ratios per workload, including regressions. `build-receipt.json` retains
the compiler, source hashes, exact native/portable adaptation, and linked
library identity. The checkout ownership failure in
[portable setup run 40640400590](https://github.com/Jagalite/illiquid/actions/runs/40640400590)
produced no measurements and is not included in these totals.

## Full CI evidence and reproduction

- [Native macOS run 40639454368](https://github.com/Jagalite/illiquid/actions/runs/40639454368)
  and its [artifact](https://github.com/Jagalite/illiquid/actions/runs/40639454368/artifacts/12821369733)
- [Portable Linux run 40641025640](https://github.com/Jagalite/illiquid/actions/runs/40641025640)
  and its [artifact](https://github.com/Jagalite/illiquid/actions/runs/40641025640/artifacts/12796092918)
- Native artifact expires **2026-11-11 14:10 UTC**; Linux expires
  **2026-11-11 06:10 UTC**. The saved JSON summaries and source runner
  remain on this research branch.

Reproduce with the `run.py` commands in
[the parent research README](../../README.md). Both jobs verified complete
production timeline logic with separately optimized modules; only Linux compile
copies drop exact CoreGraphics imports. The shared Kyoto queue was unavailable
on the isolated CI runners.

A separate, already-open [PR #216](https://github.com/Jagalite/illiquid/pull/216)
investigates a different bitmap lookup algorithm. Its measurements must not be
attributed to this rejected hybrid candidate.
