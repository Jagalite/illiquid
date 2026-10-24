# Native performance evidence

## Initial cohort

[GitHub Actions run 39666994530](https://github.com/Jagalite/illiquid/actions/runs/39666994530) compared pinned main `a2de305c8dbcaa81aac1477df7c9a0017c14eae3` with candidate `559eb2431f379608ad2f9668dc209c314ec58607`.

The host was Apple M1 (Virtual), arm64, three logical CPUs, macOS 26.6.2, Apple Swift 6.3.3 from Xcode 26.6. Each cell has six balanced AB/BA pairs. Iteration calibration targeted 100 ms per process; at 10,000 files it selected one timed call after two warmups.

All four baseline/candidate debug/release test runs passed, each reporting 20 tests. All 18 complete output comparisons matched, totaling 66,630 rows per variant. All 216 timed observations are retained; no outliers were removed.

Negative changes mean lower time. Absolute times are the median of per-process means, in milliseconds per complete `rows()` call. Percentage changes are the median of paired percentage changes, not the ratio of the two absolute medians. Ranges in the raw summaries are observed ranges, not confidence intervals.

| Case | Files | Baseline wall ms | Candidate wall ms | Paired wall change | Paired CPU change | Wall-faster pairs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `folders-files` | 100 | 7.849 | 6.587 | -22.54% | -22.38% | 6/6 |
| `folders-media` | 100 | 8.372 | 6.940 | -23.54% | -19.05% | 5/6 |
| `mixed-files` | 100 | 7.779 | 8.390 | +9.75% | +11.92% | 2/6 |
| `mixed-media` | 100 | 7.800 | 9.388 | +24.52% | +23.39% | 2/6 |
| `explicit-files` | 100 | 7.301 | 8.402 | +11.77% | +12.02% | 2/6 |
| `explicit-media` | 100 | 7.360 | 6.973 | -4.48% | -4.67% | 4/6 |
| `folders-files` | 1,000 | 69.171 | 49.232 | -25.33% | -24.32% | 4/6 |
| `folders-media` | 1,000 | 76.011 | 60.401 | -22.16% | -18.21% | 6/6 |
| `mixed-files` | 1,000 | 53.596 | 54.274 | -1.03% | -0.95% | 4/6 |
| `mixed-media` | 1,000 | 68.438 | 68.906 | -0.00% | +0.04% | 3/6 |
| `explicit-files` | 1,000 | 77.026 | 73.968 | +2.25% | +2.26% | 3/6 |
| `explicit-media` | 1,000 | 122.633 | 104.794 | -1.55% | +0.91% | 3/6 |
| `folders-files` | 10,000 | 790.040 | 583.720 | -15.16% | -16.61% | 6/6 |
| `folders-media` | 10,000 | 638.376 | 576.013 | -13.26% | -13.30% | 5/6 |
| `mixed-files` | 10,000 | 662.359 | 652.641 | -0.50% | -0.63% | 3/6 |
| `mixed-media` | 10,000 | 679.981 | 652.064 | -4.21% | -4.04% | 3/6 |
| `explicit-files` | 10,000 | 656.461 | 703.943 | +4.60% | +3.48% | 2/6 |
| `explicit-media` | 10,000 | 699.300 | 790.460 | +12.27% | +12.18% | 1/6 |

All six folder-only cells improved at the paired median, with 32/36 target pairs faster for both wall and CPU time. Several controls were slower, including mixed-media at 100 files (+24.52% wall, +23.39% CPU) and explicit-media at 10,000 (+12.27% wall, +12.18% CPU). These observations motivated the targeted confirmation below; the initial cohort alone does not establish that the unchanged merge path has no performance regression.

## Targeted confirmation

[GitHub Actions run 39669135880](https://github.com/Jagalite/illiquid/actions/runs/39669135880) targeted the four control cells with the largest initial slowdowns. Commit `5eec2e01ba0044216f66bf6a7fda711d615ea731` changes only workflow arguments: the production sources, tests, runner and harness are identical to the initial cohort. The host model, macOS and Swift compiler versions also match.

Each cell uses ten balanced pairs and a 1,000 ms calibration target. The small cases average 157–204 calls per observation; the 10,000-file case averages two. Benchmark mode builds release executables and repeats complete output comparisons, without rerunning the already-passing tests. All four output comparisons matched and all 80 timed observations are retained.

| Case | Files | Calls per observation | Paired wall change | Paired CPU change | Wall-faster pairs |
| --- | ---: | ---: | ---: | ---: | ---: |
| `mixed-files` | 100 | 204 | +0.07% | -0.16% | 4/10 |
| `mixed-media` | 100 | 159 | -0.57% | -1.23% | 5/10 |
| `explicit-files` | 100 | 157 | +1.67% | -1.44% | 4/10 |
| `explicit-media` | 10,000 | 2 | -3.76% | -3.51% | 6/10 |

The large initial slowdowns did not reproduce: confirmation medians span −3.76% to +1.67% wall and −3.51% to −0.16% CPU. This resolves the specific concern about a persistent large paired-median control slowdown; it does not prove exact equivalence or a general speedup in explicit-file paths. Individual observations remain variable, especially the large case: its paired CPU changes span −18.33% to +29.86%, and paired wall changes span −19.75% to +55.00%. The ratio of that cell's overall process means is +6.10% wall and +0.36% CPU, so the favorable median is not a tail-latency guarantee. Neither cohort was filtered, pooled, or substituted for the other. No further runs were selected based on favorable individual samples.

Reproduce the targeted follow-up:

```sh
python3 Benchmarks/FlatFileProjection/run.py \
  --mode benchmark --pairs 10 --target-ms 1000 \
  --sizes 100 --cases mixed-files mixed-media explicit-files \
  --output /tmp/flat-projection-controls-small

python3 Benchmarks/FlatFileProjection/run.py \
  --mode benchmark --pairs 10 --target-ms 1000 \
  --sizes 10000 --cases explicit-media \
  --output /tmp/flat-projection-control-large
```

## Retained receipts

- `observations.json`: every per-call wall/CPU duration, process order, pair, iteration count and consumption checksum.
- `calibration.json` and `summary.json`: all calibration observations, per-process ranges and paired summary calculations.
- `environment.json`, `sources.json`, `binaries.json` and `completion.json`: host/compiler identity, staged production/test hashes, executable hashes and completed on-run integrity checks.
- `tests.json` and `logs/tests-*.log`: four native test-run counts and complete test/build output.
- `parity.json` and `trace-receipts.json`: complete-row equality receipts, row counts and SHA-256 hashes for all 36 original trace files.
- `commands.json`: executed commands, exit codes, stderr and original stdout-log locations.
- `provenance.json`: immutable candidate revision, Actions run/job/artifact identifiers and downloaded ZIP digest.

These selected receipts are committed permanently. The full Actions artifact contains staged packages, driver copies, complete row traces and all individual command stdout logs; its expiry is recorded in `provenance.json`. The large trace bodies and duplicate sources are omitted here and can be regenerated using the pinned revisions and unchanged runner. Command stdout paths refer to that original artifact layout.

Native executables and compiler binaries are not included in the artifact. Their hashes are on-run receipts; the runner checked executable integrity again at completion. All retained source/driver hashes, trace equality, timing arithmetic, command order and checksums were independently audited against the Git revisions and raw artifact.

## Scope

These are isolated complete-row-construction measurements. They exclude fixture preparation, metadata recognition used to prepare fixtures, output consumption and returned-array destruction. They do not measure filesystem scanning, GUI rendering, interactive latency, playback CPU, allocations or RSS. The synthetic collections and hosted virtual machine constrain generalization.
