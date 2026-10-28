# Thumbnail sample prefix planning

This experiment measures the CPU service time of `ThumbnailPolicy.samples` and
its `storyboard` wrapper. The baseline fills an entire subdivision round before
taking the requested prefix. The candidate stops as soon as that prefix exists
and returns the initial sample immediately when a clip has only one possible
half-second timestamp.

The sampling arithmetic, focus handling, deduplication and output order are
unchanged. This is independent of thumbnail ranking, playlist neighborhood,
decoder and cache optimizations.

## Reproduce

On an isolated host without the shared Kyoto queue:

```sh
python3 Benchmarks/ThumbnailSamplePrefix/run.py \
  --output /tmp/thumbnail-sample-prefix --pairs 12 --target-ms 80
```

Where Kyoto is available, submit the entire command through it and add
`--kyoto-worker` to the submitted command, then inspect the job's show/logs/wait
receipts as required by `AGENTS.md`. The harness refuses a direct build there.
All builds and tests are serialized.

The frozen baseline is the complete production file from
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`, Git blob
`cf3b96706f34ba5c43041d650f4c9f6217e340cc`. The runner verifies that blob before
building it. It copies the complete candidate file without extracting or
rewriting the measured function. Each variant is compiled into a separate
`IlliquidCore` module, without cross-module optimization, then called by the
same executable.

## Correctness and timing

- Existing policy and scheduling regressions plus new prefix regressions run
  against both variants in debug and release.
- A 4,732-case differential compares every output timestamp's IEEE-754 bits,
  including signed zero, invalid inputs, extreme finite values, short clips,
  duplicated focus, all count boundaries and deterministic generated cases.
- Release timings use 12 fresh-process AB/BA pairs per workload. Both variants
  use the same calibrated iteration count. Workload order rotates each pair.
- Input construction, warmup, full-output validation and JSON are outside the
  timed region. Production calls, count/first/last consumption and array lifetime
  are inside it. Every measurement has a checked observable checksum.
- The normal requests are 6/12/24 samples. A 64-sample power-of-two case, a short
  saturated clip and unchanged `nearby` are controls.
- Wall and process-CPU time are reported separately, with paired speedups and a
  deterministic 95% bootstrap interval for the paired median.
- Output capacity is recorded: returning the prefix directly can retain a few
  extra array slots. This experiment does not claim a memory reduction.

## Scope

The scheduler uses 12 samples by default and 6/12/24 in its presets; counts are
bounded to 1...64. The 24-sample storyboard is also used for current-video
preparation, cached-thumbnail fallback selection and storyboard protection.
The result qualifies sample planning only. It does not establish decode speed,
end-to-end hover latency, playback FPS or energy savings.

Measurement results will be retained here after the experiment completes.
