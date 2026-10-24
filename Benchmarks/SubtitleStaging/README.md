# Subtitle staging benchmark

This benchmark measures the production `ASSSubtitleFramePacker` CPU preparation
after stable-size and large-to-small subtitle frames. The complete findings,
methodology, and limits are in
[`SUBTITLE_STAGING_PERFORMANCE.md`](../../Documentation/SUBTITLE_STAGING_PERFORMANCE.md).

```sh
python3 Benchmarks/SubtitleStaging/run.py test
python3 Benchmarks/SubtitleStaging/run.py test --configuration release
python3 Benchmarks/SubtitleStaging/run.py benchmark --output /tmp/subtitle-staging-run
```

The benchmark requires Swift 6.1 or newer and a checkout containing baseline
commit `8c3cc3d4008d5d1b8d436bcf2d51d891382b6548`. Recorded runs use Swift 6.3.2
on Linux and Apple Swift 6.3.3 on macOS.
macOS builds target the application's macOS 26 deployment version. The portable
component build needs no native media SDK or third-party package downloads.

`run.py` extracts complete production declarations without rewriting their
logic. It compiles independent baseline/candidate executables with the same
`Main.swift`, checks their active-frame receipts, then runs ten alternating
fresh-process pairs per workload. Initial allocation and the first cleanup of
each formerly large slot are excluded from steady-state timing.

The current differential verifier compares every active pixel, geometry and
upload field. Each variant also checks that unused tail bytes are zero and
that complete previously returned snapshots remain unchanged. Independent
staging-slot capacities may differ. The original checked-in study receipts
below retain their historical whole-buffer comparison and source hashes;
they have not been rewritten. Current timing workloads warm both slots at
the same size, so their retained-storage equality check remains a control.

Use `--case r8-large-to-small` to run one workload or `--repetitions 2` for a
quick smoke run. The built driver also supports:

```sh
/tmp/subtitle-staging-run/candidate/subtitle-staging list
/tmp/subtitle-staging-run/candidate/subtitle-staging verify
/tmp/subtitle-staging-run/candidate/subtitle-staging transition r8-large-to-small 1
```

The checked-in `RESULTS-linux.json` and `RESULTS-macos.json` each contain all
240 timing observations, source/compiler/executable receipts, summary ranges,
and output verification.
`TRANSITIONS-linux.json` records the first six smaller frames for three
large-to-small workloads. `VALIDATION.json` and the test logs record the focused
debug/release checks and the expected old-counter failures. `VALIDATION-macos.json`
records the successful macOS component, benchmark, and native regression jobs;
`TESTS-*-macos.log` preserves their test output.

The baseline clear counter is inaccurate: it reports active upload bytes when
the original helper clears the historical allocation. The research report
explains how the original reset footprint follows from the actual source.

These measurements describe changed-frame CPU preparation. They do not measure
the entire player, process memory, Metal GPU work, or energy use. CI publishes
separate macOS evidence and executes the native subtitle regression suites.
