# Audio-delay PCM ownership

This experiment runs the real `AudioDelayTimeline` before and after immutable
silence-payload sharing and metadata-only template retention. See the
[research report](../../Documentation/AUDIO_DELAY_MEMORY_PERFORMANCE.md) for
results and limitations.

```sh
python3 Benchmarks/AudioDelayMemory/run.py \
  --output /tmp/illiquid-audio-delay-results --pairs 6 --target-ms 80
```

Use a new/empty output directory and a Swift 6.1+ toolchain on `PATH`, or pass
`--swiftc /path/to/swiftc`. The recorded Linux run uses Swift 6.3.2. No FFmpeg,
libass, external Swift packages, or player build is needed for the component
experiment. The macOS workflow also builds the real app graph and runs the
native audio-delay/seek/stop regressions with generated media fixtures.

## What is executed

- The frozen baseline is the exact `AudioDelayTimeline.swift` at commit
  `6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635`. Its SHA-256 and Git blob identity
  are checked before compilation.
- The candidate is read directly from the production source. Both variants use
  the actual `NativeDecodedAudioFrame` and `trimmingSamples` implementation
  extracted from `AudioDecoder.swift`; its baseline hash is checked too.
- macOS uses native CoreMedia. Linux removes only the CoreMedia import and uses
  the documented finite-rational `CMTime` boundary in `Platform.swift`. Linux
  results validate Foundation/Data ownership and component parity, not native
  CoreMedia clock behavior or playback.
- Debug and optimized builds compare the complete raw PCM transcript plus every
  frame's timestamp, duration, format fields, generation, revision, rejection
  decision, and the cursor after each operation. `cases.py` supplies 48 named
  scenarios, 100 seeded scenarios, and six measurement workloads.
- The three existing pure audio-delay tests run against both variants. The six
  new ownership test functions also run against the candidate. A baseline
  negative control must fail the selected sharing/lifetime tests after reaching
  test execution.

## Memory observations

The queue-sized case retains 48 full 1,024-sample frames, matching the production
decoded-audio queue capacity, and rejects the next emission. All owners remain
alive during address inspection. The reported `unique_payload_bytes` sums the
logical sizes of simultaneously live, distinct payload base addresses. These
heap-sized, unsliced buffers avoid inline-Data and allocation-address-recycling
artifacts.

The separate 469-chunk case retains every silent frame of a ten-second delay to
demonstrate full-chunk and exact-tail storage sharing. That is a stress case;
the production queue does not retain the entire ten-second output.

A custom `Data` deallocator separately records whether real source PCM is
released while the timeline is still alive and can finish using its format.
Both a passed-through source and a completely trimmed source are exercised.

These are owned-payload observations. They exclude allocator capacity/overhead,
source and in-flight frames, decoder memory, and the presenter's CoreMedia copy.
They are not process RSS or total player-memory measurements.

## Timing observations

Release binaries use `-O -whole-module-optimization` and Swift 6 checking.
Inputs are constructed before timing. Each invocation exercises the production
timeline with a 48-slot retaining emitter; ring writes and an output checksum
keep its work observable. It does not model queue blocking, decoding, playback
pacing, or the CoreMedia presenter.

Each workload uses baseline-calibrated iterations and six fresh-process pairs
in balanced AB/BA order. `summary.json` reports each variant's median and the
median/minimum/maximum **paired** time change. Individual slower samples are
retained in `observations.json`; small nanosecond changes are not playback claims.

## Evidence

`evidence/linux/` contains the verbatim generated source/compiler manifest,
case inventory, exact-comparison receipts, ownership observations, test logs,
negative-control log, commands, timing samples, and summaries. Temporary binaries
and raw transcripts are under the ignored `build/` directory. Reproduction
compares raw transcripts exactly before recording their SHA-256 receipts.

The workflow `.github/workflows/audio-delay-memory.yml` runs the same component
experiment with native CoreMedia and separately runs full native audio tests.
Its artifacts preserve the results and logs.
