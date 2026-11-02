# Video color region averaging

The adaptive text UI asks VideoColorSample for overall, leading, bottom, and
local averages. average() already clamps its rectangle bounds, but then calls
the public point lookup for every visited cell, clamping those coordinates again.

This candidate indexes the validated region directly, computing each row offset
once. It preserves the original row-major accumulation and division order and
keeps the public point lookup's clamping behavior. Reversed bounds still collapse
at the clamped minimum; they are not swapped. There is no added cache or storage.

## Reproduce

Use Swift 6 and Python 3.10+, with a fresh output directory:

~~~sh
python3 Benchmarks/VideoColorRegionAverage/run.py \
  --output /tmp/illiquid-color-regions --pairs 8 --target-ms 150
~~~

Use --tests-only for correctness checks without timings. Follow AGENTS.md and
submit the entire command through Kyoto on a host where that queue is available.
The isolated GitHub-hosted jobs explain its absence and build sequentially.

Both variants compile the complete VideoColorSample.swift as a separate dynamic
module. The driver is compiled separately without cross-module optimization.
The frozen baseline is verified against its recorded Git blob. Every source,
binary, command, compiler version, test log and raw observation is retained.

Seven independent regression tests run against baseline and candidate in debug
and release. They cover 10,000 deterministic rectangles across several shapes,
extreme and reversed coordinates, one-row/one-column samples, exact summation,
input clamping, UI regions, and public point lookup. Separate differential
receipts compare all Double bit patterns for 16,408 region results per build.

The ten timing cases use the actual production 12-by-8 grid: overall, leading,
bottom, local interior/edge, one cell, clipped and reversed rectangles, a
four-region palette workload, and an unchanged point-lookup control. Data setup,
warmup, process startup and output are outside timing. Every fresh-process pair
uses equal iterations and matching consumed output. AB/BA order balances across
eight pairs while workload order rotates. Wall and process CPU time are retained;
correctness tests impose no timing threshold.

These are component measurements, not measurements of visible UI latency,
decoding, playback FPS, energy or total application CPU. No larger grids are used
to inflate the measured result. Native and Linux results are reported separately.

## Measured Linux results

[Successful Linux component job](https://github.com/Jagalite/illiquid/actions/runs/40637609399/job/122648077821),
measured commit 67d217b1b3ad282f04708826c2078b1792f4df8a:
Ubuntu 24.04 x86_64, Intel Xeon Platinum 8370C at 2.80 GHz, Swift 6.4.
The unchanged complete production source is compiled into each variant's own
dynamic library, whose resolved path was checked with ldd.

| Workload | Baseline ns/call | Candidate ns/call | Median paired wall reduction |
| --- | ---: | ---: | ---: |
| Overall (96 cells) | 138.3 | 115.5 | 16.4% |
| Leading (32 cells) | 60.4 | 47.8 | 21.0% |
| Bottom (24 cells) | 51.8 | 49.6 | 4.3% |
| Local interior (9 cells) | 23.9 | 19.0 | 20.3% |
| Local edge (4 cells) | 15.8 | 13.2 | 17.1% |
| Single cell | 11.1 | 10.5 | 5.7% |
| Clipped whole grid | 137.5 | 115.1 | 16.4% |
| Reversed bounds | 11.2 | 10.5 | 6.8% |
| Four-region palette (161 cells) | 268.4 | 227.6 | 15.2% |
| Point lookup control | 5.08 | 5.08 | 0.04% |

Percentages are medians of per-pair candidate/baseline ratios, rather than
ratios of the two displayed medians. All nine affected workloads were faster
in all eight pairs. CPU-time results agree with wall time. The unchanged point
lookup control is effectively flat: its paired changes range from -0.17% to
+0.91%, with a median reduction of 0.04%.

The principal effects survive execution-order separation. Overall averaging
shows 16.44% reduction in baseline-first pairs and 16.36% in candidate-first
pairs. The four-region palette workload shows 15.11% and 15.24%, respectively.
No observations were dropped. The 160 measured batches lasted 140.865–191.138 ms
against a 150 ms calibration target.

Absolute savings are small: approximately **22.8 ns per overall average** and
**40.7 ns per four-region palette workload**, based on differences in absolute
medians. These results establish an improvement in this component on the
measured Linux host; they do not establish a perceptible UI change or a
whole-player performance gain.

## Correctness and qualification

- Seven unique regression tests passed against both implementations in debug
  and release: 28 successful test executions.
- Each of the four builds produced identical exact receipts for 16,408 region
  results. The comparisons used Python integers, preserving all Double bit
  patterns; both configurations also produced the same receipt hash.
- Tests include explicit index-list expectations and 10,000 seeded rectangles
  across 1×1, 1×8, 12×1, 12×8 and 17×11 grids, plus extreme/reversed bounds,
  derived UI regions, input clamping, accumulation order and point lookup.
- All timed pair checksums match. Every source hash was independently checked
  against the successfully measured inputs. Dynamic library resolution was
  checked for every baseline/candidate debug/release executable.
- The source still uses checked array subscripts. The same row-major additions,
  count increments and final divisions are preserved.
- **macOS qualification is pending.** Its job was queued at the last successful
  status check. The PR remains a draft until native results are available.
  No full application build, live playback or UI qualification is claimed.

The bounds proof is short: a successfully initialized sample has positive C
and R, with colors.count = C×R. After the existing rectangle clamps, every
visited cell satisfies 0 ≤ row < R and 0 ≤ column < C. Therefore
0 ≤ row×C + column < colors.count, with no overflowing intermediate product or
sum. Reversed bounds still collapse at the clamped minimum. No unsafe indexing
or new stored state is introduced.

## Retained evidence

The [Linux evidence directory](evidence/linux) contains every raw observation,
calibration, source/binary manifest, exact command, test log, summary, verification
receipt hash, library-resolution report and independent audit. Complete decision
streams and source snapshots are also in the workflow artifact.

The [initial build failure](evidence/initial-build-failure) is retained separately.
Its baseline debug tests passed, then Swift's type checker rejected a complex
fixture-generation expression in the benchmark driver. There were no timings.
The fixture setup was simplified before the successful cohort; production
source and expected behavior did not change.

The two-line production indexing change, regression tests, benchmark driver
and runner are byte-identical to the successfully measured commit. Later
changes only retain evidence/documentation and remove the temporary
research-branch push trigger.
