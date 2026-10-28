# Video color sampling performance

## Question and change

`NativePresentationCoordinator.enqueueMainVideo` samples video colors on its serial commit queue when adaptive color sampling is enabled. The default sampler accepts at most one frame every 0.25 seconds. Each accepted frame contributes a 12-column by 8-row grid.

The baseline dispatches on the pixel format and queries base addresses and row strides for every grid point. The candidate dispatches on the format once and resolves the layout once, while the same CoreVideo read lock is held. A nonescaping grid closure uses those addresses only until the existing deferred unlock. Nothing is cached between frames.

Apple's [pixel-buffer locking contract](https://developer.apple.com/documentation/corevideo/cvpixelbufferlockbaseaddress%28_%3A_%3A%29) requires the CPU read to stay between lock/unlock calls with matching flags. The candidate preserves that scope and continues using each plane's reported row stride; it does not infer stride from the image width.

Successful BGRA sampling reduces base-address/stride queries from 192 to 2 per frame. Successful bi-planar sampling reduces plane-count/base-address/stride queries from 480 to 5. These are counts derived from the source loops, not separately instrumented native API measurements. Width, height, format and matrix lookup, locking, output allocation, and the existing RGB conversion and temporal behavior remain in the operation.

The baseline is pinned to `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`. Only `Sources/IlliquidNativePlayback/Presentation/VideoFrameColorSampler.swift` changes in production.

## Reproduce

Run on macOS with the repository's supported Swift/Xcode toolchain:

```sh
python3 Benchmarks/VideoColorSampling/run.py --output /tmp/illiquid-video-color-sampling
```

Follow the repository's `AGENTS.md` build-coordination rule: submit this command through the shared Kyoto queue when it is available. The dedicated GitHub Actions workflow uses that queue when present and explains its direct, serial component builds on an isolated hosted runner when it is absent.

## Method

- Compile the pinned baseline and candidate sampler files directly, with the same optimized Swift compiler flags. The supporting `VideoColorSample.swift` and `PiPVideoMapping.swift` files must match the baseline byte for byte.
- Run the same ten native sampler tests against both revisions in debug and release using isolated Swift packages. These packages retain the production module boundaries but do not build FFmpeg, the renderer, or the application shell.
- Compare all 96 RGB samples as exact IEEE-754 bit patterns for 15 format/size combinations under six matrix attachment states: absent, BT.601, BT.709, BT.2020, unknown and absent after earlier overrides. Also compare ten temporal events covering throttling, smoothing, scene cuts, reset and a regressing clock.
- Time five formats (BGRA; 8-bit bi-planar video/full range; 10-bit bi-planar video/full range) at 48×32, 1920×1080 and 3840×2160. Each process constructs one IOSurface-backed buffer, fills a deterministic pattern and performs 64 warmup calls before timing.
- Calibrate both variants with a 30 ms batch-duration target, choosing identical iteration counts for each case. Calibration is a target rather than a lower bound on subsequent observations; the shortest measured batch in this run was 15.7 ms. Run eight fresh-process pairs per case, alternating baseline/candidate order and rotating case order. Report every case and all 240 individual measured observations.
- Consume every RGB component in a word checksum inside timing; compare checksums with preflight and verify that staged sources and binaries remain unchanged afterward.

The regression additions use an independent integer grid-coordinate and BT.709 oracle with padded rows, tiny buffers, odd BGRA dimensions, unused 10-bit bits, buffer reuse, format/stride switches and unsupported formats. Existing throttle, smoothing, scene-cut and matrix-switch tests are preserved.

## Scope

These measurements describe elapsed time for the color-sampling component on synthetic, preallocated pixel buffers. Buffer construction and filling are outside the timing interval; the actual sampler's CoreVideo lock/unlock, layout reads, conversion and output-array construction are inside it. Consuming every sampled color prevents the benchmark from discarding the result and adds identical checksum overhead to both implementations.

This is a small optimization on a path throttled to four samples per second. It does not establish a change in playback frame rate, GPU time, energy use, dropped frames, or full-application responsiveness. Native decoding, rendering and live UI playback are not exercised by this isolated benchmark.

## Evidence

Native qualification passed in [GitHub Actions run 40635423170](https://github.com/Jagalite/illiquid/actions/runs/40635423170) on 2026-10-28. The tested candidate was [`c60321fc2418bbb9bb801e85388bd95fcc4dccb5`](https://github.com/Jagalite/illiquid/commit/c60321fc2418bbb9bb801e85388bd95fcc4dccb5), against baseline [`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`](https://github.com/Jagalite/illiquid/commit/ea2ff568237e2667f7b1aeee67b11a44ebe95b72). The subsequent report/evidence commit changes no production, test, harness, driver or workflow source.

The host was an Apple M1 (Virtual), `arm64`, with 3 virtual CPUs and 7 GiB RAM. It ran macOS 26.6.2 (25G83), Xcode 26.6 (17F113), and Apple Swift 6.3.3. Both optimized executables used `-O -whole-module-optimization -swift-version 6` and target `arm64-apple-macosx26.0`; the full flags, SDK and hashes are in the manifest. This is one hosted virtual machine, not a survey of physical Macs.

### Timing results

All 120 baseline/candidate pairs favored the candidate. Across the 15 workloads, the median paired elapsed-time reduction was **40.95–65.87%**, with median paired savings of **2.59–7.83 µs per accepted sample**. These are component timings including the checksum overhead described above.

| Format | Buffer size | Baseline median (µs/sample) | Candidate median (µs/sample) | Median paired reduction | Faster pairs |
| --- | --- | ---: | ---: | ---: | ---: |
| BGRA | 48×32 | 6.610 | 3.714 | 44.2% | 8/8 |
| BGRA | 1920×1080 | 6.435 | 3.457 | 45.3% | 8/8 |
| BGRA | 3840×2160 | 6.434 | 3.851 | 41.0% | 8/8 |
| 8-bit YUV, video range | 48×32 | 10.905 | 3.854 | 62.5% | 8/8 |
| 8-bit YUV, video range | 1920×1080 | 10.789 | 4.367 | 61.5% | 8/8 |
| 8-bit YUV, video range | 3840×2160 | 10.937 | 4.405 | 61.8% | 8/8 |
| 8-bit YUV, full range | 48×32 | 11.727 | 3.839 | 65.9% | 8/8 |
| 8-bit YUV, full range | 1920×1080 | 11.130 | 4.008 | 64.9% | 8/8 |
| 8-bit YUV, full range | 3840×2160 | 10.613 | 4.464 | 58.4% | 8/8 |
| 10-bit YUV, video range | 48×32 | 10.952 | 3.795 | 65.2% | 8/8 |
| 10-bit YUV, video range | 1920×1080 | 11.261 | 3.945 | 65.0% | 8/8 |
| 10-bit YUV, video range | 3840×2160 | 10.865 | 4.071 | 60.7% | 8/8 |
| 10-bit YUV, full range | 48×32 | 10.718 | 4.434 | 63.7% | 8/8 |
| 10-bit YUV, full range | 1920×1080 | 12.333 | 4.487 | 60.8% | 8/8 |
| 10-bit YUV, full range | 3840×2160 | 10.686 | 3.730 | 63.8% | 8/8 |

Baseline and candidate columns are independent medians of eight observations. Reduction is the median of the eight paired values `100 × (1 − candidate / baseline)`, so it need not equal the percentage calculated from those two displayed medians. Pair order alternates AB/BA; all raw observations are retained, including slower batches and host variability.

### Correctness results

- All ten tests passed against both baseline and candidate in both debug and release: four successful suite runs, 40 test executions, ten distinct tests.
- All 90 grid/matrix cases (15 workloads × six matrix states, each containing 96 RGB samples) matched baseline output bit for bit. Ten explicit temporal events also matched exactly.
- Every measured checksum matched its preflight result and paired variant. Source and executable hashes remained unchanged throughout qualification.
- A separate recomputation from the 240 raw observations confirmed the pair counts, iteration counts, checksums, medians, reductions and savings reported above.

### Preserved records

- [manifest.json](evidence/macos-arm64-20261028/manifest.json): source revisions, source/binary SHA-256 hashes, host, compiler, flags, per-case iterations and test exit codes.
- [summary.json](evidence/macos-arm64-20261028/summary.json): every case's statistics, ratios, verification digest and test results.
- [observations.jsonl](evidence/macos-arm64-20261028/observations.jsonl): all 240 raw timed observations, including execution order, layout, iterations, elapsed time and checksums.
- [qualification.json](evidence/macos-arm64-20261028/qualification.json): CI/job/artifact links, the independent consistency audit and scope limitations.

The CI [`video-color-sampling-native` artifact](https://github.com/Jagalite/illiquid/actions/runs/40635423170/artifacts/12793522961) additionally contains the complete verification vectors, test logs and staged source files. Its scheduled expiry is 2026-11-11T05:07:53Z; the checked-in records above persist with this change. The verification JSON's SHA-256 is `8b6fd17b568b3748a8e36f94b3c4532c1ad0755b69632fea5911892086acd7a9`.
