# Episode folder parsing — initial macOS evidence

This records a completed component experiment and an independent evidence audit.
The timed operation is filename recognition plus a common result consumer.
See the [research report](../../../EPISODE_FOLDER_PARSING_PERFORMANCE.md) for
the complete workload table and interpretation.

## Provenance

| Item | Identity |
|---|---|
| Repository | `Jagalite/illiquid` |
| Actions run | [39069954591](https://github.com/Jagalite/illiquid/actions/runs/39069954591) |
| Native job | `117505317729`, `native-recognition`; completed successfully |
| Measured commit | `f8386f9be6636432c68a9ced7825544306560a60` |
| Baseline commit | `68274d1b09dcc866296321a5a8858efc297c4f19` |
| Original artifact | [12115540648, media-name-recognition-native](https://github.com/Jagalite/illiquid/actions/runs/39069954591/artifacts/12115540648) |
| Original ZIP | 458,586 bytes; 356 files; 12,252,983 uncompressed bytes |
| Platform | Apple M1 (Virtual), macOS 26.6.2, Swift 6.3.3, Swift 6 language mode, `-O` |

Original ZIP SHA-256:

~~~text
08ea93ad10f09b665a2bc02217a2646af18e9177872e5c656e0bd5b5254e2610
~~~

This directory retains the decoded Actions job log, job-step metadata and a
provenance summary. The original archive is available from Actions with
**14-day retention** and is not mirrored here. The machine-readable source
manifest, measurements, receipts and original audit file are not reconstructed
from these notes.

Both variants concern `Sources/IlliquidCore/MediaLibrary/MediaNameRecognition.swift`:

~~~text
baseline  b9e75457eccae3c30e09817ce3520750429935b2af646532ac290b18e4aee8fb
candidate f5fb2c51878046d33c341d6b8cde6426011e10730b30dbd564becc4619967b96
~~~

## Original records and path mapping

The measured benchmark lived at `Benchmarks/MediaNameRecognition`. Its final
location is `Benchmarks/EpisodeFolderParsing`. Source, driver, corpus, runner,
and test bytes were checked against the measured snapshots after relocation.
Directory relocation and README edits do not establish a new measurement.

The original ZIP preserves command paths, Git identity, raw observations,
calibration records, stdout/stderr, complete output receipts, and seven input
snapshots. All 356 archived files were compared byte for byte with the
materialized files used for the audit. Runner temporary paths are historical
provenance, not required installation paths.

## Independent audit notes

The audit verified source/support/test hashes and the baseline against its
pinned Git revision; all 170 command records, zero exit codes and log hashes;
and positive Swift Testing completion summaries. Baseline and candidate each
passed 19 test functions in debug and release. Sidecar/NFO coverage passed
32 tests in each mode, and its Actions step concluded successfully.

All 7,936 complete recognition results matched byte for byte, including every
stored field and `seriesTitle`, `displayName`, and `section`. Strings were
encoded as UTF-8 byte arrays. Matching full-receipt SHA-256:

~~~text
fe9e02dfb3d2f377ac7d38499e16ddea5be50f934038f23364f6b75d5067f3e1
~~~

The audit recalculated 12 workloads × six AB/BA pairs × two variants:
144 observations. It checked actual command and observation order,
calibration-derived recognition counts, checksum recurrence, medians, ranges,
aggregate reductions, and every paired reduction.

The initial checker expected `19 tests passed`; Swift instead reported
`19 tests in 2 suites passed`. Only the checker's parser was corrected before
the successful audit. Original logs and measurements were unchanged. Executable
hashes were recorded during the run, but executable bytes were not uploaded,
so the independent audit could not rehash the binaries.

## Result and limits

| Workload | Baseline → candidate median | Median reduction | Paired observations |
|---|---:|---:|---|
| Bare episode in a season folder | 37.19 → 26.78 µs/name | 27.98% | All six improve; 25.37–45.66% reductions |
| Specials and multi-episode names | 43.17 → 31.50 µs/name | 27.03% | All six improve; 21.80–30.31% reductions |

These families provide the clearest result in this cohort. The mixed corpus
recorded a 17.35% lower median, but one pair was 7.82% slower. The unchanged
movie control ranged from 50.43% slower to 36.58% faster across pairs.
This virtual-host cohort supports a narrow episode-recognition improvement.

## Rechecking

Verify the original archive digest before extraction. Compare preserved input
hashes with the desired checkout and the frozen baseline with its pinned Git
commit. Recalculate results from `measurements.jsonl` and cross-check command
output files; summary medians alone are not verification. Actions job-step
conclusions supply the sidecar process result because those commands run
outside the benchmark runner's `commands.jsonl`.
