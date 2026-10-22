# Filesystem event planning results

## Decision

The candidate qualifies for a performance PR. On the native macOS runner,
planning the four 256-event workloads backed by existing files or directories
used **33.6–46.1% less median paired elapsed time**. Each workload favored the
candidate in all eight pairs; process CPU time corroborated the improvement.
A 4,096-event structural batch went from a median **67.79 ms to 45.12 ms**
(**32.2% less median paired time**).

The production change is 12 added and 10 removed lines in
`SourceFilesystemInvalidation.swift`. It retains the already-normalized event
URL, avoids reconstructing a URL that infers directory status, and skips
metadata-name checks for structural events. The planner runs synchronously in
`SourcesSidebar`'s main-actor filesystem-refresh task. Reducing this component's
work can reduce main-actor occupancy during notification bursts; end-to-end UI
latency and playback performance were not measured.

## Native qualification

- [Successful workflow run](https://github.com/Jagalite/illiquid/actions/runs/39845334930),
  job `120056994332`, candidate commit `4e78049dc225fa2dea86fc5b3fa6cef24c132655`.
- Baseline: `7f9ba073394b77a908e0589447c6edc8d10b832c`.
- Host: Apple M1 (Virtual), arm64, macOS 26.6.2 (25G83).
- Compiler: Apple Swift 6.3.3 (`swiftlang-6.3.3.1.3`), selected by Xcode 26.6.
- Timing builds: `-O -whole-module-optimization`; unchanged complete production
  files compiled separately for baseline and candidate.
- Eight balanced AB/BA pairs per workload, fresh processes, two warmup calls,
  100 ms calibration target, identical iteration count within each workload.
- All 19 workloads completed: **304 measured process samples**, no exclusions.
- Four existing-path workloads use warm local filesystem fixtures created
  outside timing. Other workloads use synthetic paths.

| Workload | Baseline median ms/plan | Candidate median ms/plan | Paired elapsed change | Paired CPU change | Faster pairs |
|---|---:|---:|---:|---:|---:|
| `one_event` | 0.018500 | 0.011902 | -24.2% | -29.4% | 8/8 |
| `structural_256_1root` | 4.708672 | 2.831766 | -39.8% | -35.3% | 8/8 |
| `structural_4096_1root` | 67.790667 | 45.124000 | -32.2% | -31.1% | 8/8 |
| `structural_256_32roots` | 5.590114 | 3.880818 | -33.4% | -34.0% | 8/8 |
| `content_4096_1root` | 39.813929 | 24.048643 | -33.1% | -39.4% | 8/8 |
| `content_4096_32roots` | 53.185833 | 41.204667 | -25.7% | -25.2% | 8/8 |
| `metadata_256_1root` | 4.098854 | 2.778622 | -30.9% | -31.0% | 8/8 |
| `metadata_256_32roots` | 5.083818 | 3.738606 | -27.0% | -26.9% | 7/8 |
| `directory_mix_256` | 3.472148 | 2.487148 | -26.4% | -26.8% | 8/8 |
| `unmatched_256_32roots` | 2.043194 | 1.969389 | -1.2% | -1.2% | 4/8 |
| `nested_roots_256` | 4.862069 | 3.138828 | -32.1% | -32.1% | 8/8 |
| `full_rescan_256` | 3.973309 | 3.258662 | -19.1% | -19.4% | 8/8 |
| `dropped_4096` | 0.075784 | 0.071579 | +1.7% | +1.7% | 3/8 |
| `no_roots` | 0.000041 | 0.000040 | -0.7% | -0.6% | 4/8 |
| `empty_events` | 0.078393 | 0.075511 | -8.4% | -8.8% | 7/8 |
| `existing_structural_256` | 5.007386 | 3.387957 | -33.6% | -33.6% | 8/8 |
| `existing_content_256` | 3.223804 | 1.732435 | -43.7% | -48.7% | 8/8 |
| `existing_metadata_256` | 4.310074 | 2.928912 | -33.8% | -33.1% | 8/8 |
| `existing_directory_256` | 4.355167 | 2.533758 | -46.1% | -46.2% | 8/8 |

Negative change means less planning time. Absolute times are the separate
medians for each implementation. Percentage changes are the median of the
within-pair candidate/baseline ratios, so they need not equal the ratio of the
two displayed medians.

All 15 workloads that reach the changed event-processing work improved on
median. Fourteen favored the candidate in 8/8 pairs; metadata writes across
32 roots favored it in 7/8 pairs. For the existing-path workloads, median
paired process CPU reductions were 33.1–48.7%.

### Controls and uncertainty

The unmatched-event, dropped-stream, no-root, and empty-event controls bypass
the changed work. Their median paired changes were -1.2%, +1.7%, -0.7%, and
-8.4%, respectively. The dropped-stream case favored the candidate in only
3/8 pairs, and unmatched/no-root controls in 4/8. The empty-event improvement
has no corresponding algorithmic change and is not credited as a benefit.
All samples and ranges are retained in the raw summary. Shared virtual runner
noise is visible; these results establish a component improvement, not a
precise universal speedup or a guarantee for every machine and workload.

## Correctness and source identity

All **37 tests in five suites** passed against both production implementations
in both debug and release: four successful test-suite runs. This includes the
existing monitor, event-loss and root-boundary regression coverage plus new
path-semantics cases for relative and normalized paths, Unicode and literal
percent characters, metadata lookalikes, combined flags, actual files,
directories, metadata-named directories, and directory symlinks.

The differential harness compared complete sorted members of all three plan
sets for **60,947 plans** in each of four compiled configurations. All four
serialized traces also had the same SHA-256:
`ae3ea63e9878cb528cc00a45419bf18135f51bae4c0ced9fdb7a0c1baca797bf`.
It covers all 256 flag masks across root/path combinations, mixed batches in
both orders, existing metadata-named directories, and every timed workload.
Every timed process also returned the same full final plan and checksum as
its counterpart.

| Input | SHA-256 |
|---|---|
| Baseline production source | `8f633dc761b83fbb18c62491231f7e8ee77984655c1f399c492b870739076572` |
| Candidate production source | `5e02e8dba3b1c20843d8668e91257109571f773b99158bc9266890d14c93183f` |
| Harness | `2362fe5c25f3f62f794f495f047cd0dd05bd51b51ed93f203ad52f492967cb4d` |
| Runner | `8e4f479da47dcc7928e4ed099ca00c8589ea2a7f601b9a338afcb9ffaba954e2` |

The current source, harness, runner, and test files were checked against the
native manifest before attaching these results. Evidence/report commits do
not change the measured implementation.

### Initial native test correction

The [first native run](https://github.com/Jagalite/illiquid/actions/runs/39844636106)
failed before timing because a new test additionally required an output path
to preserve the input's exact Unicode UTF-8 representation. The unchanged
baseline failed this assertion on macOS; its semantic expected-plan assertion
passed. Foundation normalized that representation differently from Linux.
The correction removed this unsupported extra assertion and retained the
semantic filename expectation and exact per-platform baseline/candidate trace
comparison. No production code changed. The complete corrected run above
then passed. The initial failure log and source manifest are retained in
[`evidence/macos-initial-test-failure`](evidence/macos-initial-test-failure).

## Mechanism check on Linux

Apple's [URL initializer documentation](https://developer.apple.com/documentation/foundation/url/init(fileurlwithpath:isdirectory:))
explains that supplying the directory hint avoids filesystem I/O used to infer
whether a path is a directory. The old metadata-classification URL constructor
did not supply that hint; the normalized URL already available to the planner
does.

A separate Linux `strace -f -e trace=%file` check of `existing_content_256`
observed **3,328 `newfstatat` calls on the fixture files in the baseline and
zero in the candidate**. This is exactly 256 event paths across 13 planner
calls: two warmups, ten timed iterations, and the final verification call.
This directly corroborates removal of redundant per-event filesystem probes
on that platform. It is not a macOS syscall measurement. Traced execution
times are not used as performance evidence.

Raw traces and commands: [`evidence/linux-syscalls`](evidence/linux-syscalls).

## Linux exploratory run

The earlier Linux run used Swift 6.3.2 on an AMD EPYC 9V74 80-Core Processor.
The same production versions passed all 37 tests in both configurations and
matched all 60,947 plans. This run preceded the test-only Unicode assertion
correction described above. Its two AB/BA pairs per workload and 25 ms
calibration target were exploratory; the native results above are the
acceptance measurement.

| Workload | Baseline median ms/plan | Candidate median ms/plan | Median paired elapsed change |
|---|---:|---:|---:|
| `one_event` | 0.009779 | 0.007979 | -17.9% |
| `structural_256_1root` | 2.043011 | 1.914925 | -6.3% |
| `structural_4096_1root` | 36.388616 | 23.957667 | -34.1% |
| `structural_256_32roots` | 3.126380 | 2.472542 | -20.3% |
| `content_4096_1root` | 19.676375 | 19.499877 | -0.7% |
| `content_4096_32roots` | 31.219318 | 26.017629 | -16.4% |
| `metadata_256_1root` | 2.243204 | 1.915096 | -14.2% |
| `metadata_256_32roots` | 2.802320 | 2.507372 | -10.5% |
| `directory_mix_256` | 2.242134 | 1.742384 | -22.5% |
| `unmatched_256_32roots` | 1.316240 | 1.350734 | +2.7% |
| `nested_roots_256` | 2.221303 | 2.096721 | -5.7% |
| `full_rescan_256` | 2.839481 | 2.353424 | -15.5% |
| `dropped_4096` | 0.058420 | 0.053788 | -7.8% |
| `no_roots` | 0.000025 | 0.000027 | +4.8% |
| `empty_events` | 0.065695 | 0.057082 | -12.6% |
| `existing_structural_256` | 2.869126 | 2.119459 | -26.0% |
| `existing_content_256` | 1.668432 | 1.355654 | -18.9% |
| `existing_metadata_256` | 2.938374 | 2.453473 | -16.4% |
| `existing_directory_256` | 2.839283 | 2.323468 | -18.0% |

Two pairs are insufficient for a stable platform claim. Linux Foundation
results are not combined with native macOS timings.

## Evidence and limits

- Native successful run: [`evidence/macos-qualified`](evidence/macos-qualified).
- Initial native baseline-test failure:
  [`evidence/macos-initial-test-failure`](evidence/macos-initial-test-failure).
- Linux exploratory measurements:
  [`evidence/linux-exploratory`](evidence/linux-exploratory).
- Linux filesystem-probe trace:
  [`evidence/linux-syscalls`](evidence/linux-syscalls).

The successful run retains environment and compiler details, source and binary
hashes, all commands, all four test logs, the complete reference trace,
calibration, all measured samples, summary, completion receipt, workflow
identity, and downloaded-artifact SHA-256. Logs and JSONL files are losslessly
gzip-compressed for the repository. JSON summaries remain directly readable.

See [`README.md`](README.md) for reproduction and measurement design. Tests
use isolated packages containing the unchanged planner and repository tests;
this qualification is not a full player build. Timings include complete
planning and result destruction, but exclude FSEvents delivery, the 150 ms
debounce, directory enumeration, downstream cache work, rendering, decoding,
and playback. Physical-Mac energy, cold filesystems, network volumes, and
whole-player CPU or latency were not measured.
