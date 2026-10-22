# Video HDR metadata preparation

This benchmark compares the color metadata portion of `VideoDecoder.makeFrame`
against commit `7f9ba073394b77a908e0589447c6edc8d10b832c`. The baseline serializes
HDR side data for the pixel buffer attachments, then serializes it again for the
returned decoded frame. The candidate serializes each payload once and shares
the resulting `Data` with both consumers.

## Scope

The runner extracts these production methods verbatim, removing only their
`private` modifiers:

- `applyColorMetadata`
- `masteringDisplayPayload`
- `contentLightPayload`
- `colorPrimariesAttachment`
- `transferAttachment`
- `matrixAttachment`

A small wrapper preserves each revision's call order and returns both HDR
payloads. Both executables use the same full repository CFFmpeg shim and module
map, real FFmpeg frames, real CoreVideo pixel buffers, the same fixtures, and
identical optimized Swift compiler flags and the same default scheduling policy.
The runner rejects changes to shared
shims, payload serialization, or color mapping helpers that would broaden this
comparison.

The measured operation includes color attachments and the returned HDR payloads.
The two `*_cleared` controls additionally include clearing attachments before
each preparation.
It excludes decoding, pixel conversion, frame and pixel buffer allocation,
geometry attachments, and presentation. Results establish component cost, not
whole-player CPU consumption or frame-rate improvements.

## Run on macOS

Prepare the repository's pinned native SDK first, and make its pkg-config
configuration available as for the normal native build. The runner neither
downloads dependencies nor changes installed libraries.

```sh
python3 Benchmarks/VideoHDRMetadata/run.py \
  --output /tmp/illiquid-hdr-metadata --pairs 10 --target-ms 100
```

`--swiftc` and `--pkg-config` select explicit tool binaries when necessary.
`--verify-only` compiles and checks exact output parity without collecting timing
samples. `--prepare-only` saves extracted sources and receipts without requiring
Swift or Apple frameworks, allowing inspection on Linux. Output directories must
be new or empty.

## Workloads and method

The eight original workloads cover SDR BGRA/NV12, HDR10 BGRA/P010,
mastering-only metadata, content-light-only metadata, changing metadata, and
preexisting attachments. They use a warm 32-buffer ring: repeated preparations
replace or preserve attachments already present after warmup.

Two additional controls, `hdr10_p010_cleared` and `sdr_nv12_cleared`, call
`CVBufferRemoveAllAttachments` before every preparation, inside the measured
interval. They measure **clearing plus fresh attachment insertion and payload
preparation**, without allocating a new buffer per iteration. These controls
cover the empty-attachment condition of the software planar path, which clears
metadata before preparing each output. Their clearing operation is a benchmark
fixture mechanism; it does not reproduce production's individual key removals.
Keep their results separate from the eight warm-buffer workloads when reporting
absolute cost or percentage changes.

Before timing, `--verify` traces from both executables must match exactly as
decoded JSON. Each timed process must also report matching output checksums.
Calibration uses the fastest observed pilot rate to target about 100 ms for each
variant. The default ten pairs alternate baseline/candidate and
candidate/baseline order; every invocation runs in a separate process. Both
variants use the same iteration count for a workload.

Evidence includes complete traces, parity results, source snapshots and hashes,
compiler commands and flags, native package versions, libavutil and executable
hashes, calibration records, raw wall/CPU measurements, and every paired ratio.
Summaries report medians, observed ranges, paired wins, and minimum wall duration.
No performance threshold is imposed by the runner; all workloads, including the
SDR controls, must be examined before deciding whether the production change is
worth keeping.

The CI confirmation protocol uses twenty pairs and a 300 ms target to reduce
short-process scheduling variation. Research-branch pushes run the component
study; pull requests and manual workflow runs also generate native fixtures,
build the complete app graph, and run the native decoder/application tests.
The initial research run additionally completed that native qualification before
this component-only push convention was introduced.
