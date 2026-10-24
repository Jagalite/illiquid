# Retained source-tab membership evidence

These measurements compare the frozen baseline at
`7f9ba073394b77a908e0589447c6edc8d10b832c` with the actual production declarations
identified by each cohort's manifest and source receipts. All timed observations
are retained. See the [research report](../../../Documentation/SOURCE_TAB_MEMBERSHIP_PERFORMANCE.md)
for interpretation and the [runner documentation](../README.md) for reproduction.

| Cohort | Candidate | Purpose |
|---|---|---|
| [linux-smoke](linux-smoke/) | Initial implementation, before its commit; source hashes match `4a0d297` | Two balanced pairs at a 20 ms calibration target; portability/correctness smoke only |
| [macos-initial](macos-initial/) | `4a0d2976387451fd8991aef0869d58bc0d140f11` | Eight balanced pairs at 60 ms; revealed a singleton-folder-miss penalty and motivated the refinement |
| [macos-refined](macos-refined/) | `9091a5b64091b9faea3e97517566bd603e42fcf7` | Same native method after preserving the first-item predicate |

Each native cohort includes:

- `manifest.json`: environment, source/harness hashes, method, and revision.
- `source-receipts.json` and `build-receipts.json`: staged source and executable hashes.
- `tests.json`: baseline/candidate debug/release pass flags and reported test counts.
- `verification.json.gz`: losslessly compressed exact stored-item, query/base-URL,
  and Boolean output receipts; decompress with Python's `gzip` module or `gzip -dc`.
- `calibration.json`: unfiltered calibration records for both implementations.
- `measurements.jsonl`: all 352 timed observations with outputs, checksums, and order.
- `summary.json`: every pair plus independent medians, paired reductions, and faster-pair counts.
- `github-run.json`: immutable workflow run, event, attempt, and measured commit.

Absolute medians and the median of paired reductions are different statistics;
percentages need not equal the ratio of the two reported medians. Empty-call
figures include the measurement loop, output storage, checksum, and timer cost.
No empty-loop subtraction or outlier filtering is applied.

Workflow artifacts also retain staged source packages and full build/test logs.
The source and harness revisions recorded here make the experiment reproducible
beyond the artifact retention period. The Linux smoke records the original dirty
worktree provenance honestly; its source hashes identify the tested implementation.
