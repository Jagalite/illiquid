# Thumbnail disk-cache eviction

## Question and change

Does selecting only the required eviction prefix reduce the cost of admitting
a thumbnail into a full disk cache?

The cache permits up to 8,192 physical image files. In the frozen baseline,
`NativeThumbnailDiskCache.trimDisk` filters and sorts every eligible entry,
even when admitting a write requires only one removal. The candidate builds
a temporary minimum heap containing filename, last-use date, and background
status, then consumes as many victims as needed. Selection changes from
O(n log n) to O(n + k log n), where n is the eligible inventory and k includes
removed entries and protected entries skipped during selection.

The ordering remains background first, oldest date next, then literal
physical filename. The disk actor retains eligibility, byte/count limits,
foreground reservations around unlink, stopping after unlink failure, and
deferred budget reconciliation. The heap is discarded after each trim, so
promotions and inventory changes require no persistent index maintenance.
Draining most or all of the heap remains O(n log n); budget reduction and
disabling the cache measure that tradeoff.

## Native experiment

[run.py](run.py) stages complete production files from baseline
`33fff16155c3472960f88e04c72dfdfdefd56dcf` and the candidate working tree. It
requires unchanged support sources, builds their shared `IlliquidCore`
definitions, and compiles two separate native executables with Swift 6,
`-O`, and whole-module optimization. Both use the actual cache actors,
CoreGraphics, ImageIO, CryptoKit, and disposable filesystem directories.

[Harness.swift](Harness.swift) supplies a real 16 × 16 `CGImage`. One valid
JPEG is encoded before qualification, padded to **4,096 bytes**, and shared
by both variants through the disk actor's existing encoder injection. The
timed region includes actor calls, key digests, eviction selection,
reservation checks, atomic file writes, and unlink. Fixture creation, initial
inventory, JPEG encoding, survivor verification, and cleanup are outside
timing. Results describe cache overhead for fixed 4 KiB encoded images;
end-to-end thumbnail latency also depends on decoding, image size, encoding,
and storage behavior.

### Fixed workload cohort

All insertion observations perform 32 completed insertion calls. Fixed-size
seed files contain 4,096 bytes. Byte-cap fixtures divide their exact byte
budget across the declared seed count using quotient and remainder, so seed
sizes can be slightly larger. Every fixture mixes foreground and background
entries; two of every three seeds are background.

| Case | Seed files | Budget and warmed state | Timed operation | Required removals |
| --- | ---: | --- | --- | ---: |
| `byte-foreground-1000` | 1,000 | Exactly 4 MiB at a 4 MiB cap | 32 foreground inserts | 32 |
| `byte-foreground-4000` | 4,000 | Exactly 16 MiB at a 16 MiB cap | 32 foreground inserts | 32 |
| `byte-foreground-8191` | 8,191 | Exactly 32 MiB at a 32 MiB cap | 32 foreground inserts | 32 |
| `byte-background-4000` | 4,000 | Exactly 16 MiB at a 16 MiB cap | 32 background inserts | 32 |
| `count-foreground-8192` | 8,191 | One untimed insert reaches 8,192 files / 32 MiB; cap 64 MiB | 32 foreground inserts | 32 |
| `count-background-8192` | 8,191 | One untimed insert reaches 8,192 files / 32 MiB; cap 64 MiB | 32 background inserts | 32 |
| `no-trim-4000` | 4,000 | Fixed-size seeds; cap 64 MiB | 32 foreground inserts | 0 |
| `shrink-8191-to-4096` | 8,191 | Fixed-size seeds; initial cap 64 MiB | Configure 16 MiB | 4,095 |
| `disable-4096` | 4,096 | Fixed-size seeds; initial cap 64 MiB | Configure 0 MiB | 4,096 |

The byte-cap cases require 32 byte-triggered trims and zero count-triggered
trims: each removal admits one insertion, while accumulated spare bytes stay
below one payload throughout the sequence. In particular, the 8,191-file
byte case never reaches the count trigger. Count cases require the converse,
with ample byte headroom. The harness asserts these fixture properties and
the actual number of removed files and successful insertions.

### Method and correctness gates

Each observation starts a fresh process and fixture. Seed modification times
are fixed past values, grouped in eights to exercise equal-date filename
ties. New entries are newer than all seed victims, and actual insertion
timestamps are excluded from receipts. Swift deterministic hashing is
enabled and production performance diagnostics are disabled.

The runner first requires both variants to pass all nine cases:
**18 preflight observations**. The
default measured cohort is **eight pairs per case, 144 observations total**,
alternating baseline-first and candidate-first (AB/BA) and rotating case
order. Only the paired observations enter the summary. Wall and process CPU
time are reported per insertion, or per configure call for the two controls.
For insertions, a sample is the 32-operation total divided by 32; medians
and ranges are across eight batch averages, not individual-latency percentiles.
The report retains each pair's candidate/baseline ratio, median paired
reduction, variant medians/ranges, and number of faster pairs.

An independent complete-sort oracle reproduces the baseline's eligibility
and ordering rules. Every observation compares the complete sorted survivor
array—filename, byte size, and physical tier encoded in the filename—and
checks actor bytes against physical bytes. One full expected receipt per
case is retained; every observation records its matching receipt hashes.
`evictedFilenames` records the **oracle's order**. Filesystem validation proves
the final survivor set and removal count; it does not instrument unlink
order. The reported pressure counters describe the asserted fixture model.

The driver preserves commands, environment, source snapshots and hashes,
executable/shared-library hashes, the JPEG receipt, raw observations, and
the exact schedule. It checks all timed identities against preflight,
reads back the complete observation log, and rechecks staged source,
executable, shared-library, and JPEG hashes before declaring success.
Correctness and complete evidence are mandatory; CI has no elapsed-time
threshold.

## Reproduce

Use macOS 26 and the project's Xcode toolchain, with the frozen baseline
revision available in Git history. The output directory must be new or
empty. The standalone component experiment requires no native playback SDK
or user media.

```sh
python3 Benchmarks/ThumbnailDiskEviction/run.py \
  --pairs 8 --output /tmp/illiquid-thumbnail-disk-eviction

swift test --force-resolved-versions --filter \
  'ThumbnailDiskEviction|NativeThumbnailCacheTests|ThumbnailPhysicalEntryTests|ThumbnailInventoryRegressionTests|ThumbnailPromotionMailboxTests|QueuedThumbnailPromotionTests'
```

Add `--verify-only` to the Python command to run only the native survivor
gates. The `swift test` command builds the app graph and requires the
repository's pinned native SDK. The `Thumbnail disk eviction` workflow
prepares it using the existing verification and installation scripts.

## Validation

The native regression job in [run 39322698431](https://github.com/Jagalite/illiquid/actions/runs/39322698431/job/118300525894)
passed at commit `52767f6e09a9e3a59ad2eb66cfa35a7e3707a7f6` on macOS 26.6.2
arm64 with Xcode 26.6. The debug app-graph build ran **54 distinct tests**:
35 XCTest and 19 Swift Testing tests, with no failures. All eight new
eviction tests passed, covering full heap ordering through cache capacity,
ties and metadata tiers, background eligibility, count admission, budget
shrink, and failed-unlink retry behavior. See the
[qualification receipt](evidence/macos-arm64-20261019/native-qualification.json)
and [native test log](evidence/macos-arm64-20261019/native-tests.log).

Supplementary Linux validation passed the four pure heap tests in both
debug and release with Swift 6.3.2; commands and source hashes are in the
[portable receipt](evidence/macos-arm64-20261019/portable-validation/heap-receipt.json).
The representative FourthPass v4 compatibility harness also passed
[20 cases and 6,167 checks](evidence/macos-arm64-20261019/portable-validation/fourthpass-tests.log).
That compatibility run uses its explicitly synthetic image adapter and
provides integration coverage only, not native image or timing evidence.

## Results and decision

**Keep the temporary heap.** All six byte/count-pressure workloads improved
wall and process CPU time in all eight pairs (48/48 pressure pairs for each
metric). Median paired wall-time reductions were **91.5–95.9%**, saving
**8.34–86.12 ms per insertion** in this fixed-payload cache experiment.
Baseline and candidate sample ranges were disjoint in every pressure case;
both AB and BA execution-order groups showed the improvement.

The [successful native run](https://github.com/Jagalite/illiquid/actions/runs/39322698431)
measured candidate `52767f6e09a9e3a59ad2eb66cfa35a7e3707a7f6` against the frozen
baseline on October 19, 2026. Host: Apple M1 (Virtual), arm64, three logical
CPUs, 7 GiB RAM, macOS 26.6.2, Xcode 26.6, Apple Swift 6.3.3 and the macOS
26.5 SDK. The working tree was clean. See the
[recorded environment](evidence/macos-arm64-20261019/environment.json).

### Wall time

Values are milliseconds per insertion, or per configure call for the last
two rows. Variant medians are across eight observations. The reduction
column is the median of the eight paired percentage reductions, so it is
not computed from the two displayed variant medians.

| Workload | Baseline median | Heap median | Paired reduction | Faster pairs |
| --- | ---: | ---: | ---: | ---: |
| `byte-foreground-1000` | 9.357 | 0.811 | 91.5% | 8/8 |
| `byte-foreground-4000` | 40.798 | 2.521 | 94.2% | 8/8 |
| `byte-foreground-8191` | 89.594 | 3.940 | 95.9% | 8/8 |
| `byte-background-4000` | 29.259 | 2.425 | 92.4% | 8/8 |
| `count-foreground-8192` | 65.602 | 3.528 | 94.5% | 8/8 |
| `count-background-8192` | 61.859 | 3.846 | 94.2% | 8/8 |
| `no-trim-4000` | 0.625 | 0.333 | 23.6% | 5/8 |
| `shrink-8191-to-4096` | 359.236 | 300.053 | 14.7% | 7/8 |
| `disable-4096` | 255.594 | 259.716 | 0.5% | 5/8 |

### Process CPU time

The same per-operation normalization and pairing apply.

| Workload | Baseline median (ms) | Heap median (ms) | Paired reduction | Faster pairs |
| --- | ---: | ---: | ---: | ---: |
| `byte-foreground-1000` | 9.161 | 0.669 | 92.7% | 8/8 |
| `byte-foreground-4000` | 38.757 | 2.012 | 95.0% | 8/8 |
| `byte-foreground-8191` | 88.202 | 3.469 | 96.1% | 8/8 |
| `byte-background-4000` | 28.846 | 1.828 | 93.8% | 8/8 |
| `count-foreground-8192` | 64.487 | 3.352 | 94.8% | 8/8 |
| `count-background-8192` | 60.994 | 3.536 | 94.6% | 8/8 |
| `no-trim-4000` | 0.396 | 0.239 | 22.6% | 5/8 |
| `shrink-8191-to-4096` | 323.166 | 237.266 | 23.3% | 8/8 |
| `disable-4096` | 224.999 | 212.051 | 2.0% | 4/8 |

### Controls and limits

- **No trim:** the heap is never constructed on this path. Only 5/8 pairs
  improved, with wide relative variation at sub-millisecond scale. Do not
  attribute its favorable aggregate median to the eviction change.
- **Budget shrink:** removing 4,095 entries improved in 7/8 wall-time pairs
  and 8/8 CPU-time pairs. The median paired wall saving was 50.66 ms (14.7%).
  The single slower wall pair and all other samples remain in the data.
- **Disable:** wall medians were 255.59 versus 259.72 ms, while the median
  paired reduction was only 0.49%; 5/8 wall pairs and 4/8 CPU pairs improved.
  This is inconclusive for a bulk-drain benefit. It does not establish that
  every disable operation will be faster or unchanged.

These are observations from one virtual Apple Silicon host with controlled
fixtures. The result supports reducing warm disk-cache admission overhead
when capacity forces a small eviction prefix. It does not measure JPEG
encoding, thumbnail generation, decoder throughput, whole-player CPU,
energy, memory consumption, or the frequency of this path during playback.
No timing samples were discarded and no elapsed-time pass threshold was used.

### Permanent evidence

An independent audit checked the complete 18-preflight/144-timed cohort,
native process stdout, every recorded survivor receipt, exact byte totals,
source and executable hashes, Git revisions, and all summary arithmetic.
The [audit report](evidence/macos-arm64-20261019/independent-audit.json) also
retains all paired ratios, ranges, absolute savings, and AB/BA group medians.
The production sources, tests, and timed driver were unchanged between the
qualified commit `52767f6` and this study's original final head `0841d30`.
Changes within that range recorded results, updated workflow triggers, and
added the helper to four existing manual benchmark build lists. The
representative FourthPass check above validated that historical build integration.
Later changes in PR #65 replaced the image reader and added an encoded-size
insertion guard. These retained measurements describe the original qualified
sources; they do not qualify the current combined cache implementation.

- [Raw timed observations](evidence/macos-arm64-20261019/observations.jsonl),
  [summary with every range and ratio](evidence/macos-arm64-20261019/summary.json),
  [preflight records](evidence/macos-arm64-20261019/verification.json),
  and [exact schedule](evidence/macos-arm64-20261019/schedule.json).
- [Full component records](evidence/macos-arm64-20261019/component-records.tar.xz):
  all staged production sources and driver files, full per-case survivor
  receipts, case definitions, commands with stdout/stderr, the fixed JPEG,
  and every original result/manifest. Extract with `tar -xf` to inspect.
  Compiled executables and Swift module outputs are omitted; their recorded
  hashes were checked against the original downloaded artifact before archiving.
- [Component qualification and artifact checksum](evidence/macos-arm64-20261019/component-qualification.json),
  [complete component job log](evidence/macos-arm64-20261019/component-job.log),
  and [checksums of retained evidence](evidence/macos-arm64-20261019/SHA256SUMS).

The original component artifact is `12223040559` from run `39322698431`,
SHA-256 `ba01282f79eb4f6b0da60a14d6195019a654ba18fc6e21ad6beb9a0ed5261f6e`.
The permanent archive preserves its research records beyond Actions artifact
retention.

### Current-source regression integration

Automated push/PR runs use `--current-source-regression`. Default CLI and
`workflow_dispatch` retain the strict historical supporting-source equality guard.
The opt-in mode substitutes only the reviewed current `ThumbnailPolicy.swift`,
`MediaPlaybackSettings.swift`, and `NativeThumbnailCache.swift` support files in
both variants. Every other support file must still match its pinned revision.
`NativeThumbnailDiskCache.swift` remains byte-for-byte from the pinned baseline
for the reference and from the working tree for the candidate. This is an
independent disk-cache reference with current support, not a recreation of the
historical executable. `source-policy.json` records the adaptation and both hashes;
original changed support bytes are retained under `sources/historical/`.

This mode requires `--verify-only` and retains all nine full-survivor oracle
workloads and baseline/candidate output parity. It emits no timing summary or
performance claim. Existing historical evidence and the default measurement
protocol are unchanged. The independent read-allocation workflow remains intact.
