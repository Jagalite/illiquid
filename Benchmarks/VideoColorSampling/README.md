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

## Scope

These measurements describe elapsed time for the color-sampling component on synthetic, preallocated pixel buffers. Buffer construction and filling are outside the timing interval; the actual sampler's CoreVideo lock/unlock, layout reads, conversion and output-array construction are inside it. Consuming every sampled color prevents the benchmark from discarding the result and adds identical checksum overhead to both implementations.

This is a small optimization on a path throttled to four samples per second. It does not establish a change in playback frame rate, GPU time, energy use, dropped frames, or full-application responsiveness. Native decoding, rendering and live UI playback are not exercised by this isolated benchmark.

## Evidence

The runner records the tested source revisions/hashes, host/toolchain, individual paired observations, summary, and regression results in the output directory. CI retains these records and the complete logs as an artifact. Measured results will be retained here after qualification.
