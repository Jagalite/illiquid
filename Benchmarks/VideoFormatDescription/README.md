# Video format description reuse

## Question and scope

Can the video presenter avoid reconstructing identical CoreMedia metadata for every frame without retaining decoded image storage or losing format changes?

Baseline: `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`.
The baseline presenter calls `CMVideoFormatDescriptionCreateForImageBuffer` for every submitted frame. Both main video and the PiP compositor use this presenter.

The candidate retains one immutable description per presenter. Every lookup uses
`CMVideoFormatDescriptionMatchesImageBuffer`; a miss runs the existing creation,
error-checking, and signpost code. A lock protects lookup, publication, and reset.
Failed creation preserves the previous entry. Presenter flush resets the cache.
Timing, sample-buffer creation, ownership tokens, and renderer submission stay in
their existing paths.

## Correctness and ownership

The focused Swift Testing suite runs against the unchanged production helper in
debug and release. It checks compatible distinct buffers, dimension/pixel-format
transitions, row-stride parity, add/change/remove metadata, in-place attachment
mutation, alternating formats, failed creation, concurrent lookups/resets, and
sample validity after reset/replacement. A CoreVideo release callback establishes
that cached metadata does not keep pixel storage alive.

Each metadata transition is compared with a newly created CoreMedia description
and submitted to `CMSampleBufferCreateReadyWithImageBuffer`. The tests require
fresh-description parity for HDR payloads; they do not assume that every OS copies
every image attachment into its format description.

## Experiment

The standalone driver compiles the real cache with an exact extraction of the
pinned presenter's creation/check/guard block. Both variants use that same factory.
The production signpost implementation is copied unchanged and checked against
the baseline. The candidate includes its real lock and compatibility matcher.

Five workloads use a ring of eight preallocated image buffers:

| Workload | Purpose |
| --- | --- |
| Stable BGRA, BT.709 | Composited/PiP-style metadata |
| Stable NV12, BT.709 | Hardware-decoded SDR-style metadata |
| Stable P010, BT.2020/PQ with HDR10 payloads | HDR-style metadata |
| Alternating BGRA dimensions | All-miss geometry control |
| Alternating NV12 color metadata | All-miss attachment control |

Buffers are 1920 × 1080, except alternating geometry uses 1280 × 720 every other
frame. Pixel allocation, decoding, sample creation, and rendering are outside the
timed region. There is no live playback or player RSS measurement.

Each observation runs in a fresh process, warms up for 2,048 operations, then
measures process CPU and monotonic wall time. Autorelease pools drain every 256
operations in both variants. A dimensions/pixel-format checksum consumes each
result. Construction counting and full output parity checks run separately from
the timed loops.

Eight balanced AB/BA pairs use identical iteration counts within each workload,
calibrated toward 150 ms for the faster variant. The stable cache is warm during
timing; an independent unprimed verification requires one creation for 64
compatible frames. Alternating workloads require 64 creations for 64 frames.

Success is declared only after correctness/ownership checks pass and every stable
workload has median candidate/baseline CPU and wall ratios below 0.95, with at
least seven of eight CPU pairs faster. The all-miss cost is reported separately.
This criterion measures a component improvement; it does not establish a
whole-player speedup or lower resident memory.

## Reproduction

On macOS 26 with the repository's Swift toolchain:

```sh
python3 Benchmarks/VideoFormatDescription/run.py \
  --pairs 8 --target-ms 150 --output /tmp/video-format-description-results
```

Use a new or empty output directory. When the shared Kyoto queue is available,
submit the same command and environment through it as required by `AGENTS.md`:

```sh
python3 /Volumes/seed1/Projects/kyoto/kyoto.py submit -- \
  python3 Benchmarks/VideoFormatDescription/run.py \
  --pairs 8 --target-ms 150 --output /tmp/video-format-description-results
```

Inspect Kyoto's job status, logs, and completion before interpreting results.
The hosted macOS workflow uses isolated direct builds because that shared queue
is unavailable. It also compiles the full app/test graph with pinned native
dependencies and runs the cache and PiP mapping regressions.

`--tests-only` runs both test configurations and real CoreMedia parity/count
checks without timing. Pull requests use that mode; feature-branch pushes run
the complete experiment.

Evidence includes source/binary SHA-256s, the pinned baseline, host/toolchain
information, command receipts, tests, verification, calibration, all raw
observations, paired ratios, and an explicit completion record. Incomplete runs
must not be interpreted as successful.

## API references

- [MatchesImageBuffer](https://developer.apple.com/documentation/coremedia/cmvideoformatdescriptionmatchesimagebuffer(_:imagebuffer:)): compares common format attachments and applicable row stride.
- [CreateForImageBuffer](https://developer.apple.com/documentation/coremedia/cmvideoformatdescriptioncreateforimagebuffer(allocator:imagebuffer:formatdescriptionout:)): creates a description from image dimensions, pixel format, and common attachments.
- [Create](https://developer.apple.com/documentation/coremedia/cmvideoformatdescriptioncreate(allocator:codectype:width:height:extensions:formatdescriptionout:)): copies inputs and deep-copies extensions.
- [Common extension keys](https://developer.apple.com/documentation/coremedia/cmvideoformatdescriptiongetextensionkeyscommonwithimagebuffers()): defines image/description compatibility requirements.

## Results

Native execution and paired measurements are pending. This section will be
updated from completed workflow receipts before recommending a pull request.
