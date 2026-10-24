# Audio-delay PCM memory research

## Result

Sharing immutable silence payloads reduces the distinct PCM storage for a
48-frame silent audio queue by **97.9%** in the measured component experiment.
For 7.1 audio, that is **1,572,864 bytes (1.5 MiB) to 32,768 bytes (32 KiB)**.
The audio-delay timeline also stops retaining the last real decoded PCM payload
when it only needs that frame's format metadata.

The production change is confined to
[`AudioDelayTimeline.swift`](../Sources/IlliquidNativePlayback/Media/AudioDelayTimeline.swift).
The frozen baseline is main commit
`6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635`. The later main commit
`1bf90fe673a062d100070abde2d793fed77588d4` has the same timeline and audio-decoder
blobs; the intervening subtitle-converter merge does not affect this experiment.

These are live PCM payload and component service-time measurements on Linux
x86-64, Swift 6.3.2. They do not measure total player RSS, playback startup time,
or native renderer memory. Native CoreMedia and full playback regression runs
are provided by the accompanying macOS workflow; their status is reported by CI.

## Why this path retained unnecessary memory

Positive audio offsets insert silence before the first shifted audio frame.
Negative offsets trim early samples and may pad the exhausted tail. The delay
is bounded to ±10 seconds, and silence is emitted in at most 1,024-sample chunks.

Previously, every chunk constructed a separate zero-filled `Data`. A ten-second
48 kHz offset emits 468 full chunks and a 768-sample tail: 469 silent frames with
identical full-chunk contents. The decoded-audio queue in
[`MediaSession.swift`](../Sources/IlliquidNativePlayback/Media/MediaSession.swift)
holds at most 48 frames, so many identical silent payloads could remain live
together while awaiting presentation.

Separately, `consume` stored the complete input frame in `template`, extending
the lifetime of its PCM through the timeline's next input or destruction.
`finish` needs the latest format fields but supplies new silence bytes; it does
not need the input PCM.

## Change and ownership safety

Each `silence` invocation now creates one immutable full-chunk payload when
needed. All full chunks share it. A final partial chunk receives an exact-sized
allocation, preserving the presenter's byte-count contract. There is no
persistent buffer pool and no new synchronization.

The template keeps an empty-PCM frame with the latest generation, output/source
formats, layout, conversion/downmix flags, and format revision. It uses zero
samples and duration, following the existing metadata-only storage pattern in
[`AudioDecoder.swift`](../Sources/IlliquidNativePlayback/Media/AudioDecoder.swift).

The consumer path supports this ownership:

- `NativeDecodedAudioFrame` exposes PCM as an immutable `Data` value.
- Queue admission and presentation do not mutate that payload or require unique
  backing storage.
- [`SampleBufferAudioPresenter.swift`](../Sources/IlliquidNativePlayback/Presentation/SampleBufferAudioPresenter.swift)
  allocates its own `CMBlockBuffer` and copies the supplied bytes. That copy
  remains; this change does not transfer borrowed storage to CoreMedia.
- Emission order, sample counts, timestamps, metadata, rejection handling, and
  cursor advancement remain the same.

## Measured storage

The harness retains 48 full silent chunks and rejects the next emission. It
then inspects every payload while all owners are still alive. The bytes below
are the sum of the logical sizes at distinct live payload addresses, excluding
allocator overhead, spare capacity, source/in-flight frames, and renderer copies.

| Output format | Logical PCM bytes in queue | Baseline unique payloads | Updated unique payloads | Baseline distinct payload bytes | Updated distinct payload bytes |
| --- | ---: | ---: | ---: | ---: | ---: |
| Stereo | 393,216 | 48 | 1 | 384 KiB | 8 KiB |
| 5.1 | 1,179,648 | 48 | 1 | 1,152 KiB | 24 KiB |
| 7.1 | 1,572,864 | 48 | 1 | 1,536 KiB | 32 KiB |

All three formats preserve identical logical PCM and reduce distinct queued
payload bytes by 47/48, or 97.9%. Debug and release builds agree.

A separate stress case retains every silent frame of a ten-second offset.
Across stereo, 5.1, and 7.1, the baseline has 469 live payloads; the updated code
has two: one full chunk and the final partial chunk. For 7.1 this is 15,360,000
bytes to 57,344 bytes (56 KiB). This establishes sharing across the complete
sequence; it is **not** the production queue's resident-memory saving.

The custom-deallocator experiment also reproduces the template's extra ownership.
After a 15,360-byte input leaves caller scope and its emitted output is discarded,
the baseline records zero releases while the timeline remains alive. The updated
code records one release. The timeline then successfully finishes using its
retained format. Both passed-through and fully trimmed inputs show this result.

Raw observations:
[`ownership-debug.json`](../Benchmarks/AudioDelayMemory/evidence/linux/ownership-debug.json)
and
[`ownership-release.json`](../Benchmarks/AudioDelayMemory/evidence/linux/ownership-release.json).

## Timing and tradeoffs

Six fresh-process pairs per workload use balanced AB/BA ordering. Release builds
use `-O -whole-module-optimization`. Inputs are prepared before timing; the
emitter retains frames in a 48-slot ring and consumes an output checksum. The
measurement covers timeline service work, without decoder, presenter, blocking,
or real-time playback pacing.

| Workload | Baseline median | Updated median | Median paired time reduction |
| --- | ---: | ---: | ---: |
| Zero delay, stereo control | 0.458 µs | 0.473 µs | −12.0% |
| +100 ms, stereo | 1.789 µs | 1.449 µs | 21.9% |
| +10 s, stereo | 162.834 µs | 83.513 µs | 54.9% |
| +10 s, 7.1 | 313.933 µs | 46.286 µs | 85.2% |
| −10 s, 7.1 tail padding | 311.031 µs | 46.340 µs | 85.2% |
| Empty-stream one-sample control | 0.208 µs | 0.259 µs | −22.8% |

Percentages are medians of paired changes, not ratios of the two displayed
medians. Timing is noisy on this shared host: one stereo ten-second pair was
2.1% slower, while all measured 7.1 long-padding pairs improved by over 81%.
All individual observations and pair ranges are retained. The zero-delay and
one-sample controls did not improve in this run; their displayed medians increased
by about 15 ns and 52 ns respectively. No playback-speed claim follows from
these component timings.

See [`summary.json`](../Benchmarks/AudioDelayMemory/evidence/linux/summary.json),
[`observations.json`](../Benchmarks/AudioDelayMemory/evidence/linux/observations.json),
and [`calibration.json`](../Benchmarks/AudioDelayMemory/evidence/linux/calibration.json).

## Correctness qualification

- **154 scenarios**, **599 operations**, and **1,929 emitted callbacks** compare
  exactly between baseline and candidate in both debug and release.
- Each run compares **40,500,000 raw PCM bytes** plus complete frame metadata,
  raw time fields, operation return values, accepted/rejected emissions, and
  cursor bit patterns. Full transcripts are compared byte-for-byte before their
  SHA-256 receipts are recorded.
- Cases cover positive/negative/zero offsets, bounded/nonfinite delays,
  partial/full trimming, seek targets, source-format changes, empty streams,
  partial tails, and rejected emissions followed by retries.
- The three existing pure audio-delay test functions pass for both variants in
  debug and release. The candidate also passes six new ownership test functions
  (14 parameterized cases) for shared backing, copy-on-write isolation, source
  lifetime, metadata changes, exact tail sizes, and rejection behavior.
- A baseline negative control fails the selected sharing/lifetime tests as
  expected, confirming they detect the previous behavior.
- An independent review checked the production consumer path, lifetime safety,
  source provenance, live-address methodology, and exact transcript comparison.

The Linux boundary shim only supplies finite rational media times. Native
CoreMedia parity and full-app audio behavior must be judged from the macOS CI
results, not inferred from the Linux shim.

## Reproduction and scope

The [benchmark README](../Benchmarks/AudioDelayMemory/README.md) gives the command,
source-extraction rules, measurement details, and evidence inventory.
The [manifest](../Benchmarks/AudioDelayMemory/evidence/linux/manifest.json) records
the baseline identity and exact production, test, and harness hashes.

The benefit is concentrated in inserted silence and the lifetime of the last
decoded frame. This work does not optimize general audio decoding, eliminate
CoreMedia's PCM copy, or demonstrate a percentage reduction in total player
memory.
