# Checkpoint source identity: independent qualification

## Result and relationship to PR #124

This is a companion to [PR #124](https://github.com/Jagalite/illiquid/pull/124).
That PR appeared while this independent experiment was running and implements
the same source-identity optimization plus a shortcut for playlists without a
collection folder. This branch adopts its production implementation verbatim
and adds a separate regression suite, benchmark, report, and retained evidence.
There are no production-code differences from PR #124.

Against the original main revision, the adopted implementation reduced median
complete `PlaybackCheckpoint.record()` elapsed time from **11.379025 ms to
7.717861 ms (32.17%)** for a last-item match in a 1,000-item playlist, and from
**116.402303 ms to 85.147384 ms (26.85%)** at 10,000 items. A missing source in
10,000 items improved from **116.993911 ms to 78.377340 ms (33.01%)**.
All seven multi-item middle/end/missing workloads improved in all six paired
comparisons. CPU measurements showed the same direction in these workloads.

These are results from one Linux host, not native macOS or whole-player results.
All timed fixtures have a non-nil folder, so this study does **not** measure
PR #124's additional no-folder shortcut. PR #124 separately publishes its own
native evidence. This companion's added suite still awaits macOS component and
full-app qualification as of this report.

## Why this work matters

The original folder-membership scan normalizes both an item's URL and the
unchanging source URL on every visited item. Preparing the source identity once
removes repeated lexical URL normalization from long scans. The optimization
keeps the existing local-file eligibility checks and normalized identity rules.
It does not introduce a persistent cache or filesystem lookup.

Checkpoint capture occurs on the main actor, while record construction runs on
the persistence writer queue. Checkpoints are requested after at least ten
seconds of playback-position change and on pause, source/playlist changes, and
shutdown. This is a scoped reduction in background persistence work.

The measured operation includes complete record construction, playlist
deduplication, and `Date()` creation. Queue delay, JSON encoding, disk writes,
media decoding, UI latency, frame rate, and whole-player CPU or memory are
outside the experiment. The remaining deduplication pass is still linear.

## Qualified revisions and environment

- Baseline: `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`.
- Measured companion: `9670a9fd32e38c8e3f0a7129fb916601d4d12374`.
- Its production checkpoint source matches PR #124 at
  `9f21c84bbe097984642c8fc08b7c8c1fd31a6c41` and
  `511bee653377575b5d3b2323d0192f86a66990c9` byte for byte.
- Swift 6.3.2 release toolchain, Linux x86_64, AMD EPYC 9V45; four logical CPUs
  available to the GitHub Actions runner.
- [Successful Linux qualification job](https://github.com/Jagalite/illiquid/actions/runs/40636874546/job/122645765124).
- Later companion commits add documentation and evidence and incorporate the
  parent's documentation; the measured source, tests, driver, and runner are
  unchanged.

## Elapsed-time results

Times are milliseconds per complete record operation. Each absolute column is
the median of six observations. The change column is the ratio of those
separate medians, `100 * (candidate / baseline - 1)`; it is not the median of
paired ratios. The final column gives the range of all six paired changes.
The receipts retain both calculations, CPU results, and every observation.

| Items | Source position/type | Baseline ms | Candidate ms | Change of medians | Paired change range |
| ---: | --- | ---: | ---: | ---: | --- |
| 0 | missing | 0.000124 | 0.000067 | −46.42% | −47.21% to −45.61% |
| 1 | first | 0.007280 | 0.007472 | +2.63% | −8.56% to +7.57% |
| 1 | missing | 0.007738 | 0.007799 | +0.79% | −7.57% to +4.09% |
| 32 | first | 0.135045 | 0.134157 | −0.66% | −7.74% to +2.76% |
| 32 | last | 0.360648 | 0.248422 | −31.12% | −33.37% to −25.35% |
| 32 | missing | 0.369675 | 0.251616 | −31.94% | −37.27% to −30.53% |
| 1,000 | first | 4.014848 | 4.025162 | +0.26% | −2.11% to +9.58% |
| 1,000 | middle | 7.849773 | 5.848621 | −25.49% | −26.46% to −24.38% |
| 1,000 | last | 11.379025 | 7.717861 | −32.17% | −33.88% to −31.30% |
| 1,000 | missing | 11.334816 | 7.676492 | −32.28% | −33.73% to −29.22% |
| 10,000 | first | 39.784639 | 39.435882 | −0.88% | −4.93% to +17.78% |
| 10,000 | last | 116.402303 | 85.147384 | −26.85% | −33.88% to −24.31% |
| 10,000 | missing | 116.993911 | 78.377340 | −33.01% | −39.83% to −28.87% |
| 1,000 | remote | 3.952488 | 3.958330 | +0.15% | −10.80% to +8.29% |
| 1,000 | invalid | 8.163077 | 3.947318 | −51.64% | −55.95% to −50.36% |

### Controls and duration limits

Calibration targets a 150 ms batch using the faster one-operation pilot and a
50% margin. This target is reported, not enforced as a timing pass/fail gate.
All **144 observations for playlists with at least 32 items** met the target.
Of the 36 empty/singleton observations, **27 were below it**, ranging from
16.449 ms to 149.018 ms. The completion receipt therefore correctly reports
`minimum_duration_met: false`. Empty and singleton results are retained for
transparency and do not support a speedup claim.

First-match and remote-stream controls had changes of both signs across
pairs. Separate-median regressions included +2.63% for the one-item first match,
+0.79% for the one-item miss, +0.26% for the 1,000-item first match, and +0.15%
for the remote source. This study does not establish improvement or tight
equivalence for those controls. The invalid-source workload uses an unsupported
non-local file authority; its result must not be generalized to normal local
sources.

## Correctness and evidence audit

- **43 tests in seven suites passed in each of four configurations:** baseline
  and candidate, debug and release. This combines six existing core suites with
  the added checkpoint suite (nine test methods, 27 parameterized invocations).
- Coverage includes decoded URL aliases, Unicode normalization, unsupported
  authorities/credentials/ports, relative URLs, source-enum mismatches, empty
  and nil-folder inputs, duplicate metadata and subtitle ordering, saved index
  and shuffle IDs, position sanitization, and timestamp/JSON behavior.
- The driver independently constructs the expected complete record for each of
  15 workloads. Full canonical records match byte for byte across all four
  binaries. Only `updatedAt` is normalized for comparison, outside timing.
- Six balanced AB/BA pairs per workload produced **180 measured observations**.
  Timed checksums consume count, position, folder membership, and pause state;
  full-record equality is checked separately, not inferred from the checksum.
- An independent audit recomputed summaries, paired ratios, ranges, and duration
  flags from raw observations. All recorded commands exited successfully.
- The audit independently verified all 14 full/compiled production source
  copies, copied tests/drivers, and 12 binary hashes against the manifest.
  All four complete record-trace files were retrieved and compared. The runner
  also confirmed source, test, and binary hashes remained unchanged.
- No audit inconsistencies were found. This qualifies the isolated checkpoint
  component on Linux; it does not claim execution of the full macOS app.

## Reproduce

Run builds through Kyoto when available:

```sh
python3 /Volumes/seed1/Projects/kyoto/kyoto.py submit -- \
  python3 Benchmarks/CheckpointSourceIdentity/run.py \
  --output /path/to/new-results --kyoto-queued
```

Inspect Kyoto show, logs, and wait for the job. Without Kyoto, the harness
reports that limitation and performs serialized isolated builds:

```sh
git fetch --no-tags --depth=1 origin ea2ff568237e2667f7b1aeee67b11a44ebe95b72
python3 Benchmarks/CheckpointSourceIdentity/run.py \
  --output /path/to/new-results --pairs 6 --target-ms 150
```

Use `--tests-only` for debug/release regressions and complete-record comparisons
without timing. Pull-request jobs use this mode; branch pushes and manual
dispatch run timing. Separate macOS jobs cover the isolated component and the
native application graph. Do not treat queued jobs as completed validation.

The benchmark uses the checkout's complete checkpoint writer and requires all
six core dependencies to match the pinned baseline. It copies the full
`PlaybackSessionRecord` and `PlaybackSessionStoring` definitions verbatim,
excluding only the unrelated atomic disk store. Core and Player are compiled
as separate production modules from the driver. Release builds use `-O`,
`-whole-module-optimization`, and Swift 6 mode.

Each measured observation runs in a fresh process. Fixture creation and one
warm-up precede timing. Both variants use the same iteration count within a
workload. Complete JSON comparison and fingerprinting occur outside timing.
The harness records compiler commands, logs, source/test/harness/binary hashes,
calibration, raw observations, and completion status.

## Retained evidence

[evidence/linux/receipts.json.gz](evidence/linux/receipts.json.gz) is a
gzip-compressed JSON object mapping artifact-relative filenames to their
original text. It includes observations, summary, calibration, commands,
complete test logs, manifests, completion and audit reports, and one complete
canonical record trace shared by all four verified configurations under
`verification/full-records.json`.

- Receipt bundle SHA-256:
  `0dc6ffff7375f24576f58efed3814a2bdf69463451f15495dcc54446c6d1b80c`.
- Original Actions artifact: `12793373413`, `checkpoint-source-identity-linux`.
- GitHub-reported original ZIP SHA-256:
  `9a3ef81ca3153e50924b1fafe21662ec693797221713c5128f052cd133e5b411`.

Read receipts without extracting arbitrary paths:

```python
import gzip
import json

with gzip.open(
    "Benchmarks/CheckpointSourceIdentity/evidence/linux/receipts.json.gz", "rt"
) as stream:
    receipts = json.load(stream)
print(receipts["audit.json"])
observations = [
    json.loads(line) for line in receipts["observations.jsonl"].splitlines()
]
```

The original Actions artifact additionally contains full build logs, binaries,
and build trees and has 14-day retention. The compact receipts remain in the
repository. Artifact members were retrieved through bounded HTTP range reads;
the individual source and binary hashes were independently verified, but the
full ZIP digest was not independently recomputed.

## Earlier independent prototype

The initial candidate `e6fa79251396c920b085ce2f59402dd9b57c9e63` hoisted source
identity normalization but did not include the no-folder shortcut. Its separate
[successful Linux job](https://github.com/Jagalite/illiquid/actions/runs/40634726321/job/122638940286)
measured last-item medians of 11.828512 to 7.970306 ms at 1,000 items (32.62%
less elapsed time) and 119.860366 to 80.265477 ms at 10,000 items (33.03%).
These prototype numbers must not be attributed to PR #124's exact implementation.

It passed the same four correctness configurations and complete-record parity.
All seven multi-item middle/end/missing workloads improved in every pair.
All 144 observations with at least 32 items met the 150 ms target; all 36
empty/singleton observations were shorter. The overall workflow was later
canceled when the companion branch advanced; its completed Linux job succeeded.

[evidence/linux-prototype/receipts.json.gz](evidence/linux-prototype/receipts.json.gz)
retains the separately audited initial receipts in the same format.
SHA-256:
`4b2311989daa2ef5b910a6660b4f98669008ad634e1cbcbfab15dea1621b247f`.

Both studies preserve the distinction between a successful component experiment,
pending integration checks, and live application qualification.
