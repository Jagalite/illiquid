# Filesystem event planning results

## Qualification status

Local Linux correctness and exploratory measurement are complete. Native macOS qualification is pending; this research branch has not yet been proposed as a PR.

## Linux exploratory run

- Compiler: Swift version 6.3.2 (swift-6.3.2-RELEASE); Target: x86_64-unknown-linux-gnu.
- CPU: AMD EPYC 9V74 80-Core Processor.
- Baseline: `7f9ba073394b77a908e0589447c6edc8d10b832c`.
- Both production sources compiled unchanged in debug and release.
- All 37 tests passed against both versions in both configurations.
- Complete outputs matched for 60,947 plans in each configuration.
- Two alternating AB/BA pairs per workload, 25 ms calibration target; exploratory measurements only.

| Workload | Baseline ms/plan | Candidate ms/plan | Median paired change |
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

Negative change means less elapsed planning time. The unchanged controls varied, and two pairs are insufficient for a stable platform claim. The native run is the acceptance measurement.

Raw receipts: [`evidence/linux-exploratory`](evidence/linux-exploratory). See [`README.md`](README.md) for methodology and the boundary between event planning and whole-player behavior.
