# Thumbnail refinement scheduling

This experiment measures construction of the background thumbnail refinement
schedule. It does not measure decoding, disk access, rendering, or whole-player
performance.

## Change

The scheduler visits each video's remaining thumbnail samples in bounded
groups. The previous implementation first materialized an array of bounded
plans, then an array of their lengths, and grew the combined result as it
appended. The candidate traverses bounded views of the original plans, computes
the exact output count (at most 4,096), and reserves the output once.

It preserves the first 64 videos, first 64 samples per video, visit clamp
1...8, video indices, visit ordering and exact Double values. No slices escape
the function; the result remains an independent array of value tuples.

## Portable results

[Qualification run 40640070827](https://github.com/Jagalite/illiquid/actions/runs/40640070827/job/122655908622)
passed on Linux x86_64 with Swift 6.2.1, using four vCPUs on an AMD EPYC 9V45
host. Qualified source commit:
[dc34d5c8eee8fcb55cc2e20bf3985f36bb83fd4d](https://github.com/Jagalite/illiquid/commit/dc34d5c8eee8fcb55cc2e20bf3985f36bb83fd4d).

These are medians per complete schedule construction, including result
allocation/destruction and the small checksum consumption cost. Percentages
compare the two variant medians; paired reductions and all raw observations
are recorded separately.

| Workload | Plans × remaining samples | Baseline µs | Candidate µs | Lower median time |
|---|---:|---:|---:|---:|
| Economical | 4 × 5 | 0.476 | 0.147 | 69.0% |
| Balanced / default | 8 × 11 | 0.993 | 0.385 | 61.3% |
| Extensive | 16 × 23 | 2.647 | 1.391 | 47.5% |
| Maximum bounded settings | 64 × 63 | 20.019 | 14.193 | 29.1% |

The candidate was faster in all ten pairs for every one of the 20 workloads:
200 pairs / 400 timing samples. Normal preset savings are approximately
0.33, 0.61 and 1.26 microseconds per pass; maximum bounded settings saved about
5.83 microseconds. This is a small planning optimization, not a demonstrated
change in decoding or total thumbnail generation time.

All 19 tests in three suites passed against both baseline and candidate in
debug and release. The 320 complete preflight schedules matched, and every
timing pair matched full output receipts, work counts, timed checksums and
warm-up checksums. Additional regressions cover all visit sizes 1...8, both
64-element boundaries, random ragged plans and exact floating-point bits.

No timing samples were discarded. Actual samples lasted 47.1–1520.2 ms.
The ten samples below 100 ms were the candidate's all-empty-plan control;
its much slower baseline caused the common iteration count to be limited
by the 1500 ms calibration bound. The four preset/bounded workload pairs
above all lasted at least 105.8 ms. Timing bounds are calibration targets,
not hard runtime guarantees.

The macOS job was still queued when these results were recorded. These
portable measurements do not qualify macOS performance or the macOS app
build, playback, UI, energy consumption or allocation counts.

### Evidence

- [Environment, source hashes and toolchain](evidence/linux-x86_64/manifest.json)
- [Complete 20-case summary](evidence/linux-x86_64/summary.json)
- [All 400 raw timing samples](evidence/linux-x86_64/measurements.jsonl)
- [Pilot and calibration samples](evidence/linux-x86_64/calibration.jsonl)
- [Test results](evidence/linux-x86_64/test-summary.json)
- [Full-output parity receipt](evidence/linux-x86_64/parity.json)
- [Pair verification](evidence/linux-x86_64/verification.json)
- [Full source snapshots, commands, test logs and output receipts](https://github.com/Jagalite/illiquid/actions/runs/40640070827/artifacts/12794979920)
  are retained in the workflow artifact for 14 days. The compact evidence
  above is committed with this report.

## Reproduce

Baseline: ea2ff568237e2667f7b1aeee67b11a44ebe95b72. The runner reads
complete baseline sources with git show; fetch this commit before using a
shallow checkout. It copies complete candidate sources from the current
checkout, records all SHA-256 hashes and the checkout status, and preserves the
source snapshots with the workflow artifact.

On a machine with the shared Kyoto queue, follow the repository AGENTS.md:

    python3 /Volumes/seed1/Projects/kyoto/kyoto.py submit -- \
      python3 Benchmarks/ThumbnailRefinement/run.py \
      --output /tmp/thumbnail-refinement-run

Inspect that job's show, logs and wait results before reporting completion.
When Kyoto is unavailable, explain that limitation before the direct command:

    python3 Benchmarks/ThumbnailRefinement/run.py \
      --pairs 10 --target-ms 150 --max-sample-ms 1500 \
      --output /tmp/thumbnail-refinement-run

Use an empty output directory. The hosted workflow checks Kyoto availability
before running serial builds in its isolated checkout.

## Validation and timing method

- Build the real policy, cursor and visibility sources in isolated Swift
  packages. Run the existing policy and scheduling tests plus the new
  refinement regressions on baseline and candidate, in debug and release.
- Compare complete outputs against an independent coordinate-sorting oracle.
  Tests cover both 64-element caps, empty and ragged inputs, all visit sizes,
  extreme visit requests, signed zero, infinities, NaN payloads, and value
  independence.
- Compile complete production source as a separate optimized IlliquidCore
  module. The separately linked driver calls the public, non-inlinable
  refinementOrder function.
- Construct 16 input variants per workload before timing. Include empty inputs,
  small and maximum schedules, uneven plans, over-limit requests and visit-one
  and visit-eight controls.
- Warm up each process; calibrate common work counts against the faster
  variant. Run ten fresh-process pairs, five AB and five BA, with deterministic
  per-pair seeds. Keep all samples.
- Time one whole schedule construction per operation, including output
  allocation/destruction and a constant-size checksum of its count and
  first/middle/last tuples. Full output verification is outside timing.
- Require complete output receipts, operation counts and checksums to match
  between paired processes. Timing does not have a noisy percentage CI gate.

The scheduler generates the first image before refinement. Full successful
preset workloads are therefore 4 x 5 (economical), 8 x 11 (balanced/default),
16 x 23 (extensive), and 64 x 63 at maximum bounded settings. Actual passes can
be shorter or ragged because short videos or failed probes yield fewer samples.

The workflow runs separate macOS and Linux jobs; their toolchains and results
are recorded independently. Portable results do not qualify macOS performance.

The workflow retains complete source snapshots, test logs, commands, raw
samples, calibration and full output receipts as an artifact. Recorded
portable results and their qualification limits are listed above.

## Interpretation

Results describe this small scheduling component. They do not establish a
change in thumbnail decoding speed or total background generation time.
Removing Array(prefix) expressions does not prove that every former prefix
always physically copied its elements; Swift can share some array storage.
No allocation counts are claimed without an allocation measurement.
