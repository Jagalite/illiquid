# Independent row-storage evidence audit

Source: `914b87e4a587676b6d9e97aab0d4b8d26f4fd244`. Linux component evidence only. All 432 observations / 216 paired comparisons passed the audit; 108 AB and 108 BA pairs. No native result is asserted.

## Retained allocator deltas at 100,000 rows

| Workload | Projection baseline B | Projection candidate B | Paired reduction | Fixture baseline B | Fixture candidate B | Candidate shares input |
|---|---:|---:|---:|---:|---:|:---:|
| tree | 57,461,184 | 14,473,600 | 74.81% | 152,786,192 | 109,798,624 | 6/6 |
| files | 57,461,184 | 14,473,600 | 74.81% | 152,786,192 | 109,798,624 | 6/6 |
| folders | 42,992,816 | 1,200 | 99.9972% | 137,991,840 | 95,000,256 | 6/6 |
| no_match | 57,462,144 | 14,475,152 | 74.81% | 152,787,152 | 109,800,176 | 6/6 |
| hide_first | 57,461,312 | 46,471,744 | 19.13% | 152,786,288 | 141,796,720 | 0/6 |
| hide_last | 57,461,200 | 46,475,664 | 19.12% | 152,786,176 | 141,800,624 | 0/6 |
| hide_most | 482,928 | 482,928 | 0.00% | 100,039,088 | 100,039,128 | 0/6 |
| annotate_first | 57,461,152 | 46,471,584 | 19.13% | 152,786,128 | 141,796,560 | 0/6 |
| annotate_last | 57,461,152 | 46,475,616 | 19.12% | 152,786,128 | 141,800,592 | 0/6 |
| preannotated | 62,877,952 | 52,871,424 | 15.91% | 162,434,176 | 152,427,648 | 0/6 |
| search | 70,748,912 | 27,761,264 | 60.76% | 166,073,920 | 123,086,272 | 0/6 |
| cache_hit | 0 | 0 | n/a | 152,786,192 | 109,798,608 | 6/6 |

## Timing at 100,000 rows

Positive paired changes mean the candidate took longer. Times and ranges are milliseconds; paired changes are medians of per-pair ratios, not ratios of medians.

| Workload | CPU baseline median [min,max] | CPU candidate median [min,max] | Paired CPU change | Wall baseline median [min,max] | Wall candidate median [min,max] | Paired wall change |
|---|---:|---:|---:|---:|---:|---:|
| tree | 2460.623 [937.589, 2885.974] | 1919.694 [1597.479, 2873.695] | -17.32% | 2640.584 [1005.125, 6498.970] | 2261.387 [1723.372, 3794.163] | -20.32% |
| files | 1267.346 [949.013, 2516.331] | 1522.781 [947.456, 2883.161] | +5.24% | 1274.569 [949.832, 2519.939] | 1551.621 [947.934, 2906.038] | +4.42% |
| folders | 227.149 [124.720, 370.962] | 77.033 [60.627, 194.847] | -54.62% | 227.021 [124.725, 375.872] | 77.056 [60.632, 194.965] | -54.61% |
| no_match | 2684.648 [1578.324, 5295.475] | 2194.250 [1417.435, 4274.596] | -20.00% | 2847.304 [1578.403, 6286.585] | 2197.199 [1417.467, 4493.262] | -25.39% |
| hide_first | 2203.413 [1503.630, 2964.989] | 1695.679 [1225.120, 2552.763] | -19.02% | 2203.606 [1524.588, 2979.414] | 1699.542 [1225.052, 2576.303] | -19.53% |
| hide_last | 1725.767 [1226.034, 2684.027] | 2214.341 [1064.067, 3163.745] | +22.45% | 1727.741 [1225.998, 2689.450] | 2257.215 [1064.645, 3164.560] | +22.49% |
| hide_most | 371.959 [347.932, 1047.534] | 384.560 [341.280, 590.304] | -4.46% | 371.861 [347.942, 1047.492] | 385.476 [341.284, 594.491] | -4.24% |
| annotate_first | 1437.252 [1318.729, 2315.196] | 1687.785 [1479.562, 2408.160] | +6.20% | 1439.021 [1318.344, 2321.341] | 1718.527 [1479.550, 2967.975] | +6.06% |
| annotate_last | 1495.500 [1232.551, 2615.834] | 1742.592 [1238.849, 3051.441] | -11.03% | 1496.883 [1235.141, 2622.293] | 1747.150 [1238.806, 3063.263] | -11.08% |
| preannotated | 2874.844 [2225.432, 4873.212] | 2474.497 [1516.336, 5016.746] | -19.39% | 2894.594 [2248.635, 4882.194] | 2481.472 [1517.624, 5039.239] | -18.82% |
| search | 2740.505 [2464.524, 8429.915] | 3085.829 [2333.406, 3886.393] | +9.78% | 2745.710 [2469.530, 8453.145] | 3057.249 [2341.768, 3898.794] | +8.66% |
| cache_hit | 0.009 [0.007, 0.032] | 0.007 [0.006, 0.008] | -17.09% | 0.013 [0.010, 0.035] | 0.010 [0.009, 0.011] | -17.89% |

## Observed paired timing increases of at least 5%

| Rows | Workload | Metric | Baseline median ms | Candidate median ms | Paired increase | Candidate slower pairs |
|---:|---|---|---:|---:|---:|---:|
| 1,000 | tree | CPU | 10.183 | 12.259 | +46.47% | 4/6 |
| 1,000 | tree | Wall | 20.735 | 28.162 | +48.98% | 4/6 |
| 1,000 | folders | Wall | 1.463 | 5.713 | +396.97% | 4/6 |
| 1,000 | no_match | Wall | 39.227 | 49.565 | +37.34% | 3/6 |
| 1,000 | hide_first | CPU | 19.890 | 24.053 | +5.50% | 3/6 |
| 1,000 | annotate_last | CPU | 23.742 | 26.753 | +18.21% | 4/6 |
| 1,000 | annotate_last | Wall | 61.151 | 64.648 | +62.14% | 4/6 |
| 1,000 | search | CPU | 28.925 | 27.583 | +8.20% | 4/6 |
| 1,000 | search | Wall | 80.276 | 88.860 | +11.03% | 4/6 |
| 10,000 | tree | Wall | 317.847 | 270.242 | +18.55% | 3/6 |
| 10,000 | files | CPU | 242.196 | 189.625 | +27.73% | 3/6 |
| 10,000 | files | Wall | 497.837 | 557.615 | +48.86% | 4/6 |
| 10,000 | no_match | CPU | 197.802 | 132.930 | +18.83% | 4/6 |
| 10,000 | hide_last | Wall | 498.646 | 514.651 | +5.25% | 4/6 |
| 10,000 | annotate_first | CPU | 276.161 | 299.285 | +12.02% | 3/6 |
| 10,000 | annotate_last | CPU | 207.254 | 205.246 | +13.48% | 4/6 |
| 10,000 | annotate_last | Wall | 246.299 | 319.784 | +16.28% | 5/6 |
| 10,000 | preannotated | CPU | 229.577 | 268.617 | +5.29% | 4/6 |
| 10,000 | preannotated | Wall | 256.719 | 316.770 | +10.44% | 4/6 |
| 10,000 | search | Wall | 326.280 | 304.897 | +5.11% | 4/6 |
| 10,000 | cache_hit | CPU | 0.009 | 0.033 | +231.89% | 4/6 |
| 10,000 | cache_hit | Wall | 0.012 | 1.532 | +13092.10% | 4/6 |
| 100,000 | files | CPU | 1267.346 | 1522.781 | +5.24% | 4/6 |
| 100,000 | hide_last | CPU | 1725.767 | 2214.341 | +22.45% | 4/6 |
| 100,000 | hide_last | Wall | 1727.741 | 2257.215 | +22.49% | 5/6 |
| 100,000 | annotate_first | CPU | 1437.252 | 1687.785 | +6.20% | 4/6 |
| 100,000 | annotate_first | Wall | 1439.021 | 1718.527 | +6.06% | 4/6 |
| 100,000 | search | CPU | 2740.505 | 3085.829 | +9.78% | 4/6 |
| 100,000 | search | Wall | 2745.710 | 3057.249 | +8.66% | 4/6 |

## Limits

- Linux x86-64 Swift 6.3.2 component evidence; no native macOS qualification result is asserted.
- Live allocator-accounted bytes while fixture, actor cache and returned projection remain alive; not process RSS, peak memory, whole-player RAM or exact per-object allocation bytes.
- Fixture delta includes input construction; projection delta excludes inputs. Cache-hit projection delta measures an already-primed hit, while fixture delta includes the primed cache.
- rows: API overload only; tree_build_count=0 in every observation. No directory discovery, tree construction, UI rendering, video decoding, or real-library GUI responsiveness was timed.
- Complete byte comparisons cover 17 deterministic cases at 257 rows. Larger measured cases agree on full-output fingerprints and semantic counts; those 432 observations did not retain two complete byte outputs each.
- Six alternating AB/BA fresh-process pairs per case and size. All observations retained without retry or trimming; min/max ranges describe this sample, not confidence intervals.
- Timing from a busy shared host is descriptive; positive paired differences are reported, and no generalized speedup or no-regression guarantee is inferred.
- Only unannotated unchanged rows share storage. Existing nonnil annotations are refreshed to preserve configured Unicode bytes even when Swift String equality considers IDs equivalent.
