# Source-preparation admission evidence

This directory contains the evidence for the [performance report](../../SOURCE_PREPARATION_ADMISSION_PERFORMANCE.md). The [benchmark documentation](../../../Benchmarks/SourcePreparationAdmission/README.md) describes the workloads and reproduction commands.

The comparison uses baseline commit `a2de305c8dbcaa81aac1477df7c9a0017c14eae3` and candidate commit `4a08e50d1bf62553a4066756632bf7a51b49bbbf`. Native and Linux benchmark receipts identify the same production, harness, runner, and test source hashes. Measurements cover executor admission and the stated synthetic or warm-directory work; they do not establish whole-player CPU consumption or input latency.

## Native macOS evidence

The primary evidence comes from [GitHub Actions run 39669100025](https://github.com/Jagalite/illiquid/actions/runs/39669100025), triggered by the candidate commit. Both the component and selected app-integration jobs completed successfully. The component runner used arm64 Apple M1 (Virtual), macOS 26.6.2, Apple Swift 6.3.3, and Xcode 26.6.

| File | Contents |
| --- | --- |
| [native/receipt.json](native/receipt.json) | Unmodified runner receipt: commits, toolchain, compiler flags, input and executable hashes, contract-test results, and stress counts. |
| [native/summary.json](native/summary.json) | Unmodified aggregate timing results from eight paired rounds. |
| [native/measurements.jsonl](native/measurements.jsonl) | All 192 original measurement rows: 12 scenarios × eight pairs × two variants. |
| [native/component-logs.tar.gz](native/component-logs.tar.gz) | All 606 recorded commands, build and contract-test logs, four stress-result JSON files, and the retained final stress log for each variant/configuration. |
| [native/app-tests.log.gz](native/app-tests.log.gz) | Complete app build/test log, compressed without changing its contents. |
| [native/provenance.json](native/provenance.json) | Original artifact and job IDs, verified original ZIP hashes and sizes, stored-file and archive-member hashes, compression settings, and source provenance. |

Both baseline and candidate passed all 12 contract tests in debug and release. Each of those four combinations also passed 100 fresh cancellation/handoff stress processes, for **400 processes and 12,800 handoff iterations**. The separate app-integration run passed **21 tests in four selected suites**: source preparation, source-item preparation, source-media scanning, and the source-sidebar folder model.

The benchmark runner overwrites its stress log after each process. The archive therefore contains the final log for each combination; its four stress JSON files retain the result for every process, and `commands.jsonl` records every invocation and exit status. No discarded per-process log is implied by the aggregate count.

The component archive contains 15 files with their original relative paths. `receipt.json`, `summary.json`, and `measurements.jsonl` are retained separately, byte-for-byte. The two production-source snapshots from the original artifact are omitted here because their exact bytes are available at the pinned git commits; both were checked against those git objects and the receipt hashes. Original ZIP artifact IDs and SHA-256 hashes are retained in the provenance file.

## Supporting Linux evidence

Linux results are supplementary measurements from a shared x86_64 host using Swift 6.3.2. They use the final candidate source, six paired rounds, and 144 measurement rows.

| File | Contents |
| --- | --- |
| [linux/receipt.json](linux/receipt.json) | Final benchmark inputs, environment, and binary hashes. |
| [linux/summary.json](linux/summary.json) | Aggregate timing results. |
| [linux/measurements.jsonl](linux/measurements.jsonl) | All original measurement rows. |
| [linux/benchmark-commands.jsonl.gz](linux/benchmark-commands.jsonl.gz) | Compressed benchmark command receipt. |
| [linux/candidate-contract-receipt.json](linux/candidate-contract-receipt.json) | Final-source candidate qualification: 12 passing tests per configuration, 30 fresh stress processes per configuration, and 1,920 handoff iterations. |
| [linux/candidate-tests-debug.log](linux/candidate-tests-debug.log) and [linux/candidate-tests-release.log](linux/candidate-tests-release.log) | Full candidate contract-test logs. |
| [linux/candidate-stress-logs.jsonl.gz](linux/candidate-stress-logs.jsonl.gz) | Compressed retained candidate stress logs. |

The candidate contract run started before the final source commit was created, so its recorded git head differs from the benchmark head. Its production SHA-256 is identical to the final native and Linux benchmark candidate: `681fc16a1e263af5f5cf11bd5838fefa29b4bf77ef58aa3615a9180e5bbd7b16`.

## Environment diagnosis

[environment/linux-sandbox-fault.log](environment/linux-sandbox-fault.log) records the diagnosed Linux sandbox failure: libdispatch queried a worker ID from a nested PID namespace through host procfs, received `ENOENT`, and hit its worker-monitor assertion. The fault also reproduced without Swift Testing and was not candidate-specific. Preliminary sandbox timings were discarded because even a successful lookup could inspect an unrelated host process.

[environment/clean-process-namespace.json](environment/clean-process-namespace.json) records matching process and procfs identifiers for clean qualification. The final candidate contract receipt independently records matching identifiers and the absence of the diagnostic preload. Accepted Linux measurements and qualification ran outside the mismatched sandbox namespace.

## Inspecting the compressed evidence

Run these commands from this directory:

```sh
tar -tzf native/component-logs.tar.gz
tar -xOf native/component-logs.tar.gz commands.jsonl
gzip -cd native/app-tests.log.gz
```

The native gzip streams have an empty original filename and a zero timestamp. The tar archive uses lexicographically sorted relative paths, fixed file modes, and zeroed timestamps and ownership. Decompression was checked against every original artifact member byte-for-byte. `native/provenance.json` records compressed-file hashes and the original member hashes so storage integrity and content identity can be checked separately.
