# Initial compact-rank native evidence

[Native run 40633467004](https://github.com/Jagalite/illiquid/actions/runs/40633467004)
compares the production change at `3169391027fe2873743708784f0bcdc5fdbc66ea`
with current-main baseline `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`.

The 320 final observations comprise ten balanced AB/BA pairs for each of 16
workloads, using a 100 ms calibration target. Both variants passed 13 tests
in debug and release, and all 55,296 selected-ID outputs agreed.

The candidate reduced no-language ranking costs, but the automatic-subtitle
control and forced audio-language fallback also showed apparent slowdowns.
This prompted a longer independent cohort. These initial measurements are
retained in full; they are not excluded or relabeled as failed measurements.
See the [research report](../../../../Documentation/TRACK_SELECTION_COMPACT_RANK_PERFORMANCE.md)
for the cross-cohort interpretation.

- `receipts.zip` is the unmodified 316,747-byte Actions artifact (SHA-256
  `7cfc3359f39acc356ee6d54232cc12864f3759a65cb833d4ba45dddcfd8d5b5a`).
- `summary.json` contains medians, ranges, all paired ratios, and absolute changes.
- `provenance.json` records the run, commit, artifact, compiler, SDK, and source hashes.

To recompute all summaries:

```sh
unzip -q Benchmarks/TrackSelectionRanking/evidence/compact-rank-initial/receipts.zip -d /tmp/compact-rank-initial
python3 Benchmarks/TrackSelectionRanking/run.py summarize --output /tmp/compact-rank-initial/benchmark
```
