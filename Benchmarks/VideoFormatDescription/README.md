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

## Results — October 28, 2026

**The original native correctness and performance criteria passed.**
[Run 40637699841](https://github.com/Jagalite/illiquid/actions/runs/40637699841)
qualified candidate `e604eaa8ba8911e952c1b5a5b1b9f5c88a08ef3e` against the pinned
baseline. The later documentation/evidence commit changes no production code,
tests, benchmark, or workflow.

Host: virtual Apple M1, arm64, macOS 26.6.2, Apple Swift 6.3.3 through Xcode 26.6.
Each workload used eight balanced AB/BA pairs and fresh processes. All 80
observations and the excluded calibration probes are retained. The shortest
measured observation contained 97.460 ms of process CPU time.

| Metadata workload | Baseline CPU (µs/lookup) | Cached CPU (µs/lookup) | Paired CPU change | Paired wall change | Faster CPU pairs |
| --- | ---: | ---: | ---: | ---: | ---: |
| Stable BGRA / BT.709 | 4.612 | 2.922 | −34.49% | −34.60% | 8/8 |
| Stable NV12 / BT.709 | 4.548 | 3.128 | −31.66% | −32.23% | 8/8 |
| Stable P010 / HDR | 4.658 | 2.934 | −36.31% | −35.91% | 8/8 |
| Alternating dimensions (all misses) | 4.574 | 4.745 | +4.36% | −1.26% | 2/8 |
| Alternating color metadata (all misses) | 4.510 | 5.421 | +21.42% | +27.13% | 0/8 |

Times are separate per-operation medians. Percentage changes are medians of
within-pair candidate/baseline ratios, so they need not equal the ratio of the
displayed medians. Negative change means less time. Every stable workload met
the predeclared CPU and wall thresholds, with all eight CPU pairs faster.

**Miss overhead is a real tradeoff.** Alternating dimensions increased median
paired CPU time by 4.36%; wall results were mixed. Alternating color metadata
increased CPU time by 21.42% and wall time by 27.13%, with the candidate slower
in all eight pairs. A miss pays matching/locking overhead before the existing
creation path. The protocol required reporting these controls and did not impose
a miss-overhead threshold. These results do not establish a universal speedup.

Separate unprimed verification recorded **one format-description construction
for 64 compatible frames**, versus 64 baseline constructions, for each stable
workload. Both alternating workloads correctly constructed 64 descriptions.
All five workloads passed fresh-description parity and sample-buffer creation.

Executed validation:

- Component debug: **11 tests passed** against the production cache.
- Component release: **11 tests passed** against the production cache.
- Full native application/test graph compiled in release; **13 tests in two
  suites passed**, comprising the cache and PiP video mapping regressions.
- The CoreVideo release-callback test passed while the cache and returned
  description remained alive, establishing that the tested cache does not retain
  decoded pixel storage.
- All 106 recorded component commands succeeded. Independent review recomputed
  all paired CPU results, verified pair counts/order/checksums, and checked
  the component test-log hashes.

See the [component job](https://github.com/Jagalite/illiquid/actions/runs/40637699841/job/122648368700)
and [native application job](https://github.com/Jagalite/illiquid/actions/runs/40637699841/job/122648368447).
[Committed evidence](evidence/2026-10-28-native) preserves all ten files emitted
by the component workflow, plus the complete native application job log.
[provenance.json](evidence/2026-10-28-native/provenance.json) records their
SHA-256 digests and the exact measured commit. The original Actions artifact is
additional temporary storage; these committed receipts do not depend on its
retention period.

This measures CoreMedia metadata preparation with the production cache, lock,
matcher, creation/error-checking block, and signposts. It excludes decoding,
sample-buffer construction, rendering, and live playback. The reduced creation
count is evidence of avoided metadata work, not a measurement of allocation
bytes, peak heap, player RSS, energy, or frame rate. Only one description is
retained per presenter; flush clears it.
