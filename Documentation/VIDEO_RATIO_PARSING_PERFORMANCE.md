# Video aspect/crop ratio parsing research

## Status and decision

**2026-10-28: portable parser improvement demonstrated; native qualification pending.** The
revised ASCII/UTF-8 candidate reduced median parser CPU time by 52.6–59.8% on the
non-nil workloads. The first Character-based candidate was rejected because colon
forms became approximately 60% slower. Keep the PR in draft until the native
geometry and test gate completes; application-level benefits remain unmeasured.

| Role | Exact revision |
| --- | --- |
| Original production baseline | `ea2ff568237e2667f7b1aeee67b11a44ebe95b72` |
| Measured, rejected Character candidate | `4b01cf199405d168ad626563957714cc35b0581c` |
| Revised ASCII candidate, portable-qualified | `244014d4008c5bdbd8eb4b9270434d752a78dd2d` |

The rejected run's [receipt](../Benchmarks/VideoRatioParsingPortable/evidence/character-scan/receipt.json)
records the measured revision, a clean checkout, full source hashes, exact function
hashes, generated wrapper hashes, and the benchmark inputs. The corresponding
[ASCII receipt](../Benchmarks/VideoRatioParsingPortable/evidence/ascii-scan/receipt.json)
provides the same provenance for the selected revision. Archive paths appear below.

## Why this path

[`VideoPresentationGeometry.ratio`](../Sources/IlliquidCore/Player/VideoPresentationGeometry.swift)
parses optional scalar or colon-form aspect/crop overrides. The geometry initializer
calls it for both settings. [`MediaSession.renderSubtitles`](../Sources/IlliquidNativePlayback/Media/MediaSession.swift)
constructs this geometry when rendering subtitles, and
[`PiPSubtitleCompositor.compose`](../Sources/IlliquidNativePlayback/Presentation/PiPSubtitleCompositor.swift)
calls the parser twice directly before constructing geometry, which calls it twice
again. This means two substantive parses with one nonnil override, or four with
both, per composition attempt. Frame coalescing, refreshes, and retries mean this
is not an exact count per decoded or displayed frame. The native runtime can use
this compositor for aspect/crop overrides even when subtitles are absent. Native
view layout and screenshot composition also use the same geometry.
These call sites make repeated parsing worth investigating; they do not quantify
its share of application CPU time.

The baseline uses `String.split` to construct a temporary array of substring
fields. The proposed change targets that intermediate storage while preserving
Swift's `Double` grammar, positive finite operands, division order, optional
failure, and the inclusive permitted ratio range `0.1...10`. Nil settings already
return before splitting, so default playback is an explicit control.

The rejected version used Character-based colon searches and borrowed fields.
The revision checks for ASCII and searches the UTF-8 view for delimiter bytes;
non-ASCII text retains the original Character-based split. This fallback preserves
grapheme semantics, including a colon followed by a combining mark. The revised
ASCII path avoids the explicit split-result array. The fallback still constructs
that array, and this study has no measured heap-allocation or RSS counters.

## Revised ASCII candidate: actual portable results

[Run 40641875650](https://github.com/Jagalite/illiquid/actions/runs/40641875650) used
the same Swift 6.2.4 Linux target and timing protocol. Its retained
[summary](../Benchmarks/VideoRatioParsingPortable/evidence/ascii-scan/summary.json)
reports the following medians of six observations per implementation:

| Scenario | Baseline CPU ns/call | ASCII CPU ns/call | CPU-time change | Wall ns/call, baseline → candidate |
| --- | ---: | ---: | ---: | ---: |
| Nil control | 10.10 | 9.74 | Control; no intended benefit | 10.10 → 9.74 |
| Scalar | 300.59 | 120.88 | −59.79% | 300.61 → 120.89 |
| Colon | 383.67 | 181.80 | −52.62% | 383.70 → 181.81 |
| Invalid | 233.46 | 109.96 | −52.90% | 233.48 → 109.97 |

CPU ranges, baseline → candidate, were 299.61–308.33 → 120.52–121.99 ns for scalar,
380.86–386.25 → 180.71–182.56 ns for colon, and 232.67–234.91 → 109.39–111.13 ns for
invalid input. The shortest CPU/wall windows were 158.50/158.55 ms. Interpret each
candidate against its own paired baseline; the two runs have different absolute
baseline timings. The nil difference is retained as a control, without attributing
it to removal of an array that the nil branch never constructed.

The candidate function SHA-256 is
`aa5db532a525e0be03b40ed58d56948dfc6a2c2de5effd6b6026a4f6e31e27de`;
the complete production file hash is recorded in the linked receipt. These results
support retaining the ASCII candidate for native review. **Native geometry/test
results remain pending.** No heap, RSS, energy, frame-rate, or whole-player saving
was measured, and Linux parser results cannot establish macOS geometry performance.

## Experimental controls

The [portable runner](../Benchmarks/VideoRatioParsingPortable/run.py) verifies the
complete baseline file against the native study's pinned SHA-256 manifest and
requires all source outside the ratio declaration to remain byte-identical. It
extracts the exact declaration into a Foundation-only public enum wrapper. It
does not emulate CoreGraphics or compile the geometry initializer.

Fixtures, the complete parser corpus, authored parser expectations, and the ratio
loop are guarded, verbatim excerpts from the
[native driver](../Benchmarks/VideoRatioParsing/Driver.swift). Receipts retain full
hashes of declarations, excerpts, wrappers, and binaries; the CI artifact retains
source snapshots and per-command stdout/stderr.
The parser library and driver are separate optimized Swift compilations, without
cross-module optimization. Inputs and output checksums cross that module boundary.

Each scenario rotates 32 prepared inputs. Fixture construction and warm-up occur
outside timing; each optional result's exact bits contribute to a checksum. Both
variants calibrate to a 150 ms target in both wall and process CPU time, then use
the larger iteration count. Six fresh-process pairs alternate AB/BA order, with
equal counts and matching checksums. Every observation must exceed 60 ms in both
clocks. Results are normalized per parser call, with no performance pass threshold.

## Rejected Character candidate: actual results

The retained [summary](../Benchmarks/VideoRatioParsingPortable/evidence/character-scan/summary.json)
was produced with Swift 6.2.4 targeting `x86_64-unknown-linux-gnu`, on the Ubuntu
workflow's pinned Swift 6.2.4 Noble container. The
[environment receipt](../Benchmarks/VideoRatioParsingPortable/evidence/character-scan/environment.json)
records the Linux kernel and toolchain. These are portable parser measurements.

| Scenario | Baseline CPU ns/call | Character CPU ns/call | CPU-time change | Wall ns/call, baseline → candidate |
| --- | ---: | ---: | ---: | ---: |
| Nil control | 12.46 | 12.46 | +0.02% | 12.46 → 12.47 |
| Scalar | 333.21 | 250.55 | −24.81% | 333.30 → 250.58 |
| Colon | 426.71 | 681.84 | **+59.79%** | 426.79 → 681.87 |
| Invalid | 255.24 | 213.70 | −16.27% | 255.28 → 213.82 |

Each value is the median of six observations. Colon CPU ranges were
423.22–428.00 ns/call for the baseline and 670.03–688.09 ns/call for the candidate.
All 48 observations were retained; the shortest CPU and wall windows were
158.53 ms. The [raw measurements](../Benchmarks/VideoRatioParsingPortable/evidence/character-scan/measurements.jsonl)
and command outputs support recomputation of the table.

The scalar improvement does not justify slowing common `16:9`/`4:3` forms. This
candidate was rejected on its measured colon regression. The evidence does not
identify the exact compiler/runtime cause of the slowdown; fewer explicit
temporary containers alone did not guarantee faster execution.

## Correctness and remaining qualification

The rejected run compared 700 parser inputs bit for bit, passed 18 authored
expected-value checks in each variant, and produced matching timed checksums.
Its [verification receipt](../Benchmarks/VideoRatioParsingPortable/evidence/character-scan/verification.json)
explicitly records that geometry and repository test suites were not run.

The revised corpus contains **2,748 parser rows**: the original 700 plus 2,048
seeded mixed strings using the unit test's exact tokens, seed, and generator.
Coverage includes decimal/exponent/hex spellings, empty or extra fields, NULs,
CRLF, Unicode digits, combining marks, glyphs, ordinary-input truncations, extreme
operands, and values immediately around the permitted floating-point boundaries.
The added strings affect verification only; timed fixtures and loops are unchanged.
The revised [verification](../Benchmarks/VideoRatioParsingPortable/evidence/ascii-scan/verification.json)
confirms all 2,748 exact-bit matches and 18 authored checks per variant. Its
[completion receipt](../Benchmarks/VideoRatioParsingPortable/evidence/ascii-scan/completion.json)
confirms all 48 observations and source/generated-artifact/binary stability checks.

The [native runner](../Benchmarks/VideoRatioParsing/run.py) compiles complete,
unmodified production source files with real CoreGraphics, including all required
model dependencies. Support files must match the pinned baseline. It runs the
actual `VideoRatioParsingTests` and `PlaybackToolsTests` in debug and release for
both variants, and compares every image/clip rectangle coordinate by bit pattern.
Its nine scenarios include parser controls and complete geometry with default,
aspect-only, crop-only, combined, and invalid settings. Fit/fill and invalid or
extreme dimensions are part of correctness coverage.

**Pending native gate:** record macOS/Xcode environment, four test configurations,
full coordinate parity, all paired observations, and completion status. Current runs are listed in the
[native research workflow](https://github.com/Jagalite/illiquid/actions/workflows/video-ratio-parsing.yml).
This focused gate does not establish whole-app compilation, live presentation,
frame rate, or end-to-end playback performance.

## Reproduction and evidence

Fetch the baseline commit, check out the candidate being investigated, and use new
output directories. Follow the repository's Kyoto build coordination when that
queue is available; both runners support `--inside-kyoto` for a queued invocation.

```sh
python3 Benchmarks/VideoRatioParsingPortable/run.py \
  --pairs 6 --target-ms 150 --minimum-ms 60 --output /tmp/ratio-portable
python3 Benchmarks/VideoRatioParsing/run.py \
  --pairs 6 --target-ms 150 --minimum-ms 60 --output /tmp/ratio-native
```

The second command requires native macOS/CoreGraphics. `--prepare-only` on either
runner validates/stages sources without claiming compilation or execution.
Portable receipts, exact traces, raw measurements, command indexes, and summaries
are retained under `Benchmarks/VideoRatioParsingPortable/evidence/character-scan/`
and `Benchmarks/VideoRatioParsingPortable/evidence/ascii-scan/`. Each directory
includes a `provenance.json` with CI run/artifact links, the log-bundle checksum,
and checksums for every retained raw file. Per-command stdout/stderr and source
snapshots remain in the linked CI artifacts (14-day retention); the measured
source/harness revisions and committed raw data support later reproduction.
The rejected study is retained alongside the favorable result.

The frozen-baseline workflows run on this study's performance branches or manual
dispatch. They do not gate unrelated future PRs: intentional changes to the pinned
production sources need a reviewed rebaseline before repeating this experiment.
