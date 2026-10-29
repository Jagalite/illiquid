# Linux exploration: correctness and harness execution

This is **exploratory Linux evidence, not native performance qualification**.
The run used Swift 6.3.2 on x86_64 Linux, two AB/BA pairs per workload, and a
25 ms calibration target on a shared host. Other work could contend for CPU and
I/O. The six-workload experiment contains 24 measured samples; every sample is
retained, including regressions and observations shorter than the native
250 ms minimum. The full native acceptance criteria were not met.

## Correctness and provenance

The pinned baseline is `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`. This run measured
a working-tree candidate before its research commit was published. The original
manifest therefore records the baseline as `candidateCommit` and explicitly
records the dirty source status. `sources.json` provides the exact production,
harness, test, and generated-package hashes for both implementations; the commit
field alone must not be interpreted as the candidate source identity.

All **23 tests passed in each of four runs**: baseline debug/release and candidate
debug/release, for 92 test executions of the same 23 cases. Linux excludes the
macOS-only path-alias test. All four executables produced equal full filesystem
oracle traces before and after measurement. Source and executable integrity
checks also passed.

`oracle-trace.json.gz` stores one complete canonical oracle trace. Its receipt
records equality and the canonical hash of all eight before/after outputs, plus
the original source JSON and command-log hashes. This avoids storing multiple
identical megabyte-scale traces. It preserves every workload's full result and
summary maps for the 1/7/256-entry and production-budget checks.

## Exploratory timings

Positive percentages favor the candidate; negative percentages indicate slower
candidate observations. These two-pair medians describe this run and do not
establish repeatable performance effects on Linux or macOS.

| Workload | Paired wall reduction | Paired CPU reduction |
| --- | ---: | ---: |
| `flat_media_4096` | -1.5% | -1.4% |
| `flat_nonmedia_4096` | -5.1% | -5.2% |
| `nested_mixed_4096` | +18.3% | +18.4% |
| `directory_only_512` | -5.7% | -4.9% |
| `cached_repair` | +2.9% | +2.7% |
| `small_32` | +2.3% | +3.5% |

Both primary and control thresholds were false. `nativeQualificationSuccess`
remains false. The native macOS experiment, its full app tests, larger sample
count, and longer durations determine whether the change warrants a PR.

## Retained files

- `manifest.json`, `sources.json`, and `builds.json`: environment, dirty-state
  provenance, source/package hashes, and executable hashes.
- `tests.json` and `tests/*.log.gz`: four complete test logs and positive counts.
- `summary.json`, `completion.json`, and `measurements.jsonl`: every measured
  observation, paired results, duration checks, and the unsuccessful criteria.
- `warmup.jsonl`, `calibration.jsonl`, and `iteration-counts.json`: untimed warmup
  and calibration observations and the shared iteration count for each workload.
- `commands.jsonl`: original command arguments, outcomes, durations, and output
  hashes. Its log paths describe the original execution directory; retained
  test/oracle logs are mapped by the accompanying receipts.
- `oracle-trace.json.gz` and `oracle-receipt.json`: one complete canonical trace
  and the checks establishing eight-way equality.
- `initial-failed-fixture/`: the initial test-fixture failure, complete failed
  test log, original test/harness sources, and exact correction patch in
  `fixture-and-harness-corrections.patch.gz`. The
  production implementation was unchanged between attempts.
- `archive-receipt.json`: SHA-256 and sizes for the retained files.

Gzip files use a zero modification timestamp. Build products, package caches,
and generated fixture trees are omitted; their inputs and executable hashes are
retained. No source, test, harness, runner, or remote branch was changed while
assembling this evidence.
