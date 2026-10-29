# Complete-palette bitmap subtitle expansion

## Result and scope

The full 256-entry palette path in
[`illiquid_subtitle_rect_copy_bgra`](../../Sources/CFFmpeg/include/ffmpeg_shim.h)
used **30.1–32.5% less process CPU time** for the synthetic caption, PGS-sized, and
1920×1080 workloads in the final Linux x86_64 / GCC 13.3 experiment. These are
incremental gains against the already optimized palette-table implementation
on `main`, not the earlier scalar-to-table improvement recorded in [README.md](README.md).

The helper runs while converting decoded bitmap subtitle events to premultiplied
BGRA. It does not run once per video frame. These measurements do not establish
whole-player CPU, frame-rate, decoding, Metal rendering, energy, or Apple Silicon
gains. The full macOS app and native Swift test are not locally qualified here.
The existing bitmap-subtitle workflow runs the complete shim and native tests on
macOS when CI is available.

## Why this path

FFmpeg 8.1.2's
[PGS decoder](https://github.com/FFmpeg/FFmpeg/blob/n8.1.2/libavcodec/pgssubdec.c)
sets each emitted bitmap rectangle's `nb_colors` to 256, even when the authored
subtitle uses only a few colors. Every `uint8_t` index is therefore valid after
the helper's existing guards and complete palette initialization. The full-palette
loop can omit the per-pixel bounds check.

An initial branch-only experiment produced modest gains. Inspection of GCC's
optimized code showed it still reloaded the rectangle width and multiplied the
row by that width inside each pixel iteration. The selected version snapshots
width and computes the output row once. It keeps the existing source stride and
4-byte `memcpy`, preserving cropped inputs, unaligned destinations, and BGRA
byte order. The existing 512-pixel threshold for a 256-entry palette remains.

Smaller palettes retain the checked loop and its exact first-invalid-index
partial-write behavior. Small images retain the scalar path. No allocation,
cache, retained state, additional palette storage, or threshold change is added.
The destination must be separate from the rectangle and its input buffers;
`SubtitleDecoder.bitmapComposition` already creates fresh output `Data`.

## Reproduce

From a full checkout with the pinned native SDK:

```sh
python3 Benchmarks/BitmapSubtitlePalette/run.py --baseline checked-palette --pairs 12 --target-ms 100 --output /tmp/illiquid-full-palette
```

Use the shared Kyoto build queue when available, as required by `AGENTS.md`.
Kyoto and the macOS toolchain were unavailable in the recorded Linux environment,
so its component builds ran directly. Output directories must be new.

The frozen baseline, [CheckedPaletteBaseline.h](CheckedPaletteBaseline.h), is the
complete helper at commit `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`, source blob
`7f980fcf6a8ba1612259d555fb71994da5148d27`, helper SHA-256
`312c80c905a5cdd6d9f2a262821221e83dc8564360b7e78a26916429c51c9775`.
The runner verifies that frozen file before building. Its default `--baseline
scalar` remains available for the historical comparison; use `checked-palette`
to measure this change's incremental benefit.

The final local run used `--sdk-headers ../pinned-ffmpeg-headers`: all **144**
pre-extracted headers were checked against `BuildInputs/native-sdk.json` and only
those verified files were copied to an isolated include directory. In that mode,
`sdk.archive_sha256` is null because the runner does not read an archive; the
expected archive hash and verified header inventory are recorded separately.
The default archive route still checks the complete SDK archive and every header.
No FFmpeg libraries are linked or loaded by the component benchmark.

## Measurement method and retained evidence

[Full raw results](evidence/full-palette-linux-gcc13.json) include every timed
sample, calibration, checksum, source hash, compiler invocation, and command
receipt. The candidate helper SHA-256 is
`223944f1fedf99342c170ed64e6404ad234e2e6354f98965e9428df2a8dc267d`.

The runner builds baseline and candidate in separate translation units with
`-O3 -fno-lto`, so callers cannot specialize away the conversion using known
fixtures. Each timed sample is a fresh process with eight deterministic fixtures
and eight complete warmup cycles. Twelve pairs alternate baseline/candidate and
candidate/baseline order. Each pair uses the same calibrated iteration count;
calibration targets 100 ms for the baseline. Each conversion contributes one output byte to a receipt; full-buffer
checksums are computed outside the timed region. Both CPU and wall-clock results
are retained.

The following times are per-conversion medians, in microseconds. Percentages are
**medians of paired CPU-time reductions**, so they need not equal the percentage
calculated from the two independently displayed medians. Positive means less
CPU time. This was a shared host; small control differences are not treated as
reliable speedups or regressions.

| Workload | Baseline µs | Candidate µs | Paired CPU reduction |
| --- | ---: | ---: | ---: |
| tiny-1x1-256 | 0.009 | 0.008 | 13.6% |
| tiny-8x8-256 | 0.258 | 0.256 | -0.3% |
| threshold-511-256 | 2.026 | 2.027 | 1.4% |
| threshold-512-256 | 1.184 | 1.063 | 9.1% |
| threshold-513-256 | 1.211 | 1.089 | 8.9% |
| small-16x16-256 | 1.002 | 1.072 | 0.7% |
| small-32x16-256 | 1.200 | 1.028 | 12.8% |
| dvd-720x64-4 | 31.855 | 30.515 | 2.9% |
| caption-1280x96-sparse4 | 85.021 | 57.061 | 31.4% |
| caption-1280x96-dense256 | 83.212 | 57.417 | 30.7% |
| caption-1280x96-255 | 86.853 | 85.141 | 1.7% |
| caption-1280x96-sparse4-contiguous | 82.533 | 57.730 | 30.3% |
| caption-1280x96-dense256-contiguous | 83.402 | 57.450 | 32.0% |
| pgs-1920x216-256 | 279.361 | 189.020 | 32.5% |
| pgs-1920x216-256-contiguous | 280.491 | 191.529 | 31.8% |
| large-1920x1080-256 | 1378.037 | 970.135 | 30.1% |

Padding-zero fixtures are contiguous, uncropped input. Existing padded fixtures
retain their three-pixel horizontal crop and original stride. Both dense and
four-used-color 256-entry palettes are included. The ordinary four-color DVD and
255-entry palette cases exercise unchanged checked paths.

## Correctness and qualification

Each of the debug, optimized, and AddressSanitizer + UndefinedBehaviorSanitizer
builds passed the same **4,675 checks**, including **34,191,210 independently
checked pixels per configuration**. These are repeated configurations of the
same cases, not independent extra workloads. The deliberate heap-buffer-overflow
negative control was rejected by ASan. Leak checking is disabled in the sandbox;
address bounds and undefined-behavior checks remain enabled.

Coverage includes all 65,536 alpha/channel pairs on both scalar and full-palette
paths, 1,000 deterministic randomized fixtures, index 255, the 511/512/513 pixel
threshold, maximal valid one-dimensional extents, cropped and padded input,
unaligned palettes and output, output sentinels, invalid metadata, and precise
partial writes. Explicit 255-entry fixtures reject index 255 at the first,
middle, and last pixel.

The added native Swift regression enters the 512-pixel path with known BGRA
bytes, source padding, index 255, rounded alpha, and an aligned allocation whose
output begins one byte later. Its execution requires macOS CI; it was not run on
the Linux research host. The component results alone do not qualify live playback,
subtitle presentation, or end-to-end latency.
