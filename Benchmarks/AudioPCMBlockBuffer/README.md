# Audio PCM sample-buffer allocation research

This native macOS component experiment compares the complete production
`SampleBufferAudioPresenter.makeSampleBuffer` method at baseline
`af1c1add701e49b355448cf8983eaed1e7623108` with the current working source.
The candidate's complete `AudioPCMBlockBuffer.swift` helper is compiled unchanged.

```sh
python3 Benchmarks/AudioPCMBlockBuffer/run.py \
  --pairs 6 --target-ms 200 --retained-frames 32 \
  --output /tmp/audio-pcm-block-buffer
```

Use a new or empty output directory. `--tests-only` builds and compares debug and
release correctness without timing. `--case c8-s8192` selects one workload.
The driver requires macOS/CoreMedia and targets the app's macOS 26 deployment
version. It does not need the native FFmpeg SDK for these component measurements.

## Exact source scope

The runner extracts the entire static sample-creation method, including its
existing format and byte-count validation, into a wrapper enum. No statements
inside the method are rewritten. The complete `NativeDecodedAudioFrame` struct,
`PresentationError`, and `checkOSStatus` come directly from production sources;
the runner requires these shared declarations to be identical across variants.
The helper source is copied byte for byte. Original files, compiled declarations,
compiler and binary hashes, flags, and subprocess receipts are saved.

The fixture driver creates real `CMAudioFormatDescription` objects from an
interleaved float PCM ASBD. It omits channel-label layout metadata because the
tested method checks rate and channel count; the native app tests separately
qualify actual decoder speaker mapping and renderer integration. This is not a
full presenter, FFmpeg decoder, audio renderer, or playback benchmark.

## Memory endpoint

The primary endpoints are **additional live allocator bytes while source PCM
frames and corresponding retained native sample buffers coexist**, and **live
allocator bytes when only the sample buffers remain**. Each fresh
process measures allocator bytes before constructing 32 unique source frames,
after sources exist, after corresponding sample buffers exist, after dropping
the source frames, and after dropping the sample buffers. Autorelease pools drain
at each ownership boundary. All sample bytes are checked after source release.

The C probe reads Darwin `malloc_zone_statistics(NULL).size_in_use`, matching the
repository's existing runtime-lease history experiment. Values include allocator
and runtime effects. They are not RSS, physical footprint, allocation-request
traffic, GPU memory, or an exact sum of payload sizes. The batch is a controlled
retention fixture, not a claim that the application retains 32 audio frames.
Source-address sharing is recorded separately from output equivalence.

The expected benefit is avoiding duplicate PCM backing during this overlap.
After the source is released, either implementation must retain the sample's
payload. Sharing can also keep the source allocation's excess capacity or a large
slice's parent alive. A reduction during overlap alone therefore cannot establish
a memory-management improvement. Samples-only regressions must be reported and
reviewed before accepting the change. Inline
and small buffers deliberately expose any owner-wrapper overhead.

## Workloads, parity, and timing

Mono, stereo, 5.1, and 7.1 fixtures each cover 1, 128, 1,024, and 8,192 sample
frames, at 48 kHz. They contain authored finite float values; each retained frame
uses different bytes. The 1-sample mono/stereo controls include inline `Data`.

All channel counts at 1,024 and 8,192 frames also cover resampler-style storage
allocated larger than output and then shrunk, and the production trimming spelling
`Data(data.dropFirst(offset))` retaining the final quarter of an input. An explicit
pathological control presents an 8 KiB slice of an 8 MiB parent. These expose
capacity retention and prevent claiming a memory win solely from duplicate-copy
avoidance. They are synthetic storage shapes; their occurrence frequency is not
measured here.

Correctness runs in debug and release for both variants. Each workload exercises
owned data, a nonzero-index slice, data bridged from mutable Foundation storage,
copy-on-write mutation, and reading after all source frames are gone. The driver
checks every returned byte against independent expected data and verifies sample
count, size, format, and exact timing. Receipts retain each complete metadata
record plus the PCM SHA-256. Invalid-format and invalid-size cases must preserve
the existing errors. Both variants' complete receipts must match.

The secondary timing endpoint constructs and releases the entire native sample
buffer using the exact production method. Fixtures and format descriptions are
created before timing. Every process warms 512 calls, then consumes returned
sample counts and byte sizes in a checked checksum. Six fresh-process AB/BA
pairs per workload use equal iteration counts calibrated to approximately 200 ms
on the faster variant. Both wall and process CPU time, all raw observations, and
adverse small-buffer controls are retained. Calibration observations are saved
separately and excluded from the summary.

Acceptance criteria are recorded in the manifest before compilation. Correctness
and native app integration are required; a component memory improvement does not
establish whole-player memory, audio latency, energy, or user-visible performance.

## Evidence

No results are asserted until a native run completes. The output contains
`manifest.json`, `commands.json`, four verification receipts, `parity.json`,
`calibration.json`, `measurements.jsonl`, `summary.json`, all original/compiled
source snapshots, and per-command logs. Preserve the evidence from every run,
including failed or adverse results; do not pool unrelated source cohorts.
