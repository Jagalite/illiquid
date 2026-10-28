# Thumbnail sample planning

Research target: constructing the ordered, half-second timestamp list used by
foreground cache fallback, current-video storyboard preparation, and background
thumbnail generation. The production defaults request 6, 12, or 24 samples.

The baseline completes an entire binary-subdivision round before checking the
requested count, then copies the requested prefix. Short clips can keep probing
duplicate positions through all 128 divisions. The candidate reserves only the
bounded output size and stops when that ordered prefix is complete or all
possible half-second positions have been found.

## Reproduce

The baseline is main commit
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`.
Use a checkout containing that commit, Python 3.10+, and Swift 6.1 or later.
Run through the shared Kyoto queue when available, as required by AGENTS.md.
On a host without Kyoto, explain that limitation before running directly.
The driver serializes all builds and measurements.

```sh
python3 Benchmarks/ThumbnailSamplePlanning/run.py \
  --pairs 8 --target-ms 80 --output /tmp/illiquid-thumbnail-samples-new
```

The output directory must not already exist. Use `--mode tests` or `--mode benchmark`
to run one part of the campaign.

The driver compiles the complete, actual ThumbnailPolicy.swift from both the
pinned baseline and the checkout, using identical release flags. The existing
thumbnail policy and scheduling tests plus new exact-order regressions run
against both versions in debug and release. The regression oracle freezes the
old function; independent golden arrays and boundary/randomized inputs protect
against accidentally changing its arithmetic or ordering.

Timing uses a prebuilt corpus, a warmup, and eight alternating baseline/candidate
and candidate/baseline pairs per workload. Input construction, compilation,
process startup, result encoding, and correctness tests are outside the timer.
Each measured operation creates one plan; a common small checksum consumes its
count and selected timestamps. Matching checksums and output counts are required
for every pair. Timing and process CPU results are retained separately.

The two storyboard workloads call the public storyboard wrapper. Three
background workloads use the 6/12/24 presets; short clips exercise exhausted
quantization; 64 samples with zero focus exercise a complete-round control.
One-sample and invalid-duration cases cover very small workloads. Raw measurements,
calibration, source/test hashes, commands, compiler/host information, source
snapshots, and test logs are retained in the result directory and CI artifact.

## Scope

This is a component benchmark. It does not measure image decoding, disk reads,
cache hit rate, end-to-end hover latency, playback CPU, or energy. Large relative
gains in a small planning function must be interpreted with their absolute
nanoseconds per plan. The patch preserves the 128-division ceiling and existing
extreme-finite-double overflow behavior; it is not a numerical-behavior change.

Measured results and qualification links will be added after the research run.
