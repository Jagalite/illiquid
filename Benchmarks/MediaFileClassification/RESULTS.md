# Recorded Linux results

## Conclusion

The bounded shortcut reduced CPU cost in the measured common lowercase classification sweeps. It does not establish faster folder opening or playback. Native macOS qualification is pending; this change should remain a draft until those results and the full application checks are reviewed.

For lowercase sweeps of 24, 1,000, and 10,000 URLs, median paired CPU reductions were **33.4%, 30.7%, and 29.1%**. The candidate was faster in **12/12, 12/12, and 11/12** pairs, respectively. The 1,000-URL caller-style short-circuit sweep improved by **24.5%**, with all 12 pairs faster.

The ordinary uppercase and Unicode controls had median paired CPU increases of **2.2%** and **1.9%**, each with the candidate faster in 5/12 pairs. The 128-byte lowercase control increased by **4.0%** (5/12 faster); the all-uppercase and uppercase-final-byte controls decreased by **2.5%** and **5.2%** (7/12 and 8/12 faster). These controls do not establish a universal speedup or prove zero fallback overhead.

Real directory measurements were mixed. The 5,050-entry mixed folder increased by **15.2%** (4/12 faster), and its uppercase counterpart increased by **9.3%** (5/12 faster). Other fixtures moved in both directions, and results differed from the earlier cohort. This shared-host experiment does **not** establish an overall discovery improvement or rule out a directory-level regression. Native measurement is required before a merge decision.

## Environment and protocol

- Recorded UTC: `2026-10-28T05:30:00.617503+00:00`.
- Platform: `Linux-6.18.55-x86_64-with-glibc2.39`; `x86_64`; 9 reported logical CPUs on a shared host.
- Compiler: `Swift version 6.3.2 (swift-6.3.2-RELEASE); Target: x86_64-unknown-linux-gnu`.
- Original baseline: `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`.
- Final production source SHA-256: `33657b48e87932f789b6ea92cf949029d916743859e964b8445a4e1bf4c8ff28`.
- 22 classification and 11 real-directory scenarios; 12 balanced fresh-process pairs per scenario; 792 final observations. Calibration observations are separate.
- Classification calibration target: 250 ms process CPU for the faster variant. Discovery target: 100 ms; individual scans can exceed it. Same iterations within each pair.
- Complete public calls are measured. One operation is an entire URL sweep or directory scan. Setup, warmups, and JSON encoding are outside timing.
- All pairs and all unfavorable results are retained. Deterministic hashing is applied identically to timed processes; no other process on this shared host was controlled.

## Correctness

- Both baseline and candidate passed 46 reported Swift Testing tests in 4 suites, in both debug and release: four successful runs.
- Complete classification receipts matched for 16,014 URLs; SHA-256 `ba4f64be00cc3b13da2cba613e6da7a7831caf7b5905eaaaa4fabb91284b4ee4`.
- All 11 real filesystem fixtures produced identical complete playlists, including ordering, URLs, subtitle associations, and metadata dates. Every timing observation also matched its complete post-run playlist; timed scans contributed scalar checksums.
- All source snapshots remained unchanged during the experiment.

After measurement, extra blank lines at the end of the Python runner and fixture
generator were removed. Their Python ASTs are unchanged; the production Swift,
Swift harnesses, and tests match the measured versions byte-for-byte. The
[formatting receipt](evidence/post-measurement-formatting.json) records both
hashes, and the archives retain the exact inputs used for measurement.

## All classification scenarios

Absolute times below are independently calculated medians. Percentage changes are medians of the within-pair candidate/baseline ratios; those are different estimators. Negative changes favor the candidate. CPU and wall values are milliseconds per **entire sweep or scan**, not per file.

| Scenario | Baseline CPU ms | Candidate CPU ms | Paired CPU change | Faster pairs | Paired wall change |
|---|---:|---:|---:|---:|---:|
| lowercase-1-paired | 0.0027 | 0.0018 | -28.74% | 11/12 | -28.74% |
| mixedcase-1-paired | 0.0025 | 0.0023 | -11.00% | 8/12 | -11.00% |
| lowercase-24-paired | 0.0671 | 0.0478 | -33.42% | 12/12 | -33.42% |
| mixedcase-24-paired | 0.0650 | 0.0682 | +2.14% | 6/12 | +2.14% |
| lowercase-1000-paired | 2.7310 | 1.8844 | -30.68% | 12/12 | -30.69% |
| mixedcase-1000-paired | 2.8702 | 2.5078 | -8.11% | 8/12 | -8.13% |
| lowercase-10000-paired | 28.1150 | 19.7720 | -29.09% | 11/12 | -29.05% |
| mixedcase-10000-paired | 26.7495 | 25.6876 | -4.04% | 9/12 | -4.00% |
| uppercase-1000-paired | 2.6613 | 2.6989 | +2.17% | 5/12 | +2.18% |
| unicode-1000-paired | 3.4061 | 3.4577 | +1.91% | 5/12 | +1.91% |
| unicode-mixed-1000-paired | 2.8265 | 2.2294 | -20.56% | 11/12 | -20.57% |
| unicode-path-1000-paired | 3.9759 | 3.0506 | -20.51% | 11/12 | -20.55% |
| unsupported-1000-paired | 2.5977 | 1.8974 | -23.80% | 12/12 | -23.77% |
| no-extension-1000-paired | 2.1711 | 1.2390 | -37.19% | 12/12 | -37.19% |
| subtitle-1000-paired | 2.7142 | 1.8976 | -28.90% | 12/12 | -28.91% |
| remote-1000-paired | 0.1173 | 0.1117 | -4.20% | 7/12 | -4.33% |
| long-lowercase-1000-paired | 10.6276 | 10.9973 | +3.98% | 5/12 | +3.82% |
| long-uppercase-1000-paired | 12.6884 | 13.4136 | -2.53% | 7/12 | -2.53% |
| long-uppercase-tail-1000-paired | 11.8787 | 11.2903 | -5.19% | 8/12 | -5.26% |
| lowercase-1000-shortcircuit | 2.0729 | 1.6387 | -24.51% | 12/12 | -24.51% |
| mixedcase-1000-shortcircuit | 2.2449 | 2.1947 | -5.27% | 9/12 | -5.30% |
| lowercase-1000-mediaonly | 1.4386 | 0.9886 | -28.10% | 12/12 | -28.00% |

## All real-directory scenarios

| Scenario | Baseline CPU ms | Candidate CPU ms | Paired CPU change | Faster pairs | Paired wall change |
|---|---:|---:|---:|---:|---:|
| empty | 0.0752 | 0.0752 | -0.38% | 7/12 | -0.39% |
| small | 0.9389 | 0.9147 | -6.61% | 9/12 | -6.60% |
| media250 | 45.0716 | 47.7205 | +0.86% | 5/12 | +1.01% |
| mixed | 260.6299 | 306.2016 | +15.20% | 4/12 | +15.12% |
| unsupported5000 | 274.8138 | 261.5401 | +0.50% | 6/12 | +0.60% |
| subtitle-heavy | 96.4150 | 98.3072 | +3.98% | 5/12 | +3.98% |
| uppercase-mixed | 258.0268 | 286.5059 | +9.33% | 5/12 | +9.31% |
| unicode-extensions | 72.6606 | 64.6402 | -9.40% | 8/12 | -9.34% |
| unicode-names-ascii-extensions | 103.0791 | 95.6503 | +2.30% | 6/12 | +2.29% |
| symlink-rich | 54.1413 | 47.9357 | -6.60% | 7/12 | -6.60% |
| filename-edge-controls | 1.1911 | 1.2419 | -3.75% | 7/12 | -3.74% |

## Evidence files

- [Final summary](evidence/linux-bounded/summary.json), [raw measurements](evidence/linux-bounded/measurements.jsonl), and [calibration](evidence/linux-bounded/calibration.jsonl).
- [Source/toolchain manifest](evidence/linux-bounded/manifest.json), [test receipts](evidence/linux-bounded/test-receipt.json), and [parity verification](evidence/linux-bounded/verification.json).
- [Complete final evidence archive](evidence/linux-bounded/evidence.tar.gz), containing source snapshots, commands, test logs, and complete output receipts; [archive/file hashes](evidence/linux-bounded/index.json).
- [First, unbounded candidate](evidence/unbounded-linux/summary.json) and [its complete evidence archive](evidence/unbounded-linux/evidence.tar.gz). That earlier experiment motivated bounding the probe; it is not the source proposed by this PR.
- [Method and reproduction instructions](README.md). Native CI artifacts will be separate from these Linux results.
