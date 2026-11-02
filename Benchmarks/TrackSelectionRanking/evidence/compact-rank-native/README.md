# Compact-rank native replication evidence

[Native run 40633913283](https://github.com/Jagalite/illiquid/actions/runs/40633913283)
qualifies commit `4c55b401e13b101158753dc0c75f7b3e3c0f1e63` against baseline
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`. Production sources, harness,
runner, tests, and both source manifests are byte-identical to the
[initial cohort](../compact-rank-initial/README.md). Only the workflow's number
of measurement pairs and calibration target changed.

The 640 final observations cover twenty balanced AB/BA pairs per workload,
with a 250 ms calibration target. Actual measured intervals range from
248.8 to 518.7 ms. Both variants passed all 13 behavior tests in debug and
release, and their complete 55,296 selected-ID receipts agree.

- `summary.json` retains all 16 workloads' medians, ranges, paired ratios,
  iteration counts, and absolute differences.
- `provenance.json` records the exact source and compiler hashes, SDK,
  Actions identifiers, artifact digest, and receipt-audit results.
- `receipts.zip` is the unmodified 474,082-byte Actions artifact. SHA-256:
  `dea15859340fce7cc9da8e2beebe12bf93021831654a81959f7b6fe12dc7b5c2`.
  It includes calibration and final measurements, every process log,
  complete selection receipts, test logs, and build manifests.

The [research report](../../../../Documentation/TRACK_SELECTION_COMPACT_RANK_PERFORMANCE.md)
reports both cohorts and their limitations. The target ranking improvements
reproduced; the initial automatic-subtitle and forced-audio-fallback slowdowns
did not reproduce.

Recompute the summaries from the original rows:

```sh
unzip -q Benchmarks/TrackSelectionRanking/evidence/compact-rank-native/receipts.zip -d /tmp/compact-rank-native
python3 Benchmarks/TrackSelectionRanking/run.py summarize --output /tmp/compact-rank-native/benchmark
```
