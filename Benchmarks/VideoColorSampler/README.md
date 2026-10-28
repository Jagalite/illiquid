# Video color sampler metadata research

The player optionally samples a 12 × 8 color grid after video enqueue on its
serial presentation executor. The baseline retrieves the same CoreVideo base
addresses and row strides at every grid point. The candidate borrows these
values once per successful read lock, then uses the original pixel addressing
and color arithmetic. No pointer survives the call or is cached on the sampler.

Baseline: `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`.

## Reproduce

On macOS 26 with the Swift 6 toolchain:

```sh
python3 Benchmarks/VideoColorSampler/run.py \
  --output /tmp/illiquid-video-color-sampler --pairs 10 --target-ms 250
```

Use a new output directory. Follow the repository's Kyoto build coordination
rule when the shared queue is available. The dedicated hosted workflow probes
for the queue and explains its absence before building isolated packages.

The runner stages the complete production sampler, PiPVideoMapping, and
VideoColorSample in two separate Swift packages. The only differing source is
the sampler. Both arms use the same harness, tests, Swift 6 mode, and native
CoreVideo APIs. The isolated package uses the toolchain's Testing module; it
does not build the application or replace its pinned dependencies.

## Correctness

Both implementations run the existing sampler and PiP mapping tests plus
layout regression tests in debug and release configurations. Added cases cover
caller-owned padded BGRA rows, independent noncontiguous planar allocations
with different strides, all four YUV format/range combinations, tiny images,
unused P010 low bits, changing matrix attachments, format switches on one
sampler, and unsupported formats. Color expectations use independent equations.

Before timing, complete RGB bit patterns for all 96 samples and the three
aggregates are compared across both implementations and configurations.
The corpus includes 184 raw/stateful traces and 45 native buffer layouts,
including 1080p and 4K buffers. Compressed complete traces are uploaded with
source, compiler, binary, and execution receipts.

## Measurement

Nine cases cover the five supported pixel formats, tiny BGRA, alternating
padded layouts, simulated 60-fps calls with the real 4-Hz sampling gate, and the
unchanged throttled path. Each fresh process creates and fills deterministic
IOSurface-backed buffers outside timing, warms 1,024 invocations, and consumes
sampled output at rotating grid coordinates.

The runner calibrates one common iteration count per case to target at least
250 ms for the faster implementation, then collects ten balanced AB/BA pairs.
It retains every observation and verifies equal output checksums, publication
counts, warmup results, and actual native buffer layouts. Wall and process CPU
times include locking, sampling, output consumption, and autorelease-pool
cleanup. The summary includes all ranges, paired changes, and a seeded paired
bootstrap interval; a duration shortfall is reported rather than hidden.

## Scope

This experiment measures warm component calls using synthetic native buffers.
The default accepted sample cadence is only four times per second and sampling
is optional. Absolute microseconds saved per accepted call matter more than
the relative percentage. These measurements do not qualify live playback,
frame rate, whole-player CPU, UI latency, power, or process memory footprint.

This exploratory variant was not pursued after concurrent PR #133 supplied
native qualification for the same optimization. No performance result is
claimed for this branch. Its workflow is disabled to release its queued run;
the distinct portable follow-up research is on perf/por-diamond-reuse.
