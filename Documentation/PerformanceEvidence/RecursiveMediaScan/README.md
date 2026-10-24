# Recursive media scanner evidence

The [research report](../../RECURSIVE_MEDIA_SCAN_PERFORMANCE.md) explains the
change, timing boundary, findings, and limits. The
[runner](../../../Benchmarks/RecursiveMediaScan/README.md) documents reproduction.

## Linux cohort

`linux/` contains the complete eight-pair local qualification against baseline
`7f9ba073394b77a908e0589447c6edc8d10b832c`. Its candidate production, tests, and
harness match published commit `a8ed1e86a82ce8000044ff424f9a140e21d4a51f`.
The measurements were collected before that commit was published; original
working-tree provenance is preserved rather than rewritten.

- `summary.json` reports process medians, ranges, and median paired ratios.
- `measurements.jsonl` retains every timed scan in each measured process.
- `environment.json` identifies the host, compiler, sampling, and harness hashes.
- `tests.json` and `checkout-verification.json` record successful test runs and
  final source attribution.
- `qualification.json` maps the measured sources to the published commit and
  records the complete archive's SHA-256.
- `evidence.tar.gz` retains the full output: exact command/test logs, source and
  binary hashes, complete ordered receipts, fixture specifications, harness
  inputs, and compressed staged source packages. Build products are excluded.

Percentages use paired observations. Taking a ratio of the two independently
computed medians can produce a different number. These synthetic warm scans
do not measure whole-player latency or playback performance.
