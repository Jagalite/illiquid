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

## Reproduce

Baseline: ea2ff568237e2667f7b1aeee67b11a44ebe95b72. The runner reads
complete baseline sources with git show; fetch this commit before using a
shallow checkout. It copies complete candidate sources from the current
checkout, records all SHA-256 hashes and the checkout status, and preserves the
source snapshots with the evidence.

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
samples, calibration and full output receipts as an artifact. A compact
evidence summary will be recorded after native qualification completes.

## Interpretation

Results describe this small scheduling component. They do not establish a
change in thumbnail decoding speed or total background generation time.
Removing Array(prefix) expressions does not prove that every former prefix
always physically copied its elements; Swift can share some array storage.
No allocation counts are claimed without an allocation measurement.
