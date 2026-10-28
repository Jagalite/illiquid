# Video color sampler layout research

This experiment compares the complete production video color sampler against
the version at `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`. The candidate resolves
CoreVideo plane addresses and row strides once inside each existing read lock,
then uses that local layout for the 12 x 8 sample grid.

The sampler's default admission rate is four samples per second. This is a native
component experiment; it does not establish decoding throughput, playback FPS,
GPU cost, live UI responsiveness, memory savings, or battery consumption.

## Reproduce

Use macOS 26 with Swift 6.1 or newer. Follow the repository's Kyoto build
coordination rule when the queue is available. On an isolated runner without
Kyoto, run:

```sh
python3 Benchmarks/VideoColorSamplerLayout/run.py \
  --output /tmp/video-color-layout-results --pairs 12 --target-ms 250
```

The output directory must not already exist. `--tests-only` retains native
compilation, exact differential verification, and debug/release tests for both
variants while omitting timing. The workflow uses this mode for PR checks.

## Method

- The frozen baseline is verified against its pinned Git commit. Candidate,
  support, harness, test, runner, and binary hashes are retained in the manifest.
- Complete production sources build as separate `IlliquidCore` and
  `IlliquidNativePlayback` libraries. The harness cannot specialize the production
  implementation using fixture constants. No CoreVideo or color types are mocked.
- Differential traces compare all 288 RGB Double bit patterns per returned
  sample, dimensions, and nil decisions. They exercise all five formats,
  tiny/odd packed layouts, padded planes, multiple sizes, all recognized matrix
  attachments plus absent/unknown values, matrix mutations, changing layouts,
  unsupported inputs, throttling, smoothing, reset, and clock rollback.
- Both existing sampler tests and the new layout tests run against baseline and
  candidate in debug and release. Independent expected-color assertions
  complement the exact differential comparison.
- Timed work includes the complete sampler call, lock/unlock, attachment lookup,
  color-array allocation, and a checksum consuming every output channel.
  Buffer construction, pattern filling, verification, and logging are outside.
- Each case calibrates both variants to at least 250 ms, then runs 12 balanced
  AB/BA pairs in fresh processes with identical iteration counts and fixtures.
  Per-pair seeds vary. Raw wall and process CPU observations, losing pairs,
  checksums, publication counts, and actual row strides are retained.
- Cases include BGRA/NV12/P010, video/full ranges, 1080p and 4K, alternating
  layouts, admitted/steady stateful sampling, and throttled/unsupported controls.
  Results are per sampler call, not per decoded video frame.

Native integration separately compiles the complete application graph with the
repository's pinned dependencies and runs the sampler and PiP mapping suites.

Measurements will be recorded here after the research run completes.
