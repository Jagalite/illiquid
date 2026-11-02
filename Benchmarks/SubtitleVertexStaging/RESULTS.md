# Subtitle vertex staging research

## Outcome and qualification status

The direct writer passed portable correctness and address-safety checks and
reduced CPU time in the portable vertex-staging proxy by **64.9–83.4%**
across the ten tested workloads. It was faster in all **80 paired comparisons**.
The change also removes the explicit temporary vertex array and bulk copy.

These are **Linux CPU-proxy results**. Native Metal speed, GPU output and
native integration have not yet been qualified. At the last check,
**2026-10-28 05:50:50 UTC**, both jobs in the
[native qualification run](https://github.com/Jagalite/illiquid/actions/runs/40636242253)
were still queued. Keep the proposed change in draft until the native
component benchmark corroborates the benefit and the rendered regressions pass.

| Qualification | Observed result |
| --- | --- |
| Portable baseline and candidate upload adapters, debug and release | Passed all 40 driver case executions |
| Portable writer tests, debug and release | Passed 4 Swift Testing functions per configuration; one function has 4 argument cases |
| Portable writer tests with AddressSanitizer | Passed the same 4 functions; address/bounds checks, leak detection disabled |
| Portable paired CPU measurements | Passed receipt checks for all 160 observations / 80 pairs |
| Native Metal component tests and CPU benchmark | Queued at the timestamp above; no result claimed |
| Native app-graph build and rendered regressions | Queued at the timestamp above; no result claimed |
| Live player, optional animated-media fixture, whole-player CPU/RSS | Not qualified by this experiment |

## Problem and change

The main ASS Metal renderer constructed a temporary Swift array containing
six vertices per quad, then copied that storage into its pooled shared
Metal buffer. Both the temporary array and the pooled buffer existed during
the upload. The candidate writes the same vertex fields directly into the
checked-out buffer and calculates frame-constant offsets and texture
dimensions once per upload.

The production change preserves vertex attribute offsets and stride,
coordinate arithmetic, color conversion, triangle order, quad order, buffer
growth, allocation-failure accounting and the resource pool's GPU completion
lifetime. A compiler-checked `BitwiseCopyable` vertex type expresses the raw
store requirement. The renderer supplies the actual pooled texture dimensions,
which can exceed the current frame's atlas size, and draws exactly the newly
written vertex count.

## Portable CPU results

[Successful workflow run](https://github.com/Jagalite/illiquid/actions/runs/40639765431)
on Ubuntu **24.04.5**, runner image `ubuntu-24.04 / 20261012.334.1`,
Linux x86_64, Swift **6.4**, collected 2026-10-28.
The timing manifest records the kernel and architecture; a CPU model was not
captured. Baseline and candidate use the same host and compiler.

| Workload | Baseline median (µs/upload) | Candidate median (µs/upload) | Median paired reduction | Paired range | Faster pairs |
| --- | ---: | ---: | ---: | ---: | ---: |
| quads-1-edges | 0.105 | 0.036 | 64.9% | 61.7% to 69.0% | 8/8 |
| quads-1-centers | 0.101 | 0.035 | 65.3% | 62.5% to 70.4% | 8/8 |
| quads-8-edges | 0.323 | 0.067 | 79.4% | 78.2% to 81.1% | 8/8 |
| quads-8-centers | 0.318 | 0.065 | 79.2% | 75.8% to 81.2% | 8/8 |
| quads-64-edges | 2.010 | 0.350 | 82.6% | 81.8% to 83.9% | 8/8 |
| quads-64-centers | 2.051 | 0.350 | 83.0% | 81.8% to 83.8% | 8/8 |
| quads-256-edges | 7.870 | 1.332 | 83.4% | 82.8% to 83.9% | 8/8 |
| quads-256-centers | 7.780 | 1.333 | 82.9% | 82.2% to 83.4% | 8/8 |
| varying-edges | 1.785 | 0.311 | 82.6% | 82.0% to 83.2% | 8/8 |
| varying-centers | 1.841 | 0.318 | 82.5% | 82.4% to 83.3% | 8/8 |

Times are medians per CPU upload. Percentage reductions are the median of the
eight paired percentage changes, so they need not equal the percentage
computed from the two separately reported time medians.

`edges` uses the production rectangle-edge texture-coordinate mode.
`centers` uses texel centers with a diagnostic -0.5-pixel offset.
The varying sequence contains 1, 8, 64, 256, 8 and 1 quads. The varying result
is average CPU time per upload across that sequence.

### Method and limits

The original production upload methods and the candidate methods are
extracted without editing their bodies, compiled in separate Swift modules,
and called by the same driver. Import-only Swift changes supply Foundation
geometry on Linux. A small, explicitly named proxy provides raw-memory
buffers and plain Swift texture dimensions in place of Metal objects.

Fixtures, device/texture stand-ins, initial buffer growth and warmup are
outside timing. Each timed upload includes an equal final-vertex read for a
consumed checksum. Eight fresh-process pairs alternate execution order for
each workload. Every pair uses identical seeds and iteration counts. Actual
sample durations were **76.672–511.958 ms**. No observations were discarded,
and no control time was subtracted.

The driver checks every logical vertex field against a corner-based oracle
before and after timing, including exact Float bit patterns and RGBA values.
The paired runner compares receipt hashes, capacity, stride, checksum and
workload metadata. The recorded observations were independently recomputed:
all reported medians, paired reductions and alternating orders agree with
the raw data.

The measured path includes vertex construction, the array/copy or direct
stores, property access, frame-constant calculations and the equal checksum
read. The result does not isolate memcpy. Plain Swift property getters and a
raw allocator have different costs from Metal APIs. These percentages must
not be presented as native Metal or whole-player performance gains.

## Memory accounting

The portable layout assertions confirmed 20 bytes of fields and a 24-byte
stride. The array element storage and explicit copy removed are each
`6 × quadCount × MemoryLayout<Vertex>.stride` bytes:

| Quads | Temporary array element storage removed | Explicit copy removed per upload |
| ---: | ---: | ---: |
| 1 | 144 bytes | 144 bytes |
| 8 | 1,152 bytes | 1,152 bytes |
| 64 | 9,216 bytes | 9,216 bytes |
| 256 | 36,864 bytes (36 KiB) | 36,864 bytes (36 KiB) |

These are source-level payload calculations, excluding array metadata,
allocator overhead and compiler-dependent optimization of small array
literals. They are not measured malloc counts or RSS. The existing shared
Metal buffer keeps its previous capacity policy. The writer retains no
additional CPU staging buffer. The queued native tests also assert the
required vertex layout.

## Correctness and native follow-up

The executed portable tests cover exact Float bits and RGBA values across
both texture-coordinate modes, positive/negative offsets, differing target
sizes, both composition strategies, alpha extremes, oversized pooled texture
dimensions and empty frames. Aligned guard bytes and repeated
larger/smaller/empty writes check that unused storage stays untouched. Struct
padding is excluded from field comparisons. AddressSanitizer passed with
`detect_leaks=0`; this qualifies address/bounds safety, not leak freedom.

The native regression added to `MetalASSSubtitleCompositorTests` uses one
renderer for 64, 1, 0, 128, 2 and 64 quads. It requires every image to match
the existing independent CPU reference exactly. This is intended to exercise
growth beyond the initial 4 KiB buffer, reduced draw counts, oversized pooled
textures, empty clears and changed colors. It has **not yet executed** in the
queued native job.

That offscreen test checks synchronous reuse. The existing asynchronous
completion path is preserved by the production diff; the portable proxy
does not test GPU synchronization. The existing optional animated fixture
test requires environment variables and media fixtures not supplied by this
workflow, so a later green suite must not be interpreted as running that
optional workload.

## Source identity and durable evidence

- Frozen baseline: main commit
  [ea2ff568237e2667f7b1aeee67b11a44ebe95b72](https://github.com/Jagalite/illiquid/commit/ea2ff568237e2667f7b1aeee67b11a44ebe95b72).
- Successful portable tested commit:
  [92f99f87e4c18e6a0c8aa0d08633355f45f72e68](https://github.com/Jagalite/illiquid/commit/92f99f87e4c18e6a0c8aa0d08633355f45f72e68),
  with a clean checkout.
- Exact portable workflow:
  [qualified configuration](https://github.com/Jagalite/illiquid/blob/92f99f87e4c18e6a0c8aa0d08633355f45f72e68/.github/workflows/subtitle-vertex-staging-portable.yml).
- Native queued source commit:
  [4affb30ff575bd77a05ff8eec408c2d8c9a70b77](https://github.com/Jagalite/illiquid/commit/4affb30ff575bd77a05ff8eec408c2d8c9a70b77),
  with the
  [exact native workflow](https://github.com/Jagalite/illiquid/blob/4affb30ff575bd77a05ff8eec408c2d8c9a70b77/.github/workflows/subtitle-vertex-staging.yml).
- The portable commit adds only companion benchmark files and a workflow.
  Production code and both regression-test files are identical to the native
  queued source. Later evidence/documentation commits do not change those
  source inputs.

The [committed evidence directory](../SubtitleVertexStagingPortable/evidence/2026-10-28)
contains all 21 emitted evidence files, including every raw timing observation,
calibration, source extraction, source and binary hashes, commands, manifests
and test logs. [The evidence index](../SubtitleVertexStagingPortable/evidence/2026-10-28/index.json)
records content hashes and CI identity. The implementation and test source
hashes were checked against the reviewed files, and the recorded extracted
sources were also checked against those files after documented import changes.

Full decoded vertex receipts are included in the
[CI artifact](https://github.com/Jagalite/illiquid/actions/runs/40639765431/artifacts/12794079965)
with 14-day retention. The committed raw timing rows retain their SHA-256
receipt values; the full receipt files are not duplicated in Git.

See the [native reproduction instructions](README.md) and
[portable reproduction instructions](../SubtitleVertexStagingPortable/README.md).
