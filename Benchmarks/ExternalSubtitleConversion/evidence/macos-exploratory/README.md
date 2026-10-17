# Exploratory macOS cohort: reused input string

This directory preserves the completed first native experiment at commit
`1c9d3b763c1c6f4e12126fdc553bf3c2ba9edd0a`, from
[GitHub Actions run 39067042202](https://github.com/Jagalite/illiquid/actions/runs/39067042202),
job `117496752132`, artifact `12113806507`.

**These measurements are exploratory.** Each process reused one decoded input
`String` across its two warmups and all measured conversions. The final harness
decodes a fresh string before each conversion, matching the production source
lifetime more closely. The later fresh-input cohort is recorded separately.
These receipts do not establish the size or direction of any effect caused by
input reuse and must not be substituted for the final cohort's measurements.

The recorded environment was an Apple M1 virtual macOS 26.6.2 runner with Xcode
26.6 and Apple Swift 6.3.3. The campaign completed 10 balanced AB/BA pairs for
each of 15 workloads: 300 fresh-process observations, with five measured
conversions per ordinary process and 125 for each tiny-input process. The
recorded differential passed 5,761 cases; the native converter regression logs
each report 17 tests passing in debug and release. These are original recorded
results, not new executions performed while packaging.

## Retained evidence

- `manifest.json`, `summary.json`, `verification.json`, `fixtures.json`,
  `environment.txt`, and `tests/` are byte-for-byte copies of the uploaded files.
- `measurements.jsonl.gz` contains every original raw measurement row.
- `receipts.tar.gz` contains the full frozen baseline and candidate converter
  sources, the renamed baseline used for differential testing, the exact Swift
  drivers and Python runner, the baseline manifest, all 15 generated fixture
  files, and every command/stdout/stderr receipt. Its archive paths begin with
  `benchmark/`. The archive is about 670 KiB; no compiled products are included.
- `provenance.json` identifies the commit, run, job, artifact, downloaded ZIP
  SHA-256, source hashes, input lifetime, and packaged payload hashes.
- `packaging-verification.json` records the independent integrity checks.

Packaging verified the downloaded ZIP hash and CRCs, all eight recorded source
hashes and byte counts, all 15 fixture hashes and byte counts, the exact baseline
declaration rename, and all 150 complete balanced pairs. Independently
recalculating medians, ranges, paired ratios, speedups, and reductions from the
300 raw rows reproduced every stored workload summary exactly. The original
summary and raw results were left unchanged. The original manifest retains
binary hashes; those binaries were excluded from the uploaded artifact and
cannot be rehashed from this package.

This experiment times full in-memory conversion elapsed time on the recorded
virtual host. It does not establish player startup or track-switch latency,
rendering behavior, CPU time, live memory, allocation volume, or energy use.
