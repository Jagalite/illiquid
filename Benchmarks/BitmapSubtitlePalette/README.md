# Bitmap subtitle palette conversion

The selected optimization prepares premultiplied BGRA colors once per bitmap
subtitle rectangle and reuses them while expanding its indexed pixels. In the
recorded Linux experiment, the five caption and larger bitmap workloads used
**73.9–75.5% less process CPU time**, measured as the median change across eight
alternating baseline/candidate pairs. These are conversion-helper measurements;
they do not measure whole-player frame rate, subtitle decode time, or energy use.

## Production change and selection

[`illiquid_subtitle_rect_copy_bgra`](../../Sources/CFFmpeg/include/ffmpeg_shim.h)
previously loaded a native-endian `0xAARRGGBB` palette entry and performed three
rounded alpha multiplications for every visible pixel. A rectangle declares at
most 256 colors, so larger rectangles repeat that arithmetic many times.

The candidate builds a local `uint8_t[256][4]` table for the declared colors,
then copies the prepared BGRA bytes for each validated palette index. The table
uses 1 KiB of stack space and requires no allocation, retained cache, or new
ownership state. The existing scalar loop remains the path for rectangles with
fewer than **two pixels per declared palette entry**. The arithmetic, all input
guards, first-invalid-index error, and partial output prefix remain the same.
`memcpy` preserves support for unaligned palettes and output; explicit BGRA bytes
avoid introducing a host-endian output representation.

[`SubtitleDecoder.bitmapComposition`](../../Sources/IlliquidNativePlayback/Media/SubtitleDecoder.swift)
allocates fresh output `Data` separately from FFmpeg's index and palette buffers.
That existing disjoint-storage contract is now documented on the helper. A
failed conversion throws before publishing its composition. Palette snapshots
are not an in-place conversion API.

Research also identified repeated URL normalization in playlist identity lookup
and repeated escaping passes in external text subtitle import. Palette expansion
was selected after its positive C screen using the actual pinned FFmpeg headers.
Two palette designs were rejected during exploration: preparing every palette
for tiny images, and enabling the table at only one pixel per declared color.
The latter failed to amortize setup around 256-pixel/256-color inputs. The final
two-pixel threshold is explicitly tested and measured below.

## Reproduce

Requirements: Python 3.10+, a C11 compiler, and a full repository checkout with
`BuildInputs/native-sdk.tar.gz` and its manifest. No system installation or
native-library linkage is required. The runner checks the SDK archive hash and
every extracted FFmpeg header against the pinned manifest.

```sh
python3 Benchmarks/BitmapSubtitlePalette/run.py \
  --pairs 8 --target-ms 80 \
  --output /tmp/illiquid-palette-run
```

The output directory must not already exist. To run correctness and sanitizer
qualification without timings:

```sh
python3 Benchmarks/BitmapSubtitlePalette/run.py \
  --verify-only --output /tmp/illiquid-palette-checks
```

`--cc` selects a compiler. An even `--pairs` value keeps baseline-first and
candidate-first runs balanced. Results, command receipts, source snapshots,
generated wrappers, headers, and binaries stay inside the requested directory.

The baseline is the exact helper at revision
`68274d1b09dcc866296321a5a8858efc297c4f19`, header Git blob
`10a3f9d1a2c5604a2eaaa8299a727ce5d2552bcc`. [`Baseline.h`](Baseline.h) is a
verbatim extraction, checked against SHA-256
`4f4e115e23be67dbdbbaf3390af4862969c13c2fdff628f5e364b808e35c81b0`.
It is retained so shallow CI checkouts can reproduce the comparison.

The candidate comes from the working tree, with its full header and extracted
helper hashes recorded. On Linux, the runner copies the complete helper
verbatim into a translation unit using **real FFmpeg `AVSubtitleRect` headers**;
it does not substitute a struct or reimplement the conversion. On macOS it
includes the complete production shim, including its Apple framework headers.
Both variants have external wrappers in separate translation units, use the
same optimization flags, and explicitly disable LTO.

## Recorded Linux results

Evidence: [`evidence/linux-gcc13.json`](evidence/linux-gcc13.json).

- Ubuntu GCC 13.3.0; Linux x86-64; glibc 2.39.
- Release flags: `-O3 -std=c11 -Wall -Wextra -Werror -fno-lto`.
- Twelve workloads, eight pairs per workload, **192 fresh-process timing samples**.
- Eight deterministic fixtures per workload, with different palettes and index
  patterns. Every process warms all eight fixtures for eight cycles before timing.
- Baseline calibration chooses iterations targeting approximately 80 ms, rounded
  to complete eight-fixture cycles. Each pair uses identical iteration counts.
- Allocation, fixture generation, independent verification, and full-buffer
  checksums are outside timing. The loop includes conversion, return-code
  checking, and one output-byte receipt. Checksums and receipts match between
  both variants in every timed pair.
- Wall-clock and process CPU time are retained. The host is shared, with no CPU
  affinity, frequency, thermal, or background-load controls. Sample ranges show
  substantial variation; no completed sample was discarded.

**CPU microseconds per conversion.** Before/after columns are separate medians
of process means. The change column is the median of the eight paired percentage
changes, so it need not equal the ratio of the two separate medians.

| Synthetic rectangle | Declared colors | Before (µs) | After (µs) | Paired CPU time change |
| --- | ---: | ---: | ---: | ---: |
| 1 × 1 | 256 | 0.0061 | 0.0067 | +9.5% |
| 8 × 8 | 256 | 0.1837 | 0.2633 | +3.1% |
| 511 × 1, below table threshold | 256 | 1.3305 | 1.2812 | −1.8% |
| 512 × 1, at table threshold | 256 | 1.2431 | 0.9104 | −28.0% |
| 513 × 1, above table threshold | 256 | 1.2634 | 0.8851 | −30.8% |
| 16 × 16, scalar control | 256 | 0.6644 | 0.6740 | +0.9% |
| 32 × 16 | 256 | 1.2915 | 0.9021 | −29.3% |
| 720 × 64 | 4 | 179.616 | 33.936 | −75.5% |
| 1280 × 96, four dispersed indices | 256 | 304.689 | 80.350 | −75.1% |
| 1280 × 96, full index pool | 256 | 304.283 | 77.936 | −74.5% |
| 1920 × 216 | 256 | 1493.401 | 300.937 | −74.5% |
| 1920 × 1080 | 256 | 5247.093 | 1500.258 | −73.9% |

The scalar controls are retained in the evidence. The 1 × 1 case adds roughly
0.6 ns in the separate medians, while the other scalar controls show small
paired changes within a noisy host. The optimization is justified by larger
rectangles, rather than a claim that every possible rectangle becomes faster.
These synthetic palettes characterize the conversion algorithm; they do not
estimate the frequency of these rectangles in a user's media library.

## Correctness and memory checks

The same **4,382 checks** passed in each of three configurations: debug (`-O0`),
release (`-O3`), and AddressSanitizer plus UndefinedBehaviorSanitizer (`-O1`,
`-fno-sanitize-recover=all`). Each configuration invoked the actual baseline and
candidate 8,764 times and checked 27,791,978 expected pixels. These counts overlap
between configurations and are not independent samples of media playback.

Coverage includes:

- All 65,536 channel/alpha pairs using an independent floating-point rounding
  oracle, including fully transparent and opaque entries and valid index 255.
- The activation boundary `2 * nb_colors − 1`, `2 * nb_colors`, and
  `2 * nb_colors + 1` for seven palette sizes.
- One thousand deterministic randomized rectangles and 96 workload fixtures.
- Cropped input pointers, padded rows with invalid non-image indices, exact-size
  unaligned palette allocations, unaligned output, and destination sentinels.
- Exact valid-prefix bytes and untouched tails when the first, middle, or last
  visible palette index is invalid.
- Null arguments, missing buffers, unsupported type, invalid dimensions/color
  counts/strides, insufficient or extra output capacity, and maximum supported
  one-dimensional extents.

The local sandbox cannot support LeakSanitizer's `/proc` task enumeration.
Test-only sanitizer defaults disable leak scanning while retaining address and
undefined-behavior checks; no sanitizer setting enters production. A deliberate
heap overrun in a separate negative-control executable was correctly rejected
by AddressSanitizer with `heap-buffer-overflow`, confirming bounds checking
remained active. Its expected nonzero exit is recorded in the evidence.

## macOS qualification

The [bitmap subtitle workflow](../../.github/workflows/bitmap-subtitle-palette.yml)
runs the same component tests, sanitizers, and paired measurements on Linux and
macOS. The macOS component compiles the complete shim. A separate native job
builds the app dependency graph with the pinned SDK and runs the existing
`BitmapSubtitleTests`, `PGSSubtitleCropTests`, and `ExternalVobSubTests`.
Tests requiring opt-in media fixtures retain their existing conditional skips.

The checked-in numerical receipt is the local Linux run. Apple Silicon timing,
native application checks, and their exact commit identities are reported by
the workflow artifacts and PR checks. This experiment does not qualify physical
display rendering or real-media playback on the local Linux host.
