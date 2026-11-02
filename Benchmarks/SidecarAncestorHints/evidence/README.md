# Retained sidecar research evidence

The proposed implementation is candidate C, source commit
`0712ea3e420b0e07fd0d1dc3f9a808e9a05c2a6c`. The frozen baseline is main
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`.

| Directory | Candidate and purpose | Completed timing observations |
| --- | --- | ---: |
| `linux-initial` | A: larger value plan, rejected full matrix | 520 |
| `linux-initial-followup` | A: unchanged-source diagnostic, rejected controls | 80 |
| `linux-reference-rejected` | B: reference plan, rejected full matrix | 520 |
| `linux` | C: original path plan plus optional metadata snapshot, full matrix | 520 |
| `linux-followup` | C: final unchanged-source diagnostic, 20 pairs | 160 |

These five cohorts total **1,800 observations**. They are not pooled. Original
unfavorable results remain present. New-reader means a fresh reader for each
complete timed scan; primed-reader is a supplementary repeated-scan diagnostic.
All operating-system filesystem caches were warm.

`linux-initial-tests`, `linux-reference-tests`, and `linux-tests` retain separate
A/B/C verification receipts. A and B reported 118 tests in each of four
baseline/candidate × debug/release configurations; C reported 119. A's initial
timing process was interrupted after its tests completed. That incomplete timing
cohort is excluded, while the completed test receipts remain identified.

## Raw records and complete outputs

Small JSON receipts and summaries are readable directly in these directories.
`raw-receipts.zip` retains every command log, test/build log, campaign log, and
raw `measurements.jsonl` at its original relative path. `raw-receipts-index.json`
records each archive member's size and SHA-256. Extract beside this README:

```sh
unzip -n raw-receipts.zip -d .
```

`verification-outputs.json.gz` contains the complete canonical differential corpus:
28 scan trajectories, 12,822 complete recognized outputs, and 92 cancellation /
throw / resume trajectories. All baseline/candidate outputs in every completed
cohort were compared with this shared corpus before duplicate publication copies
were removed. Each cohort's `verification-output-receipts.json` preserves the
original stdout and gzip hashes. The canonical corpus SHA-256 is
`6d7384c78897d50191eba121322c488ae5d4bb2a315404b154593c6eaee3f569`.
The original unabridged build outputs were not modified by this packaging step.

`manifest.json` hashes every published evidence file, excluding itself. Source
snapshots and compiled binaries are not duplicated in this Git archive. Their
hashes, original/compiled source identities, command arrays, compiler identity,
flags, and binary/module hashes are retained. Obtain exact source/test versions
from the source commit in each `candidate.json`; the five frozen baseline files
also live in `../baseline`. The original runner retains complete source snapshots
and binaries in its normal output directory when reproducing an experiment.

Candidate heads in raw `environment.json` / `provenance.json` identify the local
worktree HEAD when a run began. `candidate_uses_worktree_source` is true. The source
manifests identify the measured bytes; `candidate.json` maps those exact bytes to
the later published source commit. Source, harness, runner, and test identities
were independently audited before publication.

## Interpretation

Percentages are medians of adjacent paired ratios, not ratios of the independent
variant medians. Both are retained; they can differ in direction for noisy
controls. CPU and wall time are separate observations, and CPU pinning did not
eliminate host variation. A summary or queued native job does not qualify the
whole player or establish a macOS speedup.

See `../../../Documentation/SIDECAR_ANCESTOR_HINTS_PERFORMANCE.md` for the full
workload matrix, rejected candidates, control tradeoffs, and draft-only conclusion.
