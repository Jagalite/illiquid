# Audio-delay PCM ownership

**Status:** The production improvement is tracked in [PR #95](https://github.com/Jagalite/illiquid/pull/95).
A parallel run opened that equivalent fix seconds before this branch's
[PR #97](https://github.com/Jagalite/illiquid/pull/97), which was closed as a duplicate.
This branch preserves independent reproduction and validation evidence.

This experiment investigates memory retained by signed audio-delay padding in
`AudioDelayTimeline`. It compares the complete production timeline at
`6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635` against the current working tree.

## Change and scope

The old timeline allocates fresh zero-filled PCM for every silence chunk and
stores the complete last decoded frame as the template for tail padding. Only
that frame's format metadata is needed after its samples have been emitted or
trimmed. The decode worker can keep the timeline alive while waiting at EOF.

The change keeps metadata without PCM in the template, and shares one immutable
zero-filled `Data` value between full silence chunks within each call to
`silence`. Each frame still has its own presentation time, sample count, duration,
generation, and format metadata. A shorter final chunk gets exact-size storage;
a short interval or one-sample preroll allocates only its required bytes. There
is no persistent silence cache or cross-format cache invalidation.

This affects large positive audio offsets, negative-offset tail padding, and
empty-stream preroll. Ordinary zero-delay playback uses a different decode loop.
The change does not adjust queue capacities, read-ahead policy, resampling,
renderer ownership, or playback timing. Removing the last source reference is
a bounded retention improvement, not a fix for unbounded accumulation.

Source anchors:

- [AudioDelayTimeline.swift](../../Sources/IlliquidNativePlayback/Media/AudioDelayTimeline.swift)
- [MediaSession.swift](../../Sources/IlliquidNativePlayback/Media/MediaSession.swift):
  48-slot `audioFrames` queue and `delayedAudioDecodeLoop`.
- [SampleBufferAudioPresenter.swift](../../Sources/IlliquidNativePlayback/Presentation/SampleBufferAudioPresenter.swift):
  PCM is read and copied into a Core Media-owned block buffer.

## Reproduce

Requires Swift 6.1+, Python 3.10+, and the pinned baseline commit in Git history.
The isolated package does not resolve remote dependencies.

```sh
python3 Benchmarks/AudioDelayMemory/run.py --output /tmp/audio-delay-memory

# Select a Swift toolchain explicitly if necessary.
python3 Benchmarks/AudioDelayMemory/run.py \
  --swift /path/to/swift --output /tmp/audio-delay-memory-alternate
```

The output directory must be new or empty. The default run builds and tests both
implementations in debug and release. `--skip-tests` is for exploration only.

macOS uses Apple's CoreMedia. Linux uses a small, explicitly labeled rational-time
shim solely to run this component's ownership and output comparison. That shim
does not qualify Core Media, hardware presentation, device output, or perceptual
A/V synchronization. The native workflow runs the component experiment with
real CoreMedia and the full application graph's audio regression suites.

## Measurement method

The runner copies the complete timeline source without modification and extracts
the exact `NativeDecodedAudioFrame` declaration and trimming extension from each
revision of `AudioDecoder.swift`. The manifest records original and extracted
source hashes, compiler identity, build configuration, harness hashes, and binary
hashes. Commands and complete test logs are retained.

Twelve scenarios cover ten-second stereo/eight-channel padding, short and partial
chunks, empty fallback, positive delay, negative trimming, format changes, and
canceled emission. Every emitted frame contributes a receipt containing its
timing fields, format metadata, PCM byte count, PCM hash, and whether every PCM
byte is zero. All 962 receipts are compared between revisions in each build mode.
Ten-second cases independently require 480,000 silent samples in 469 chunks.

The consumer retains at most **48 PCM frames**, matching the production queue's
capacity. At each full batch and the final partial batch, nested
`Data.withUnsafeBytes` calls keep all borrowed pointers valid at the same time.
The harness measures the union of the exposed byte ranges before those closures
return. Pointers never escape their borrowing scopes, consistent with
[Apple's pointer-lifetime contract](https://developer.apple.com/documentation/foundation/data/withunsafebytes(_:)).

`uniqueBorrowedPCMBytes` describes the unique PCM payload covered by that retained
batch. It excludes object headers, allocation rounding, spare capacity, producer
locals, Core Media's copy, and unrelated process memory. It is **not** RSS, a heap
allocation count, or cumulative allocated bytes. Adjacent ranges can merge, so
`uniqueBorrowedRanges` is not an allocation count either. Tiny inline `Data`
scenarios are output-size controls; their temporary borrow addresses are not
used to claim heap savings. Batches are drained together for deterministic
measurement, rather than simulating a real renderer's scheduling.

The producer-local full buffer can remain alive while emitting the shorter tail.
If a consumer has already released every full chunk, this can temporarily retain
one extra full buffer (up to 32 KiB for eight channels) compared with allocating
only the tail. That local lifetime is excluded from the queued-payload metric.

A separate custom-deallocator fixture supplies a 4,096-sample, eight-channel
source frame (128 KiB). A non-inlined producer scope returns before the release
count is inspected. This proves whether the timeline alone keeps that allocation
alive after a fully trimmed input. Regression tests also cover accepted and
canceled input, continued consumer ownership, latest-format metadata, partial
and one-sample chunks, and mutation of copied or trimmed silence values.

## Component results

The retained [Linux evidence](evidence/linux/) uses Swift 6.3.2 on Linux x86_64.
Both debug and release produced the following results:

| Retained PCM batch | Before | After | Reduction |
| --- | ---: | ---: | ---: |
| 48 full stereo chunks | 393,216 B (384 KiB) | 8,192 B (8 KiB) | 97.92% |
| 48 full eight-channel chunks | 1,572,864 B (1,536 KiB) | 32,768 B (32 KiB) | 97.92% |
| Final 37 stereo chunks, including the 768-sample tail | 301,056 B (294 KiB) | 14,336 B (14 KiB) | 95.24% |
| Final 37 eight-channel chunks, including the 768-sample tail | 1,204,224 B (1,176 KiB) | 57,344 B (56 KiB) | 95.24% |

Across all sampled batches, maximum observed unique payload coverage changed
from 384 to 14 KiB for stereo and from 1,536 to 56 KiB for eight channels. These
remain component payload measurements, not whole-player peak memory estimates.

The 128 KiB source allocation remained owned by the baseline until timeline
reset; the candidate released it while the timeline remained usable. Actual
source-frame savings depend on decoded block size and other consumers' ownership.

All twelve output scenarios matched in both configurations. Both baseline
configurations passed seven behavior test functions and failed the five expected
ownership test functions. Both candidate configurations passed all twelve focused
test functions, including parameterized channel/count/cancellation cases. The
baseline failures are deliberate negative controls; the runner rejects compiler
errors or unrelated failures as proof of the ownership defect.

## Native qualification

The [Audio delay memory workflow](../../.github/workflows/audio-delay-memory.yml)
runs the same component experiment on macOS 26 with real CoreMedia. It also
generates the required H.264/AAC and 7.1 FLAC fixtures and runs
`AudioDelayMemoryTests`, `AudioDelayTests`, `AudioResamplerDrainTests`, and
`MultichannelAudioTests` in the full application graph. This covers extreme
offsets, prepare/seek/stop, delay replacement, resampler draining, and negotiated
multichannel sample-buffer output. Native qualification was still queued when
this duplicate was closed. Follow [PR #95](https://github.com/Jagalite/illiquid/pull/95)
for the active implementation's native results; no native pass is claimed here.

No CPU-speedup, ordinary-playback RAM, or real-device synchronization claim
follows from this component experiment.
