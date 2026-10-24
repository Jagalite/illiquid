# Compact libass bitmap ownership

## Finding and change

`LibassContext.render` previously copied each `ASS_Image` into Swift-owned
`Data` using `stride * height` bytes. This retained native row padding and read
beyond the source extent guaranteed by the libass API: the final row may end
immediately after its visible `width` pixels. Padding in earlier rows may also
be uninitialized. See the [`ASS_Image` contract in libass 0.17.5][contract], the
version pinned by this repository.

`ASSBitmapCopyLayout` now validates both the compact destination size and the
last readable source byte, then copies only visible pixels in their original
top-to-bottom order. Padded masks use one owned allocation without a redundant
zero fill. Tight masks and single-row masks use a contiguous-copy fast path.
Returned regions use `stride == width` and `bitmap.count == width * height`.
No native bitmap pointer escapes the synchronous copy.

Both render admission passes now charge the compact payload size. This can
admit additional regions within an existing byte limit, while preserving image
order and the image-count limit. The complete native image list is validated
before any copies. Existing atlas, BGRA, screenshot, and PiP consumers already
honor region stride and need no changes.

[contract]: https://github.com/libass/libass/blob/0.17.5/libass/ass.h#L53-L76

## Scope of the memory result

The byte metric is copied mask payload (`Data.count`), not allocator capacity,
process RSS, the libass glyph cache, Metal texture storage, or whole-player
memory. Requested payload allocation and copy traffic decrease by
`(sourceStride - width) * height` bytes per padded mask. The configured libass
cache limits remain separate from these Swift-owned region buffers.

The existing compositor feature matrix was rendered at five timestamps at each
of four resolutions. The Linux inventory used the available **libass 0.17.1**
and DejaVu Sans through Fontconfig; native CI uses the repository's pinned
**libass 0.17.5** and macOS font provider. Font choice and libass version can
change mask dimensions, so these measurements are a fixture result, not a
prediction for every subtitle file.

| Canvas | Sampled frames | Region copies | Previous payload bytes, summed | Compact payload bytes, summed | Reduction |
| --- | ---: | ---: | ---: | ---: | ---: |
| 640 × 360 | 5 | 165 | 1,716,608 | 1,426,468 | 16.90% |
| 1280 × 720 | 5 | 165 | 5,834,208 | 5,062,145 | 13.23% |
| 1920 × 1080 | 5 | 165 | 12,030,848 | 10,572,838 | 12.12% |
| 3840 × 2160 | 5 | 165 | 46,231,104 | 41,133,476 | 11.03% |
| **All samples** | **20** | **660** | **65,812,768** | **58,194,927** | **11.58%** |

These sums describe copying across successive frames, not simultaneously live
storage. For example, the largest sampled 4K frame decreased from 13,309,440 to
12,314,522 payload bytes (994,918 bytes, about 0.95 MiB).

Mask dimensions, per-frame totals, fixture hashes, and library version are recorded in
[`evidence/linux/libass/libass-inventory.json`](evidence/linux/libass/libass-inventory.json).
No padding bytes are read by the inventory tool.

## Correctness qualification

The focused package compiles the actual production helper and the repository's
actual `ASSBitmapCopyTests.swift`. Five portable tests pass in both debug and
release, covering:

- 275 combinations of widths, heights, and padding with exact pixel equality.
- An unpadded final row ending at a protected page, including a single row
  whose unused stride is `Int.max`.
- Invalid geometry and overflow in destination multiplication, last-row
  offset multiplication, and final source-byte addition.
- Independent ownership after source overwrite/deallocation and Swift `Data`
  copy-on-write behavior.

The additional native libass test is compiled only in the full native module.
It checks compact accounting, exact-fit and cumulative byte/image limits,
unchanged-frame copy skipping, and equivalent atlas/BGRA pixels and quads from
padded and compact representations. The existing subtitle staging workflow
also runs compositor and PiP tests on macOS. Portable tests do not establish
full macOS playback, GPU, or screenshot integration success.

## Timing method and tradeoff

This is a memory reduction and source-boundary correction. Row-wise copying
can take more CPU time than the previous bulk copy, especially for small
padded masks. The benchmark reports that cost rather than assuming less
copying always means lower elapsed time.

`run.py` verifies the original copy statements against baseline commit
`af1c1add701e49b355448cf8983eaed1e7623108`. It builds separate optimized Swift
modules for that bulk copy and the exact candidate helper, with the same
driver. Sources, compiler, commands, and binaries are hashed in each receipt.
The candidate includes layout validation; the baseline adapter reproduces the
original copy phase after preflight validation. This is a component benchmark,
not the complete `LibassContext.render` call.

All timing sources are fully allocated and initialized through `stride *
height`, so the old copy is timed without an out-of-bounds read. Guard-page
tests separately exercise the API's minimum valid source extent. Each variant
first passes full visible-pixel and ownership checks. Measurements use six
alternating AB/BA pairs, fresh processes, equal per-case iteration counts, a
warm-up, and calibration toward 50 ms. Both wall and process CPU times are
recorded. Verification also retains 32 copies and checks their total payload
size; that value is not an RSS measurement.

The standard cohort covers a tightly packed control and five padded shapes.
The libass cohort selects five fixed quantiles of observed mask area rather
than selecting by percentage saved. Pixel contents in the timing fixtures are
deterministic synthetic values; their dimensions come from the recorded real
libass output. Exact results are in the two `summary.json` files below.

Final Linux measurements (Swift 6.3.2, process CPU time medians):

| Observed mask geometry | Payload before → after | Payload reduction | Copy before → after |
| --- | ---: | ---: | ---: |
| 12 × 37, source stride 160 | 5,920 → 444 B | 92.50% | 0.160 → 0.224 µs |
| 112 × 80, source stride 128 | 10,240 → 8,960 B | 12.50% | 0.209 → 0.309 µs |
| 377 × 74, source stride 384 | 28,416 → 27,898 B | 1.82% | 0.644 → 0.749 µs |
| 726 × 133, source stride 736 | 97,888 → 96,558 B | 1.36% | 1.992 → 1.995 µs |
| 2168 × 1248, source stride 2176 | 2,715,648 → 2,705,664 B | 0.37% | 61.195 → 69.243 µs |

The small shapes add roughly 0.06–0.10 µs per copy; the largest adds about
8.05 µs. Relative CPU penalties are substantial for some shapes even though
absolute times are small. Tightly packed storage saves no bytes and follows
the same bulk-copy route. The ordinary synthetic subtitle-line case saves
17.58% of payload at about 0.096 µs additional CPU time. These observations
support the memory/safety tradeoff; they do not establish faster playback or
lower total CPU utilization.

## Reproduce

Run the portable tests and standard copy measurements with Swift 6.1 or newer:

```sh
python3 Benchmarks/ASSBitmapCopy/run.py \
  --output /tmp/illiquid-ass-bitmap-copy --pairs 6 --target-ms 50
```

Capture real libass geometry and benchmark the selected shapes:

```sh
python3 Benchmarks/ASSBitmapCopy/capture-libass.py \
  --output /tmp/illiquid-ass-mask-inventory
python3 Benchmarks/ASSBitmapCopy/run.py --benchmarks-only \
  --cases /tmp/illiquid-ass-mask-inventory/libass-cases.json \
  --output /tmp/illiquid-ass-mask-shapes --pairs 6 --target-ms 50
```

Use `--library /path/to/libass.9.dylib` for an explicit library and
`--swift /path/to/swift` for a non-default compiler. Output directories must be
new or empty. The runner never downloads a toolchain or native dependencies.
The baseline commit must be available locally; CI checks out full history.

On a configured macOS build host, run the native integration gate:

```sh
swift test --force-resolved-versions --filter \
  'ASSBitmapCopyTests|SubtitleStagingReuseTests|MetalASSSubtitleCompositorTests|PiPSubtitlePipelineTests'
```

### Evidence

- [Real libass inventory](evidence/linux/libass/libass-inventory.json)
- [Portable tests and standard-case receipt](evidence/linux/copy/manifest.json)
- [Standard-case summary](evidence/linux/copy/summary.json)
- [Standard-case raw measurements](evidence/linux/copy/observations.json)
- [Observed-shape receipt](evidence/linux/libass-copy/manifest.json)
- [Observed-shape summary](evidence/linux/libass-copy/summary.json)
- [Observed-shape raw measurements](evidence/linux/libass-copy/observations.json)

macOS artifacts are uploaded by `.github/workflows/subtitle-staging-performance.yml`
as `ass-bitmap-copy-macos-component` and `ass-bitmap-copy-macos-native`.
