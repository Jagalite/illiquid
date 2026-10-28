# Folder discovery classification: measured allocation reduction

## Decision and validation status

The Linux campaign supports this small allocation optimization. Every fixture
containing supported entries used fewer covered allocation requests and fewer
requested bytes in both paired observations, while complete playlist results
remained identical. The empty and unsupported-only allocation controls were
unchanged.

For 1,000 media files plus 2,000 subtitles, the median reduction was **30,016
allocation requests (4.12%) and 2,887,640 requested bytes (2.28%) per discovery**.
The byte reduction is about 2.75 MiB of cumulative allocation traffic. It is not
a measurement of live memory, peak memory, RSS, or the complete player.

**Native qualification remains pending.** As of 2026-10-28 06:14 UTC, the
[original macOS campaign](https://github.com/Jagalite/illiquid/actions/runs/40639472583)
was queued, without executed native tests or measurements. This report does not
claim macOS performance gains or a complete application build. The PR should
remain a draft until native regression qualification is available.

## Completed campaign and provenance

- [Successful Linux run 40641585663](https://github.com/Jagalite/illiquid/actions/runs/40641585663),
  job `122660733751`, completed on 2026-10-28.
- Measured candidate: `1009de80f7d3b2e569747677241319c6c1d58664`.
- Baseline: `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`.
- Host: Ubuntu 24.04 GitHub runner using the official `swift:6.3.2-noble`
  container; Linux x86_64, glibc 2.39, four reported CPUs.
- Compiler: Swift 6.3.2 (`swift-6.3.2-RELEASE`); C probe built with GCC 13.3.0.
- Seven complete production source files compiled in separate optimized modules.
  Only `FolderPlaylistDiscovery.swift` differs between baseline and candidate.
- Two AB/BA pairs for each of eight real filesystem fixtures, with one warmup
  and one measured discovery per fresh process: **64 measured processes**,
  comprising 32 uninstrumented timing observations and 32 allocation observations.
- All observations are retained. No timing threshold or discarded sample was used.

The original macOS run uses candidate `78062e27e6d6c368e4d37f2c1789034ad5e1aacd`.
Its production implementation and measurement harness are byte-identical to the
completed Linux campaign. The later test correction preserves Darwin's injected
forward/reverse listings and adds a Linux filesystem-enumeration fallback.
Documentation and workflow-scope edits after the completed campaign do not
alter the measured production code, tests, driver, or allocation probe.

## Allocation results

Counts and byte totals below are medians of two observations per variant.
Percentage changes are medians of the paired candidate/baseline changes;
negative values mean less allocation traffic. Fractional request counts result
from taking the median of two integer observations.

| Fixture | Allocation requests, baseline → candidate | Request change | Requested bytes, baseline → candidate | Byte change |
| --- | ---: | ---: | ---: | ---: |
| Empty | 129 → 129 | +0.00% | 61,654 → 61,654 | +0.00% |
| 25 media + 50 subtitles | 17,100.5 → 16,339 | -4.45% | 3,167,331 → 3,094,296 | -2.31% |
| 1,000 media | 342,809 → 336,798 | -1.75% | 57,568,094 → 57,015,990 | -0.96% |
| 250 media + 500 subtitles | 180,092 → 172,579 | -4.17% | 31,629,786 → 30,907,804 | -2.28% |
| 1,000 media + 2,000 subtitles | 728,855.5 → 698,839.5 | -4.12% | 126,790,958 → 123,903,318 | -2.28% |
| 1,000 subtitles | 168,173 → 156,162 | -7.14% | 30,436,345 → 29,365,241 | -3.52% |
| 1,000 unsupported files | 53,139 → 53,139 | +0.00% | 17,608,038 → 17,608,038 | +0.00% |
| Symlink rich | 100,899 → 97,769.5 | -3.10% | 20,124,391 → 19,854,495 | -1.34% |

All six fixtures containing supported entries reduced requests and bytes in
both pairs. The largest individual allocation request was unchanged in every
fixture. Removing the combined regular-file array and reusing classification
results reduces allocation traffic without changing playlist construction.

The Linux probe covers successful `malloc`, `calloc`, and `realloc` requests on
the calling thread. Reallocation contributes its entire requested size. These
are covered-request metrics, not total process allocation or retained memory.
Both binaries passed the same real Swift-array control: a 262,144-element byte
array caused exactly one observed request of 262,176 bytes, with the expected
consumed checksum. See [meter-controls.json](evidence/linux/meter-controls.json).

## Timing is exploratory, including the adverse control

Two pairs are insufficient to establish a stable speedup. The table retains
both paired changes instead of presenting only favorable medians. CPU and wall
times come from uninstrumented binaries; metered timings are not speed evidence.

| Fixture | CPU ms, baseline → candidate | CPU change in pairs 1 / 2 | Wall ms, baseline → candidate | Wall change in pairs 1 / 2 |
| --- | ---: | ---: | ---: | ---: |
| Empty | 0.173 → 0.172 | -1.52% / -0.05% | 0.170 → 0.168 | -1.48% / -0.13% |
| 25 media + 50 subtitles | 15.634 → 15.492 | -2.20% / +0.39% | 15.630 → 15.487 | -2.21% / +0.39% |
| 1,000 media | 294.576 → 293.075 | -0.32% / -0.69% | 294.605 → 293.084 | -0.33% / -0.70% |
| 250 media + 500 subtitles | 158.574 → 155.927 | -1.87% / -1.47% | 158.600 → 155.942 | -1.86% / -1.49% |
| 1,000 media + 2,000 subtitles | 643.330 → 633.539 | -1.24% / -1.80% | 643.382 → 633.552 | -1.25% / -1.80% |
| 1,000 subtitles | 152.435 → 149.885 | -0.84% / -2.49% | 152.458 → 149.914 | -0.88% / -2.45% |
| 1,000 unsupported files | 88.712 → 90.410 | +2.22% / +1.61% | 88.705 → 90.411 | +2.24% / +1.61% |
| Symlink rich | 114.075 → 113.751 | +0.40% / -0.96% | 114.073 → 113.773 | +0.40% / -0.91% |

The large mixed fixture's median paired change was -1.52% CPU and -1.53% wall
time. The unsupported-only control was **+1.92% CPU and +1.92% wall time**, and
both of its timing pairs were slower. Small mixed and symlink-rich scans also
have one slower timing pair. This small campaign cannot determine whether the
control slowdown is a repeatable code-generation tradeoff or run variability.
The acceptance claim is the observed allocation reduction with result parity;
it is not a general latency improvement or a claim of no timing regression.

## Correctness and meter qualification

Swift Testing reported **34 tests passed in each of four runs**: baseline Debug,
baseline Release, candidate Debug, and candidate Release. These runs cover the
classification, discovery, filesystem, playlist, and prepared-playlist suites.

The four new tests compare against the frozen original discovery pipeline and
cover mixed target/alias types, duplicate subtitle aliases, metadata equality,
every supported uppercase suffix, all 28 cancellation checkpoints in the mixed
fixture, and unsupported-entry early rejection. Linux executes real filesystem
enumeration. Explicit forward/reversed listing injection is Darwin-only and is
not counted as executed by the Linux campaign.

Every measured output matched its own warmup output and all baseline/candidate
outputs for its fixture. Equality covers complete production Codable items,
dates, subtitle arrays, and URL absolute/relative/base representations. All
eight expected item/subtitle counts and all 64 receipt hashes were verified.
There were no missing observations or failed commands in the successful run.
The test receipts are in [tests.json](evidence/linux/tests.json), and full output
identities are in [verification.json](evidence/linux/verification.json).

The existing macOS folder-discovery regression workflow invokes the updated
standalone test runner, so it will include the new tests on this PR. The research
workflows are restricted to this branch and manual dispatch; their frozen
historical baseline is deliberately not a general future-PR gate.

## Durable evidence and reproduction

- [manifest.json](evidence/linux/manifest.json): compiler/environment information,
  source identities, test and harness hashes, and build boundaries.
- [summary.json](evidence/linux/summary.json): all metric medians, minima/maxima,
  paired changes, and counts of lower candidate observations.
- [observations.jsonl](evidence/linux/observations.jsonl): every raw measurement.
- [records.json.gz](evidence/linux/records.json.gz): the original compressed JSON
  map containing complete text records, command logs, fixture inventory, and
  complete output receipts from CI. It is the original archive, without rewriting.
- The [CI artifact](https://github.com/Jagalite/illiquid/actions/runs/40641585663/artifacts/12795654030)
  additionally includes full source snapshots; the archive committed here and
  the pinned Git revisions preserve reproducibility after CI artifacts expire.

Archive SHA-256:

```text
9b361834398c4fe9d9493066f0d6ed5960a2ccc9bb6399128d442d30bffd3001
```

For example, inspect the retained complete test log without extracting paths:

```sh
python3 - <<'PYTHON'
import gzip, json
from pathlib import Path
path = Path('Benchmarks/FolderDiscoveryClassification/evidence/linux/records.json.gz')
records = json.loads(gzip.decompress(path.read_bytes()))
print(records['logs/0006-test-baseline-debug.log'])
PYTHON
```

See [README.md](README.md) for the full method and reproduction commands. The
native workflow uses six pairs (192 measured processes) and includes Darwin
normal/typed/zone allocator hooks. Its results must be qualified independently.
Neither campaign measures interactive UI latency, cold-cache or network folder
opening, decode/playback performance, or complete-player memory.
