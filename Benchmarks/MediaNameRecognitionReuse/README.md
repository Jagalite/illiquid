# Media-name recognition: reuse folder evidence

This experiment measures the complete
MediaNameRecognition.recognize(relativePath:) operation. Episode recognition
previously parsed the same folder title/year more than once. The candidate
reuses the parsed folder result within one call. It retains filename priority,
the explicit-year requirement for an ordinary parent, and the existing
case-insensitive folder enrichment rule. It adds no cross-file cache.

## Reproduce

Use one Swift 6.1+ toolchain for both swift and swiftc, and Python 3.9+:

```sh
python3 Benchmarks/MediaNameRecognitionReuse/run.py \
  --output /tmp/illiquid-media-name-recognition --pairs 6
```

The output directory must be empty. Use --mode tests for just regressions or
--mode benchmark for timings and full-result parity. The isolated package uses
the exact production source and the toolchain's Swift Testing module, without
downloaded package dependencies. The native workflow uses macOS 26 and Xcode 26.6.

## Method

- Baseline: the complete production file at commit
  68274d1b09dcc866296321a5a8858efc297c4f19, verified against its Git blob identity
  in baseline/manifest.json.
- Candidate: the complete current production file. Each variant is compiled as
  a separate optimized IlliquidCore library; the driver links it separately.
- Identical flags: -swift-version 6 -O -whole-module-optimization.
- Tests: existing recognition tests and seven new tests with 26 explicit
  complete-result expectations, against both versions in debug and release.
- Parity: compare all 258 complete verification records, including all stored
  fields and the computed seriesTitle, displayName, and section.
- Twelve timed cases, each containing 16 deterministic paths. Cases include
  folder-only episodes with/without a year, specials, named episodes, differing
  filename/folder titles, ordinary parents with/without a year, Unicode
  filenames, and a mixed batch. Movies, dated episodes, and unknown filenames
  are controls.
- One iteration is one complete recognition call plus a stable FNV hash of
  every stored result field. Hashing and call-loop overhead are included.
  Fixture generation, preflight, warmup, computed display formatting, and
  JSON encoding are outside the timers. No control time is subtracted.
- Fresh process per case/variant/pair, serial execution, and balanced AB/BA order
  for the default six pairs. A baseline CPU-time pilot calibrates toward 150 ms;
  both variants use the same iteration count, rounded to a 16-path batch.
- Both wall and process CPU time are retained. Each timed checksum must match
  preflight expectations and the paired variant. Full-result parity is a
  separate check, not inferred only from each variant's own checksum.

The driver also supports --verify and --list-cases. Its command-line help
describes the standalone options. Fixture frequencies are research inputs,
not measured user traffic.

## Evidence and interpretation

The runner retains exact compiled sources, test/driver/runner inputs, all four
test logs, full baseline/candidate verification records, calibration records,
all timed observations, ranges and paired ratios, source hashes, toolchain/host
information, and command receipts. The workflow uploads these as the
media-name-recognition artifact; transient binaries and module caches are
excluded.

Timing differences are reported, not used as a flaky CI threshold. Compilation
errors, failed tests, changed baseline content, or output mismatches fail the
run. The research report records accepted results and controls after native
qualification.

These component measurements do not establish whole-library scan latency,
filesystem or sidecar I/O savings, playback FPS, memory use, or battery life.
The production change is confined to parsing reuse in the episode branch.
