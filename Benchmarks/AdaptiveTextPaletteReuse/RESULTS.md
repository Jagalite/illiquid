# Adaptive text palette context reuse: results

## Decision and qualification status

**Open a draft PR for the demonstrated reduction in ordinary style-miss CPU cost.** Keep native performance and control-path qualification outstanding. The production change is 12 added / 10 removed lines in `PlayerTheme.swift`: prepare one immutable legibility context and use it for primary color resolution and both subordinate opacities. Numerical color rules, cache keys/history/capacity, and output choices are preserved.

The Linux evidence supports this targeted improvement, with larger sampled regions generally benefiting more. It does **not** establish that every path is faster: the single-sample uncached rainbow case is slightly slower, and cache-control results remain mixed. The latest [macOS qualification run](https://github.com/Jagalite/illiquid/actions/runs/40635954954) is queued at publication, so this is not a native application-build or test-pass claim.

## Final comparison with matched hash seeds

- Swift 6.3.2, optimized whole-module Swift 6, AMD EPYC 9V74 shared Linux host.
- **24 cases × 4 kernels × 6 alternating AB/BA pairs = 1,152 successful timed processes.** All 1,262 recorded build, verification, calibration, and timing commands exited successfully.
- CPU affinity 3; approximately 150 ms baseline-calibrated batches. Thermal state, CPU frequency, and unrelated host load were not controlled.
- Benchmark subprocesses use `SWIFT_DETERMINISTIC_HASHING=1`. This follows [Swift benchmark guidance](https://github.com/swiftlang/swift/blob/main/benchmark/README.md#deterministic-hashing-requirement) and matches table layouts between separately launched variants. Production hashing is unchanged.
- **5,382 exact output records plus one 144-key hash record match byte-for-byte**: 5,383 total JSONL receipts. Every timed pair also matches measured/warmup checksums and cache revision/generation counters.
- The production source is unchanged from the earlier cohorts. Final source/driver provenance is pinned to public commit `63ae72ba07b514218561caba21980d8d131e914d`.

### Sample-revision style misses

All 24 workloads have positive median paired CPU reductions (**2.12–40.38%**); 138 of 144 individual pairs favor the candidate. Representative complete-operation CPU timings:

| Workload | Baseline µs | Candidate µs | Median paired CPU reduction | Faster pairs |
| --- | ---: | ---: | ---: | ---: |
| `one-rainbow` | 7.35 | 7.01 | 2.12% | 4/6 |
| `local9-bright-rainbow` | 35.74 | 26.90 | 22.81% | 6/6 |
| `local9-dark-rainbow` | 15.95 | 11.81 | 23.67% | 6/6 |
| `leading32-saturated-rainbow` | 41.94 | 29.35 | 29.76% | 6/6 |
| `overall96-bright-rainbow` | 385.34 | 355.37 | 12.04% | 5/6 |
| `overall96-midgray-rainbow` | 121.47 | 81.60 | 33.90% | 6/6 |
| `overall96-mixed-mono` | 77.97 | 48.04 | 36.34% | 6/6 |
| `overall96-varied-rainbow` | 107.11 | 63.20 | 39.18% | 6/6 |
| `letterbox224-mono` | 214.16 | 142.18 | 34.41% | 6/6 |

Percentages are medians of the per-pair reductions. They need not equal the ratio of the two independently calculated timing medians. The measured operation includes publication/revision handling, region lookup, primary resolution, opacity calculations, color construction, and identical output consumption. On Linux, color construction/consumption uses the disclosed numeric SwiftUI stand-in.

### Tradeoffs and controls

| Path | Faster workload medians | Range of median paired CPU reductions | Faster individual pairs |
| --- | ---: | ---: | ---: |
| Uncached styles | 23/24 | -2.38% to +42.53% | 136/144 |
| Revision misses | 24/24 | +2.12% to +40.38% | 138/144 |
| Full style-cache hits | 20/24 | -7.60% to +24.42% | 105/144 |
| Preseeded component hits with a style miss | 12/24 | -10.06% to +10.23% | 74/144 |

The controls are not uniformly neutral, including after matching hash seeds. Three specific limitations are:

- **Single-sample uncached rainbow:** 2.38% slower by the paired metric; median paired increase 0.180 µs, with 4/6 pairs slower.
- **Local-midgray monochrome style-cache hit:** 7.60% slower by the paired metric; median paired increase 0.041 µs, with 3/6 pairs slower.
- **Overall-midgray monochrome component hit:** 10.06% slower by the paired metric; median paired increase 4.783 µs, with 5/6 pairs slower.

The component-hit fixture deliberately seeds the component cache before asking for a style, exercising the path that already constructed one context. Its remaining slowdown needs native review. The full style-hit differences are small in absolute time but are still reported. These measurements do not support a universal CPU non-regression claim.

### All final workloads

Positive values mean less candidate CPU time; negative values mean slower. No completed observations or cases were discarded.

| Case | Uncached | Revision | Style hit | Component hit |
| --- | ---: | ---: | ---: | ---: |
| `one-rainbow` | -2.38% | +2.12% | +10.82% | -5.09% |
| `one-mono` | +17.14% | +10.62% | +5.09% | -2.89% |
| `local9-bright-rainbow` | +9.97% | +22.81% | +8.18% | +2.01% |
| `local9-bright-mono` | +28.63% | +28.77% | +12.45% | +3.02% |
| `local9-dark-rainbow` | +26.65% | +23.67% | +6.51% | +7.00% |
| `local9-dark-mono` | +25.79% | +22.40% | +24.42% | -0.26% |
| `local9-midgray-rainbow` | +26.74% | +25.95% | +4.36% | +0.36% |
| `local9-midgray-mono` | +33.94% | +34.97% | -7.60% | +4.73% |
| `leading32-saturated-rainbow` | +32.63% | +29.76% | +21.12% | -3.69% |
| `leading32-saturated-mono` | +39.58% | +28.60% | +5.01% | -0.36% |
| `bottom24-varied-rainbow` | +37.46% | +35.93% | +9.60% | -3.94% |
| `bottom24-varied-mono` | +31.52% | +34.47% | +6.90% | -3.02% |
| `overall96-bright-rainbow` | +13.35% | +12.04% | -0.07% | +5.03% |
| `overall96-bright-mono` | +30.75% | +22.14% | +13.97% | -0.30% |
| `overall96-dark-rainbow` | +33.90% | +23.19% | +4.54% | -1.68% |
| `overall96-dark-mono` | +26.76% | +25.03% | +15.74% | +1.53% |
| `overall96-midgray-rainbow` | +34.36% | +33.90% | +0.40% | -0.76% |
| `overall96-midgray-mono` | +34.44% | +33.90% | +0.75% | -10.06% |
| `overall96-mixed-rainbow` | +42.53% | +40.38% | -2.92% | +0.66% |
| `overall96-mixed-mono` | +39.15% | +36.34% | +4.82% | +10.23% |
| `overall96-varied-rainbow` | +39.84% | +39.18% | -1.70% | +8.76% |
| `overall96-varied-mono` | +40.29% | +39.73% | +4.55% | +4.37% |
| `letterbox224-rainbow` | +29.35% | +31.46% | +8.18% | +7.80% |
| `letterbox224-mono` | +35.78% | +34.41% | +10.42% | -0.01% |

## Earlier cohorts and the measurement correction

The first complete cohort used normal randomized hashing, CPU 0, six pairs, and 100 ms targets. All 24 revision medians improved (7.25–46.50%; 141/144 faster pairs), but full-hit controls ranged from -12.70% to +20.40% and component-hit controls from -15.79% to +15.10%.

A longer confirmation retained every control case: 24 cases × two controls × eight pairs, 250 ms targets on CPU 3, **768 successful timed processes**. It still showed variable controls: full hits -11.39% to +16.66%, component hits -10.83% to +11.48%. Neither cohort establishes uniform control neutrality.

Those results exposed independently randomized dictionary layouts as a confound for fresh-process cache comparisons. The current runner fixes the hash seed and verifies 144 actual key hashes before timing. This controls the chosen layout, not every possible production layout, and it does not eliminate other shared-host noise. The final controlled run, both earlier completed cohorts, and their negative observations are all retained. Across the three complete cohorts there are **3,072 timed observations**.

One first attempt at the matched-hashing cohort terminated after 244 observations when a process exited with SIGILL while the shared filesystem was full; stderr was empty. Its partial files are preserved and excluded from performance conclusions. The temporary toolchain path was subsequently removed during shared-environment cleanup. The complete retry used the verified equivalent Swift 6.3.2 toolchain, the same source/protocol, restored disk capacity, and an approved execution environment. No application change was made to obtain the retry result.

## Correctness and independent verification

The same **six regression tests pass against both versions in debug and release**: four successful configurations, 24 executed test instances. Each configuration performs **2,471 complete style comparisons / 12,355 color-and-halo field comparisons** against the original two-context wrapper. Coverage includes modes, all palettes and regions, sampled geometry, previous-color history, component/full hits, cache overflow, fallback themes, missing samples, generation resets, and switching sources with identical counters.

The oracle shares the unchanged numerical helpers, so this establishes wrapper/output equivalence rather than independently validating the contrast model. Linux output values use the disclosed color stand-in; native SwiftUI and rendered appearance remain distinct qualification steps.

Independent audits recompute every paired change, summary median, faster-pair count, and source/command correspondence. They verify complete counts, requested iteration/warmup values, actual AB/BA order, rotated workloads, checksums, cache counters, and source hashes. The final audit also independently hashed both live executable variants and both shared libraries before cleanup; all matched the recorded hashes.

Two earlier test-setup failures are preserved: an inferred fixture array exceeded Swift type-checker complexity until explicit types were added, and one sandboxed Swift Testing process crashed during restricted `/proc` inspection before assertions. The identical final test matrix passed in the approved execution environment. These are recorded separately from the completed test evidence.

## Source binding and scope

The historical baseline is `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`. The originally tested local commit `2ef550f27a0ecd37ce7cf2fc34815e14ee8abf07` and first published commit `8b89675ce399cb59bbf9a995768d2a32f2e04ffb` share tree `fefdd3b1c7fe61faf7ce8afd3f04df451cdc5b93`. Publication through the GitHub connection changed only commit metadata. The [binding receipt](evidence/source-revision-binding.json) preserves the exact local commit object so its identity can be checked without requiring that unpublished object in a clone.

Commit `63ae72ba07b514218561caba21980d8d131e914d` changes only the benchmark to control hashing and report key hashes. Production bytes are identical across every timing cohort, the passing test matrix, and both published revisions. Common supporting implementations match the frozen baseline; only `PlayerTextPalette` differs between measured implementations.

This change concerns dynamic Liquid Glass text style misses. The current sampler normally uses a 12×8 grid, a minimum 0.25-second interval, and meaningful-change suppression. Styles cache between revisions, with a 256-entry cap. Actual user-visible benefit depends on revisions and visible style keys. **Whole-player CPU, frame rate, power consumption, process memory, and rendered pixels were not measured.**

## Native qualification

At publication, [the latest macOS run](https://github.com/Jagalite/illiquid/actions/runs/40635954954) for `63ae72ba` is queued. The earlier run was superseded by the benchmark correction. The new workflow will run both isolated test versions/configurations using real SwiftUI, the complete benchmark, and the actual app adaptive-text suites through the repository’s native runner. Its XML receipt must show every new regression executed, with no failures. The draft status preserves this outstanding gate and the control-path questions.

## Evidence and reproduction

See the [README](README.md) for source extraction, measurement boundaries, and reproduction commands.

| Evidence | Contents |
| --- | --- |
| [Final controlled cohort](evidence/linux-matched-hashing/summary.json) | [All measurements](evidence/linux-matched-hashing/measurements.json), [pairs](evidence/linux-matched-hashing/pairs.json), [output receipt comparison](evidence/linux-matched-hashing/differential.json), [independent audit](evidence/linux-matched-hashing/independent-audit.json), [binary hashes](evidence/linux-matched-hashing/binary-verification.json) |
| [First randomized cohort](evidence/linux-full/summary.json) | Complete observations and independent audit, including unfavorable controls |
| [Longer randomized controls](evidence/linux-control-confirmation/summary.json) | All 768 observations, independent arithmetic/source/binary audit |
| [Test matrix](evidence/linux-tests/tests.json) | All four passing configurations and full logs |
| [Interrupted matched-hash attempt](evidence/interrupted-matched-hashing/status.json) | Partial evidence and crash log; no completed-performance claim |
| [Exploratory numeric experiment](evidence/exploratory-numeric/summary.json) | Hypothesis selection only; superseded by actual production-call-path measurements |
| [Earlier test setup failures](evidence/setup-failures.json) | Type-checker and sandbox failures retained explicitly |

Each cohort’s `raw-evidence.json.gz` is a gzip-compressed JSON object mapping relative filenames to their exact text. It preserves all generated source snapshots, commands/stdout/stderr, raw process records, full output receipts, calibration, and summaries. Extract its entries to a fresh directory to rerun the accompanying independent audit. SHA-256 inventories accompany the archives. The CI artifact will retain native source/log/output evidence once execution is available.
