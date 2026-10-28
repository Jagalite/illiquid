# Audio PCM presentation ownership

## Question and change

Can audio presentation retain decoded immutable PCM instead of allocating and
copying it into a second CoreMedia block for every sample buffer?

The baseline is the exact pre-change main revision
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`.
`SampleBufferAudioPresenter.makeSampleBuffer` previously created an empty
`CMBlockBuffer` and filled it with `CMBlockBufferReplaceDataBytes`.
The candidate preserves validation, formats, sample counts, and timing, and asks
`AudioPCMBlockBuffer` to retain the existing immutable bytes.

The helper bridges `Data` to immutable `NSData`. Its custom allocation callback
retains that owner when CoreMedia acquires the block; its free callback releases
the same owner. Immediate allocation is required so the initially unretained
callback context cannot outlive its local owner. A failure before allocation has
no manual retain to unwind. Consumers must treat these PCM blocks as read-only.

Primary API contracts:

- [NSData.bytes](https://developer.apple.com/documentation/foundation/nsdata/bytes)
  specifies pointer validity for the immutable owner's lifetime.
- [Custom block source](https://developer.apple.com/documentation/coremedia/cmblockbuffercustomblocksource)
  defines the allocation/free pair.
- [Immediate allocation](https://developer.apple.com/documentation/coremedia/kcmblockbufferassurememorynowflag)
  prevents deferred access to the initially unretained context.
- [FreeBlock](https://developer.apple.com/documentation/coremedia/cmblockbuffercustomblocksource/freeblock)
  is not called if no memory block was allocated or supplied.

## Reproduction

On a native macOS 26 host with Xcode:

```sh
python3 Benchmarks/AudioPresentationMemory/run.py \
  --pairs 6 --target-ms 80 --output /tmp/illiquid-audio-pcm-results
```

The runner compiles serially in a separate output directory and refuses a
nonempty destination. It requires full git history for the pinned baseline.
The repository's Kyoto build coordination applies when the shared queue is
available; the hosted workflow explicitly records its absence before building.

The component uses the exact production sample-buffer method, exact decoded
frame declaration, and exact error helpers extracted with unique anchors.
The candidate's ownership helper is compiled unchanged as a complete file.
No CoreMedia or Foundation shims are used. The standalone format description
omits speaker layout; the separate native app job compiles the full class and
tests the production channel layout and playback integration.

Receipts include input/staged/binary hashes, baseline and candidate revisions,
compiler commands, OS/CPU/compiler metadata, exact verification results, memory
inventories, raw paired observations, and completion status.

## Validation and acceptance

Before accepting the change:

1. All 72 PCM/timing cases must agree between baseline and candidate in both
   debug and release. Cases cover 1/2/6/8 channels, 44.1/48/96 kHz, 1/257/1,024
   samples, and ordinary/nonzero-index data.
2. The native test suite must verify ordinary heap storage sharing, final-owner
   release, multiple sample/block owners, caller copy-on-write isolation,
   inline data, misaligned slices, malformed frames, empty input, and structure
   allocation failure. Full app compilation and existing audio delay,
   resampler drain, and multichannel integration tests must pass.
3. Every measured heap-backed scenario must share the source PCM bytes. The
   baseline must demonstrate the duplicate payloads as a negative control.
   Shared silence must retain one payload across the sample-buffer batch.
4. Inspect common 1,024/4,096-sample paired timings for material regressions.
   A median slowdown exceeding 5% requires investigation before acceptance.
   Report tiny-buffer controls independently; they are not the normal decode
   workload. Timing is deliberately not a flaky CI assertion.

Fixtures and format descriptions are built outside timed intervals. Each timing
observation includes creation and destruction of sample buffers, result
consumption, and autorelease-pool scope. Six fresh-process pairs alternate A/B
order with identical calibrated iteration counts and checksum agreement.

The 48-buffer workload matches the scale of the decoded audio frame queue
in `MediaSession`, not the renderer's measured queue depth. The 469-buffer
shared-silence workload is a synthetic long-delay stress case, not live playback.

## Limits

Pointer inventories count distinct live logical PCM spans. They do not measure
allocator block size, Foundation/CoreMedia wrapper overhead, device memory, or
whole-player RSS. The raw Darwin high-water RSS fields are secondary evidence.

Ordinary PCM no longer needs a duplicate payload while the frame and sample
buffer overlap. Once the source frame is released, both implementations may
retain one payload, so unique PCM does not imply a permanent 50% memory saving.
Shared silence is different: many sample buffers can retain the same PCM bytes.

Foundation may materialize tiny inline data. A slice or a decoder allocation
whose count has shrunk can keep a larger backing allocation alive. These cases
remain correct but prevent an unconditional claim of lower RSS for every input.
Allocation-failure injection covers failure before successful block acquisition;
the later failure path relies on CoreMedia's allocation/free ownership contract.

No audible device QA, interactive latency, full-player CPU reduction, or complete
application test-suite result is implied by this component investigation.
