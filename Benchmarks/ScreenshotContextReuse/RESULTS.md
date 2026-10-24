# Screenshot context reuse: native qualification

## Decision

Reusing the screenshot `CIContext` met the predeclared performance and image
correctness criteria. The complete warmed PNG-generation path took 25–35% less
paired wall time across four 1080p workloads and 16.6% less at 4K on the measured
macOS runner. Every one of the 30 warmed wall-time pairs improved. The four 1080p
cases also used 15.5–24.4% less paired process CPU time.

This supports a focused improvement to repeated screenshot generation. First-use
measurements were variable and mixed; this experiment does not establish a
first-screenshot speedup. The 4K CPU result was also mixed across pairs.

## Measured revisions and environment

- Baseline: `7f9ba073394b77a908e0589447c6edc8d10b832c`.
- Candidate: `8ebc569187ec03355e09885eeebab21b391eb91e`, clean working tree.
- [Qualification run 39844570938](https://github.com/Jagalite/illiquid/actions/runs/39844570938),
  measured on 2026-10-22.
- macOS 26.6.2, Apple M1 (Virtual), arm64; Metal reported **Apple Paravirtual
  device**. These are hosted virtual-machine measurements, not physical-device
  or cross-hardware qualification.
- Apple Swift 6.3.3, Xcode 26.6, macOS 26.5 SDK, target macOS 26.0,
  Swift 6 mode, `-O -whole-module-optimization -warnings-as-errors`.

The only changed production source is `NativeScreenshot.swift`. Its context is
now initialized lazily once and shared across captures; each capture still
constructs its own image and compositor. Context options, SDR sRGB output, HDR
tone mapping, geometry, subtitles and PNG encoding remain the same.

## Results

The [protocol](README.md) was committed before measurement. Each workload has six
fresh-process pairs with alternating AB/BA order. Warm processes perform two
untimed captures and then six timed captures over three deterministic inputs.
First-use processes perform one capture without screenshot warmup. The run
contains 120 process observations and 420 timed captures. No observations were
discarded.

Times below are median milliseconds per capture. Percentage reductions are
`100 × (1 − median(candidate / baseline))` across matched pairs; they are not
computed from the two separate medians printed in the table.

### Repeated captures after warmup

| Workload | Baseline wall ms | Candidate wall ms | Paired wall reduction | Paired CPU reduction |
| --- | ---: | ---: | ---: | ---: |
| BGRA 1080p | 55.45 | 37.88 | 33.7% | 24.2% |
| NV12 1080p | 69.55 | 46.00 | 35.4% | 24.4% |
| HDR P010 1080p | 68.12 | 46.03 | 29.6% | 17.7% |
| BGRA 4K | 195.44 | 156.32 | 16.6% | 4.9% |
| 1080p with subtitles | 53.24 | 39.22 | 25.0% | 15.5% |

All four 1080p cases exceed the predeclared 10% threshold for both wall time and
CPU. No warmed wall-time pair regressed. At 4K, CPU improved in three pairs and
regressed in three, with the largest regression 4.04%. The paired median is
positive, but this does not establish a reliable 4K CPU reduction.

### First capture in a fresh process

| Workload | Baseline wall ms | Candidate wall ms | Paired wall reduction |
| --- | ---: | ---: | ---: |
| BGRA 1080p | 138.68 | 139.52 | −0.6% |
| NV12 1080p | 189.10 | 195.17 | −5.2% |
| HDR P010 1080p | 172.01 | 159.79 | 5.0% |
| BGRA 4K | 219.24 | 228.62 | 1.6% |
| 1080p with subtitles | 165.17 | 177.89 | −0.8% |

Negative reductions mean slower candidate pairs. These measurements include
context initialization in both variants. Individual first-use observations were
noisy, including candidate outliers of 390.1 ms versus a 155.6 ms baseline for
NV12, and 294.8 ms versus a 127.0 ms baseline for BGRA. First-use variability
remains unresolved on this shared virtual runner. System and driver caches
persist across processes, so these are not cold-boot results.

### Memory observations

| Warm workload | Baseline median peak RSS MiB | Candidate median peak RSS MiB |
| --- | ---: | ---: |
| BGRA 1080p | 64.41 | 64.00 |
| NV12 1080p | 113.86 | 113.41 |
| HDR P010 1080p | 122.70 | 122.20 |
| BGRA 4K | 207.11 | 206.73 |
| 1080p with subtitles | 64.72 | 64.32 |

These are process high-water marks from Darwin `ru_maxrss`, including runtime and
fixture allocations. The small differences do not establish a memory saving.
The change keeps Core Image context resources alive after the first screenshot.
Current post-capture residency, complete GPU allocations and long-session memory
behavior were not measured. `.cacheIntermediates` remains disabled.

## Correctness and integration

Both optimized builds passed exact decoded canonical RGBA equality, output
dimensions and selected PNG color metadata checks across 19 cases. The corpus
includes BGRA, NV12, PQ/BT.2020 P010, 1080p and 4K output, rotation, mirroring,
clean aperture, crop/aspect adjustments, padded text masks and premultiplied
bitmap subtitles. Concurrent first initialization, concurrent-versus-serial
captures and replay after mixed formats also matched. All 19 baseline/candidate
RGBA pairs and SHA-256 hashes were independently checked again in the downloaded
artifact.

Native application regression qualification passed: the full release package
graph compiled, and all seven selected tests passed with no skips. The
[CI receipt](evidence/2026-10-22-arm64/ci-receipt.json) and
[native test log](evidence/2026-10-22-arm64/native-tests.log) record the result.
The test run includes six new screenshot tests and the existing
subtitle-composition screenshot test.
The new tests exercise content and matrix-attachment changes on reused buffers,
geometry changes, padded subtitle formats, 24 concurrent captures and invalid
output dimensions.

## Evidence and scope

The [evidence directory](evidence/2026-10-22-arm64/) preserves the original
environment, revision/source/executable hashes, all ordered raw measurements,
verification manifest, summaries and completion receipt. The source and harness
hashes match the measured candidate. The benchmark compiles the actual production
PNG implementation and verbatim supporting declarations; the separate app job
checks full-package integration.

The [component artifact](https://github.com/Jagalite/illiquid/actions/runs/39844570938/artifacts/12453509886)
also contains staged sources, driver snapshots, executable builds, compiler logs
and decoded RGBA files. Its ZIP SHA-256 is
`14865f18b0d9fbb77b488c7423905ebcb3e617eab5fb5afdbe81825142bff2e1`.
GitHub retains that artifact for 14 days; the committed text evidence and
reproduction instructions remain available afterward.

The timed boundary is the complete synchronous `NativeScreenshot.png()` call,
including rendering, composition and PNG encoding, using synthetic fixtures.
It excludes displayed-frame acquisition, the save panel and filesystem writing.
It does not establish interactive latency, playback frame-rate, battery-life or
steady-playback CPU improvements. Results on other hardware, long-lived player
sessions and different image content can vary.
