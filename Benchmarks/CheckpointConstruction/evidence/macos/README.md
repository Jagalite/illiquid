# Native macOS checkpoint construction evidence

Qualification run: [40634906801](https://github.com/Jagalite/illiquid/actions/runs/40634906801),
job [122639520635](https://github.com/Jagalite/illiquid/actions/runs/40634906801/job/122639520635).
The job completed successfully on October 28, 2026.

- Host: Apple M1 virtual machine, arm64, macOS 26.6.2.
- Compiler: Apple Swift 6.3.3, selected through Xcode 26.6.
- Baseline: `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`.
- Measured candidate: `bd6ba1e11635fef65ef80d8bef219f82f6e50d59`.
- Both revisions passed 22 tests in three suites in debug and release.
- All 448 observations (224 pairs across 28 workloads) passed full output parity
  and their timed checksums. Each observation checked the complete record and
  exact encoded output before and after timing, excluding only the volatile
  timestamp from equality and separately validating its bounds.
- All observations met the 25 ms minimum CPU/wall duration. The shortest CPU
  observation was 72.370 ms and the shortest wall observation was 72.369 ms.

## Complete results

CPU columns are separate medians in milliseconds per complete record construction
and release. Percentage changes are medians of eight within-pair ratios; negative
values indicate reduced cost. They need not equal the ratio of separate medians.
All observations and outliers are retained. Fixture setup, warmup, JSON encoding,
and full-output validation are outside timing. Darwin autorelease-pool draining
and a constant-time result checksum are inside each measured operation.

| Workload / item count | Baseline CPU ms | Candidate CPU ms | Paired CPU change | Paired wall change |
| --- | ---: | ---: | ---: | ---: |
| `no-folder-last/0` | 0.000458 | 0.000481 | +4.10% | +0.74% |
| `folder-last/0` | 0.000460 | 0.000540 | +14.91% | +12.98% |
| `no-folder-last/1` | 0.010208 | 0.000518 | -94.80% | -94.97% |
| `folder-last/1` | 0.009441 | 0.010033 | +5.61% | +6.09% |
| `no-folder-last/32` | 0.531120 | 0.208293 | -64.08% | -64.97% |
| `folder-last/32` | 0.404540 | 0.307289 | -29.17% | -29.21% |
| `no-folder-last/1000` | 12.494583 | 4.260729 | -65.79% | -65.76% |
| `folder-last/1000` | 13.159231 | 8.663462 | -32.53% | -32.53% |
| `no-folder-last/10000` | 132.808000 | 42.418500 | -66.54% | -66.08% |
| `folder-last/10000` | 113.384500 | 74.860000 | -34.27% | -33.04% |
| `no-folder-first/32` | 0.160602 | 0.170127 | +0.86% | +2.87% |
| `folder-first/32` | 0.134454 | 0.135314 | +0.65% | +0.73% |
| `folder-missing/32` | 0.388420 | 0.288232 | -28.07% | -28.01% |
| `no-folder-first/1000` | 4.391352 | 3.733481 | -3.97% | -4.05% |
| `folder-first/1000` | 3.724056 | 3.766519 | +1.27% | +1.41% |
| `folder-missing/1000` | 12.027036 | 8.337214 | -28.14% | -28.10% |
| `no-folder-first/10000` | 39.541167 | 41.108833 | +1.00% | -2.37% |
| `folder-first/10000` | 40.328250 | 40.544750 | +3.27% | +2.56% |
| `folder-missing/10000` | 117.198250 | 89.658250 | -31.01% | -33.35% |
| `no-folder-missing/1000` | 11.725437 | 4.215063 | -65.89% | -65.98% |
| `folder-middle/1000` | 8.528912 | 6.671235 | -21.19% | -21.26% |
| `folder-unicode/1000` | 17.870375 | 13.855937 | -21.98% | -21.93% |
| `no-folder-unicode/1000` | 19.071654 | 8.416538 | -55.77% | -55.84% |
| `folder-unsupported-source/1000` | 8.448604 | 4.060625 | -51.73% | -51.76% |
| `folder-remote/1000` | 3.869111 | 3.975833 | +2.66% | +2.70% |
| `folder-invalid-items/1000` | 1.522807 | 1.429536 | -8.72% | -8.74% |
| `folder-mixed-items/1000` | 4.561015 | 3.091485 | -29.61% | -29.58% |
| `folder-duplicates/1000` | 5.610158 | 4.721895 | -17.31% | -17.29% |

## Assessment and controls

For the four primary last-item workloads at 1,000 and 10,000 items, every one of
32 CPU pairs improved. Flat playlists used 65.8–66.5% less CPU and folder playlists
used 32.5–34.3% less CPU. Flat missing-item and Unicode workloads also improved;
folder middle/missing/Unicode cases retained benefits with smaller scans or more
remaining per-item work.

First-match scans offer little work to remove. Folder first-match controls had
paired CPU changes of +0.7%, +1.3%, and +3.3% at 32, 1,000, and 10,000 items.
The remote-source control changed by +2.7%. These controls do not establish tight
performance equivalence, and no improvement is claimed for them. The singleton
folder control changed by +5.6%, corresponding to separate CPU medians of
9.44 to 10.03 microseconds. The empty folder control changed by +14.9%, from
0.460 to 0.540 microseconds. Those tiny absolute costs are retained rather than
hidden behind the large-scan improvements. The all-invalid-item control improved
in this cohort despite the candidate performing one extra target normalization;
that result should not be generalized into an invalid-input performance claim.

This is a native Foundation component experiment. It does not measure playback
FPS, live UI behavior, whole-player CPU, queue delay, encoding, or disk writes.
The full app's automatic PR workflows are a separate integration gate. The
production and harness files are unchanged after the measured commit; subsequent
commits add documentation and evidence only.

## Receipt format

`summary.json` and `manifest.json` are exact runner outputs. `review.json.gz` is
the exact compressed JSON mapping emitted in the successful job log. It contains
all UTF-8 evidence: observations, calibration, commands, logs, source snapshots,
and test receipts. It excludes build products and caches.

Archive SHA-256:
`40551985be9fae851b08652a310df3ded6610e54dec687c511199f88409d3710`.

To inspect the archive without extracting files:

```python
import gzip, json
from pathlib import Path
files = json.loads(gzip.decompress(Path("review.json.gz").read_bytes()))
observations = [json.loads(line) for line in files["observations.jsonl"].splitlines()]
manifest = json.loads(files["manifest.json"])
```
