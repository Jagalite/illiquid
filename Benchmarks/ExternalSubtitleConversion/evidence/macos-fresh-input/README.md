# Final macOS cohort: fresh input string per conversion

This directory preserves the completed native experiment at commit
`de1b4be4906c9a0446476b39993c4c75168263b7`, from
[GitHub Actions run 39067528346](https://github.com/Jagalite/illiquid/actions/runs/39067528346),
job `117498173448`, artifact `12114296096`.

**Each conversion receives a fresh decoded input `String`.** Fixture `Data` is
loaded once per process. Inside each warmup or measured iteration's autorelease
pool, the driver decodes a new string before starting the timer. That string is
converted once and stays alive through output consumption. Decoding, input and
output destruction, and pool draining occur outside conversion timing. Code and
the runtime receive two warmups. This is the final source-lifetime protocol;
the earlier reused-string experiment is retained separately as exploratory.

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
  `benchmark/`. The archive is about 673 KiB; no compiled products are included.
- `provenance.json` identifies the commit, run, job, artifact, downloaded ZIP
  SHA-256, source hashes, input lifetime, and packaged payload hashes.
- `packaging-verification.json` records the independent integrity checks.

Packaging verified the downloaded ZIP hash and CRCs, all eight recorded source
hashes and byte counts, all 15 fixture hashes and byte counts, the exact baseline
declaration rename, and all 150 complete balanced pairs. Every raw row agrees
with the manifest and summary on fresh-string source lifetime. Independently
recalculating medians, ranges, paired ratios, speedups, and reductions from the
300 raw rows reproduced every stored workload summary exactly. The original
summary and raw results were left unchanged. Decompressing each retained archive
reproduced the corresponding ZIP entries byte for byte. The original manifest
retains binary hashes; those binaries were excluded from the uploaded artifact
and cannot be rehashed from this package.

These are full in-memory conversion elapsed-time measurements on the recorded
virtual host. Read all workload results, including fallback costs, rather than
treating the largest improvement as representative. This cohort does not
establish player startup or track-switch latency, rendering behavior, CPU time,
live memory, allocation volume, energy use, or physical-device performance.
