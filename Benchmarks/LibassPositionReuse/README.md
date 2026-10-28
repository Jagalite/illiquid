# Libass position-only mask reuse

Libass distinguishes changed positions (1) from changed content (2). The
production renderer already skips bitmap copies for unchanged output (0), but
previously copied every admitted mask for both kinds of changed output. This
experiment reuses Swift-owned masks for position-only changes while rebuilding
their current geometry.

The contract is documented in [libass 0.17.5 ass.h](https://github.com/libass/libass/blob/0.17.5/libass/ass.h).
Its [change detector](https://github.com/libass/libass/blob/0.17.5/libass/ass_render.c)
compares the ordered image list, bitmap pointers, dimensions, stride and color;
position-only changes preserve those properties.

## Measured result and qualification

The Linux component experiment succeeded on 2026-10-28. In the dense moving
fixture, median render time fell from 1.428 ms to 0.331 ms per frame, with a
76.847% median paired reduction and all eight pairs faster. After warmup,
42 mask copies and 6,038,444 copied bytes per frame were avoided. The two
nonmoving controls became slightly slower.

**Native macOS qualification remains pending.** The
[native component and application integration run](https://github.com/Jagalite/illiquid/actions/runs/40643162809)
was still queued when this report was written. Keep the PR in draft until
the exact native production sources and application integration pass.
The results below are Linux measurements; they do not predict Apple-platform
percentages or qualify the player.

### Complete Linux results

| Workload | Baseline median µs/frame | Candidate median µs/frame | Median paired reduction | Full paired range | Candidate faster |
|---|---:|---:|---:|---:|---:|
| Moving caption, 1080p | 19.592 | 16.466 | 15.948% | 14.128% to 18.308% | 8/8 |
| 14 moving lines, 4K | 1,427.610 | 331.093 | 76.847% | 76.172% to 77.409% | 8/8 |
| 4K, eight-image limit | 538.774 | 331.106 | 38.741% | 36.360% to 41.250% | 8/8 |
| Fractional motion | 20.007 | 16.919 | 15.461% | 6.100% to 18.008% | 8/8 |
| Static dense control | 325.998 | 329.556 | -1.348% | -14.347% to 0.676% | 2/8 |
| Changing-text control | 16.325 | 16.450 | -1.577% | -3.070% to 4.904% | 2/8 |

Positive reduction means less time. Each percentage is calculated within its
matched pair before taking the median; it need not equal the ratio of the two
independently reported timing medians. All measured samples, including adverse
ones, are retained. Samples lasted 95.9–461.3 ms; the 100 ms target was a
calibration target, not a postmeasurement exclusion rule.

The static control was slower in six of eight pairs, with a worst pair of
14.347% more wall time. That pair also used more CPU time, so it is not dismissed
as scheduling noise. The changing-text control was slower in six of eight
pairs. Their median paired regressions were 1.348% and 1.577%, respectively.
These controls record the observed overhead where mask reuse cannot help;
this single campaign does not isolate bookkeeping cost from timing noise.

| Workload | Copied mask bytes/frame, baseline → candidate | Bitmap copies/frame, baseline → candidate |
|---|---:|---:|
| Moving caption, 1080p | 85,008.000 → 0.000 | 3.000 → 0.000 |
| 14 moving lines, 4K | 6,038,444.000 → 0.000 | 42.000 → 0.000 |
| 4K, eight-image limit | 1,139,750.000 → 0.000 | 8.000 → 0.000 |
| Fractional motion | 85,035.563 → 3,986.063 | 3.000 → 0.141 |
| Static dense control | 0.000 → 0.000 | 0.000 → 0.000 |
| Changing-text control | 63,139.125 → 63,139.125 | 3.000 → 3.000 |

These copy counts cover the warmed timed phase. Initial rendering still copies
the masks. The fractional fixture reported position-only changes on 61/64
timed frames and content changes on 3/64; content-change frames still copied
their masks. Static output already avoided copies in the baseline.

### Evidence and environment

- [Successful Linux run](https://github.com/Jagalite/illiquid/actions/runs/40643811579),
  tested commit `7e1a0ddf53e3bd1da482d5254794ca93c042de7b`.
- Baseline: `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`.
- x86_64 Linux, Intel Xeon Platinum 8573C, Swift 6.3.3; official
  `swift:6.3.3-noble` image, resolved image digest
  `swift@sha256:1038d54c80063f5cdfabc4560990c30af64b5de8ebf28161deb22ca4ad5db866`.
- Real libass 0.17.5, built from the repository's verified source archive with
  GCC 13.3.0 and `-O2`. Fontconfig resolved Arial to Liberation Sans.
  Font, native library, source, compiler, package and executable receipts are
  recorded in the [manifest](Results/linux-x86_64-20261028/manifest.json).
- **24 tests in three suites passed in debug and again in release.**
  These comprise the existing compact-copy tests in both variants and
  12 candidate reuse tests. Exact observed summary lines are retained in
  [test output](Results/linux-x86_64-20261028/test-output.txt).
- **96 measured process runs, 48 pairs, 308,224 timed frames**, plus
  24 separately retained calibration runs. Each measured process passed its
  independent 71-query full-copy oracle sweep.
- All pairs matched fixture hashes, complete verification digests, final visual
  hashes, warmup/timed checksums, geometry, admitted byte counts, native change
  classifications, seeds, iteration counts and frame counts. Pair order
  alternated baseline/candidate and candidate/baseline.

The retained [raw measurements](Results/linux-x86_64-20261028/measurements.jsonl),
[calibration](Results/linux-x86_64-20261028/calibration.jsonl),
[summary](Results/linux-x86_64-20261028/summary.json),
[test receipt](Results/linux-x86_64-20261028/tests.json),
[qualification](Results/linux-x86_64-20261028/qualification.json) and
[command receipts](Results/linux-x86_64-20261028/commands.jsonl) allow independent review.
The [container receipt](Results/linux-x86_64-20261028/container-image.json),
[generated package](Results/linux-x86_64-20261028/portable-Package.swift) and
[resolved packages](Results/linux-x86_64-20261028/Package.resolved) preserve the portable build.
Full build/test logs are also in the
[CI artifact](https://github.com/Jagalite/illiquid/actions/runs/40643811579/artifacts/12796622906);
that artifact has a 14-day retention period.

The [qualification-attempt record](Results/qualification-attempts.json) describes
earlier harness failures and superseded runs. They produced no measurements
used in this report. Production code and measured driver did not change while
the test harness and receipt parsing were repaired.

## Ownership and invalidation

An opaque immutable snapshot belongs to the caller. It carries its owned regions,
a per-context identity, a render sequence, and the admission limits. Reuse
requires the immediately preceding render, matching limits and every admitted
region's layout and color. A stale, missing, foreign or incompatible snapshot
uses the existing full-copy path. Source replacement, reset, actual geometry
changes and invalid render requests retire the previous token.

The context stores only token metadata. A snapshot does not retain the context,
native ASS_Image pointers, or libass caches. SubtitlePipeline shares its existing
region-array storage with the cached snapshot and clears both together.
Unchanged native renders retag a valid snapshot; viewport translation preserves
mask identity and always uses the new native frame coordinates on a later move.

Image-count and bitmap-byte admission remain deterministic. The full native
list is validated before any copies or mask sharing. The byte accounting still
describes the complete admitted output; bitmapCopies counts actual copies.

## Reproduce on macOS

Requires macOS, Swift 6.1+, Python 3.10+, and libass. The CI workflow installs the
repository's checksum-verified native SDK, including libass 0.17.5. On a local
host, supply a compatible installation with --libass-prefix if needed, and
follow the root AGENTS.md Kyoto build-coordination instructions.

    python3 Benchmarks/LibassPositionReuse/run.py --mode all \
      --pairs 8 --target-ms 100 --max-sample-ms 1500 \
      --output /tmp/illiquid-libass-position-reuse

Use a new empty output directory for every attempt. --mode tests runs regression
tests only; --mode measure runs the paired experiment only.

The baseline is the exact complete production sources at main commit
ea2ff568237e2667f7b1aeee67b11a44ebe95b72. Both variants compile LibassContext,
ASSBitmapCopy, SubtitleMemoryBudget and FontAttachmentStore without changes.
The exact PresentationError declaration is extracted with checked boundaries;
only its Foundation import is supplied. Real CoreGraphics, CryptoKit, Data,
locks and libass are used. There are no behavioral substitutes.

Production code is built as a separate optimized module with -O and
-whole-module-optimization. The driver accesses its existing internal API through
@testable import. The same driver source is compiled for both variants;
POSITION_REUSE only supplies and retains the candidate's snapshot.

## Workloads and verification

Six 64-frame workloads cover a short moving caption at 1080p, fourteen moving
lines at 4K, the same dense scene with an eight-image admission limit, static
dense text, changing text, and fractional motion. The integer-motion fixtures
deliberately isolate position-only updates. The fractional control records the
actual mixture of native change classifications.

Before timing, every complete output is compared with a separate full-copy
libass context: all mask bytes, colors, frames, strides and layout metadata.
Verification includes repeated timestamps, backward queries and expired events.
Paired runs must also match input hashes, complete verification digests,
warmup and timed checksums, final full-output digests, native change counts and
admitted byte counts. Copy counts are expected to differ.

Each timed process warms one full sweep, then renders repeated sweeps. Eight
fresh-process pairs alternate baseline/candidate order with identical iteration
counts and fixture seeds. Calibration targets 100 ms for the faster variant,
capping estimated slow-variant samples at 1.5 seconds; actual durations are
retained. No samples are discarded or control times subtracted.

Primary timing covers the full production render call and identical driver
output consumption, including candidate validation and ownership overhead.
Process CPU time is also recorded. The internal copyNanoseconds diagnostic
excludes the preceding admission/validation pass and must not be treated as
the complete speedup.

For the standalone test packages, exact CPU frame-packer declarations are also
extracted from MetalASSSubtitleCompositor with checked boundaries and source
hashes. Native tests use the real CoreGraphics and Synchronization frameworks.

Existing compact-copy regressions run against both implementations in debug
and release. Candidate tests cover position/content/empty output, unchanged
retagging, stale/foreign/missing tokens, admission changes, reset/reload/geometry,
viewport offsets and caller-owned payload lifetime. A separate native job builds
the app graph and runs subtitle lifetime, staging and seek integration tests.

## Reproduce the Linux experiment

The [portable workflow](../../.github/workflows/libass-position-reuse-portable.yml)
defines the complete container setup, native dependencies and font installation.
Use the recorded image digest above to reproduce this run. With those
dependencies installed, run:

    python3 Benchmarks/LibassPositionReuse/portable.py \
      --pairs 8 --target-ms 100 --max-sample-ms 1500 --jobs 2 \
      --output /tmp/illiquid-libass-position-reuse-linux

The adapter shares the native runner's source extraction, driver, parity
checks and summarization. Production Swift bodies are unchanged. It replaces
CoreGraphics imports with Foundation geometry, CryptoKit imports with pinned
official Swift Crypto 3.12.3, and testable module names with the corresponding
baseline/candidate module. Original and adapted hashes and exact import edits
are retained. Both modules and drivers use SwiftPM release optimization; only
the candidate driver defines POSITION_REUSE. No app dependency is added.

This standalone package does not compile SubtitlePipeline. Native application
integration, Apple's framework implementations and the CoreText font provider
must be checked by the separate macOS workflow.

## Interpretation

The evidence supports avoiding mask-copy work on libass position-only updates
in these warm component workloads. The small and fractional fixtures improve
by about 15–16%; the dense case benefits most because it previously copied
roughly 6.04 MB each frame. Benefit depends on libass's actual change
classification and the admitted mask size. Content changes still take the
existing copy path, and the control regressions remain part of the result.

This is one environment and one eight-pair campaign, not a cross-machine
confidence interval. It does not measure live playback occupancy, GPU work,
compositing, frame rate, whole-player CPU, resident memory or energy.
Downstream geometry, packing and presentation still happen. Do not interpret
fewer bitmap copies as fewer GPU uploads, or these Linux timings as a macOS
performance claim.
