# BWDIF end-of-stream memory lifetime

This experiment compiles the complete baseline and candidate
`VideoDeinterlacer.swift` against FFmpeg 8.1.2. It measures input-buffer ownership
after the sink reaches EOF while the deinterlacer object remains alive.

The production change releases the completed filter graph. It does not change
the filter algorithm, cadence, supported formats, queue capacity, or the
32 MiB input-frame limit.

## Reproduce on macOS

Use the project's pinned native SDK, Swift 6.3 or later, and `pkg-config`.
The dedicated `deinterlacer-eof-memory.yml` workflow installs the reviewed SDK
and runs both this experiment and the native application test graph.

```sh
python3 Benchmarks/DeinterlacerEOFMemory/run.py \
  --output /tmp/deinterlacer-eof-results --pairs 4
```

The output directory must be new or empty. The runner verifies the frozen
baseline and shared source hashes before building. A complete run executes:

- Baseline and candidate lifetime tests in debug and release.
- One debug output comparison for each workload.
- Four release comparisons per workload in balanced AB/BA order.
- A fresh executable process for every observation.

The baseline must build successfully before its new lifetime tests are expected
to fail. Compiler errors, crashes, and unrelated test-runner errors are not
accepted as the negative control.

## Reproduce the software-only component on Linux

The offline helper builds the FFmpeg source archive already included in the
repository after verifying it against the corresponding-source manifest. It
does not download dependencies or change the system installation.

```sh
bash Benchmarks/DeinterlacerEOFMemory/build-linux-ffmpeg.sh \
  /tmp/deinterlacer-eof-sdk

python3 Benchmarks/DeinterlacerEOFMemory/run.py \
  --sdk-prefix /tmp/deinterlacer-eof-sdk \
  --output /tmp/deinterlacer-eof-results --pairs 4
```

The Linux toolchain must provide Swift 6.3 or later, a C compiler, make, and
Python 3.11 or later. External x86 assembly is disabled in the minimal SDK.
Linux timing therefore must not be used as a claim about macOS production
deinterlacing speed.

On Linux the staged Swift source differs only by removal of `import CoreVideo`.
`LinuxSupport.swift` supplies the `CVReturn` type alias and an unavailable
VideoToolbox guard. No filter, AVFrame, reference-counting, or allocation API is
mocked. All workloads use software frames. Native macOS runs use the real
CoreVideo import and complete production CFFmpeg shim.

## What is measured

The driver calls the normal `av_frame_get_buffer`.
`LifetimeProbe.h` wraps each resulting buffer without retaining an additional
observer reference. Its existing reference moves into the wrapper, and the
wrapper's final-release callback unreferences it and updates the counters.

The reported byte count is the sum of `AVBufferRef.size` for tagged input
allocations that remain alive. It includes FFmpeg's padding. This measures
actual release of those allocations; it is not an estimate derived from image
dimensions or a reference-count observer that itself keeps the pixels alive.

It excludes filter-created output buffers, filter graph/thread allocations,
allocator size classes, memory retained by the allocator after free, GPU
resources, CoreVideo resources, and process RSS. It does not establish a
whole-player memory reduction of the same size.

The driver records ownership after feeding, complete drain, repeated drain,
consumer release, and reset. The `held_output` workload deliberately retains a
progressive output that shares the source pixels. Those pixels must survive EOF
and remain byte-identical until the consumer releases them.

## Output and regression checks

The workloads cover an empty stream, progressive bypass, one interlaced frame,
720×576, 1920×1080 TFF and BFF, 3840×2160 10-bit, a progressive tail, resolution
and color changes, and retained output.

For every emitted frame, the driver writes complete visible pixel planes and
metadata: PTS, duration, time base, dimensions, pixel format, sample aspect,
color fields, frame flags, and filter/hardware-copy classification. The runner
compares the complete binary files, then checks that their SHA-256 remains
identical across runs and optimization levels.

One compressed complete output per workload is retained. Duplicate raw outputs
are removed after comparison to keep disk use bounded. Receipts contain all
observations, process order, source and executable hashes, command logs, and
the compressed/uncompressed output hashes.

The regression suite additionally exercises interrupted drain, throwing
consumers, repeated drain, reset, destruction, and same/changed-format input
after EOF. Those tests use a separate observer reference to inspect native
refcounts safely; only the callback-based driver measures final deallocation.

See [the research report](../../Documentation/DEINTERLACER_EOF_MEMORY_RESEARCH.md)
for measured results and qualification limits.
