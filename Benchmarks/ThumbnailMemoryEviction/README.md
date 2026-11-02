# Thumbnail memory eviction

This experiment measures the ordinary in-memory thumbnail insertion path in
`NativeThumbnailCache`. Once the cache reaches its byte budget or 96-image cap,
the original implementation builds a filtered dictionary and sorts every
eligible resident before evicting a prefix. Ordinary insertion commonly needs
only one victim.

The candidate finds the minimum-priority eligible victim in one scan and uses
that result only when removing it satisfies both limits. When the byte deficit
exceeds the average resident size, it goes directly to the original sorted path
to avoid an extra scan before likely bulk eviction. This is only a dispatch
heuristic: it does not change admission or victim order. A mixed-size cache can
still use the original path when one unusually large victim would suffice.
Configuration trims, oversized inputs and equal minimum ranks also retain the
existing sorted path. Background
requests still cannot evict foreground or storyboard-protected images;
foreground requests keep the original protection, background and recency order.

## Reproduce

Requires Python 3 and Swift 6. Follow the repository's `AGENTS.md` build
coordination: submit the command through Kyoto when available. When the queue
is unavailable, the isolated benchmark can be built directly and serially:

```sh
python3 Benchmarks/ThumbnailMemoryEviction/run.py \
  --pairs 16 --bulk-iterations 1000 --output /tmp/illiquid-memory-eviction
# Correctness only, in debug and release:
python3 Benchmarks/ThumbnailMemoryEviction/run.py \
  --tests-only --output /tmp/illiquid-memory-eviction-tests
```

Use a new or empty output directory. Use `--baseline-file PATH` for a source-only snapshot: the runner still checks
the exact baseline Git blob, and records that no checkout revision is available.
Otherwise the pinned baseline commit
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72` must be available to `git show`.
The baseline cache blob is
`66b8127d5c1ea269860b2c1b63e3dcede4262807`.

## What is measured

The runner compiles the complete baseline and candidate cache source bodies,
removing only module imports needed by the standalone build. Identical test-only
receipt/setup methods are appended to each generated source. The actual
`ThumbnailPreferences` and disabled `NonDecodePerformance` instrumentation are
also compiled.

On macOS, images and their storage use real CoreGraphics. The cache is
configured with no disk directory and disk disabled; disk and identity services
are explicit test doubles that fail if an unmeasured operation is attempted.
Linux uses metadata-only image objects and is a portable logic-check option,
not a substitute for native measurements.

The streaming cases call the public actor methods, including their actor
transition costs. Key and image construction, 512 warmup operations, and full
output receipts are excluded from timing. Distinct images are preconstructed
and retained by the harness, so timings measure cache bookkeeping rather than
pixel allocation, decoding, or the destruction of pixel storage.

| Workload | Measured operation |
| --- | --- |
| count-foreground | Foreground insertion at the 96-image cap |
| count-background | Background insertion with foreground and storyboard protection |
| count-mixed | Foreground insertion with 12 persistent storyboard-protected entries; warmup drains other background entries |
| byte-budget | Foreground insertion at the default 16 MiB limit, with 320 × 180 images |
| bulk-insert | A 4 MiB insertion into eight 1 MiB residents under an 8 MiB limit |
| bulk-configure | Reducing a 96 MiB resident cache from a 128 MiB budget to 8 MiB |
| no-victim | Rejected background insertion into a full foreground cache |
| resident-hit | Foreground resident lookup without eviction |

Every bulk sample starts with a newly populated cache. Only the single
insertion/configuration operation is timed; setup and receipts are excluded.
An additional excluded sample warms the bulk path.

Fresh-process baseline/candidate pairs alternate AB/BA order. The initial
portable experiment uses eight pairs; the refined candidate uses sixteen. Both
monotonic elapsed time and process CPU time are recorded. There is no fragile
wall-time threshold on a shared CI host. Source snapshots, compiler settings,
binary hashes, all measurements, command exit statuses, and output receipts
are retained.

## Correctness

Debug and optimized builds each compare complete baseline/candidate traces
after 2,219 checkpoints. The checks cover count/byte pressure, all four priority
tiers, promotions, configuration changes, storyboard source changes, memory
pressure, clearing, oversized input side effects, counter wrap, equal ranks,
and deterministic mixed API sequences. Receipts include resident keys, image
identity, byte accounting, use ranks, protection, source identity, and counters.
A weak-reference check separately verifies release of an evicted image.

The native `ThumbnailMemoryEvictionTests` asserts expected survivors
independently of the baseline, using real `CGImage` instances. The workflow also
runs existing thumbnail cache, non-decoding, and image lifetime regressions in
the complete app dependency graph.

## Recorded results

The final [portable run](https://github.com/Jagalite/illiquid/actions/runs/40640061465)
completed successfully on a GitHub-hosted Linux x86_64 guest with an AMD EPYC
7763 CPU and Swift 6.3.2, using `-O -swift-version 6 -warnings-as-errors`.
These results use metadata-only image doubles. They are **not native macOS
or whole-player measurements**.

The final candidate was commit
`4ae9c4e61a9d24096b8f2488fc8498dae032d306`, cache blob
`e96869867a686d89aec025eb8c174f14f743b7bb`.
There are 256 timing observations: sixteen balanced AB/BA pairs for each of
eight workloads. Streaming observations use 10,000 operations each; bulk
observations use 1,000 independently prepared samples each.

| Workload | Baseline CPU (µs/op) | Candidate CPU (µs/op) | Median paired CPU change |
| --- | ---: | ---: | ---: |
| Foreground insertion, 96-image cap | 139.666 | 5.909 | -95.78% |
| Background insertion, protected residents | 252.081 | 14.099 | -94.48% |
| Foreground insertion, storyboard protection | 520.261 | 17.954 | -96.44% |
| Foreground insertion, 16 MiB byte limit | 83.981 | 4.296 | -94.89% |
| 4 MiB insertion, four victims | 10.632 | 10.787 | +0.27% |
| Budget reduction, many victims | 473.765 | 459.095 | -3.36% |
| Rejected background insertion | 7.994 | 0.611 | -92.31% |
| Foreground resident lookup | 0.374 | 0.378 | +1.10% |

The first two numeric columns are separate medians of per-operation process
CPU cost. The last column is the median of each matched pair's percentage
change, so it need not equal the ratio of the two displayed medians. Monotonic
elapsed-time observations, ranges, and all individual timings are retained too.
Timer overhead is not subtracted from either variant.

### Investigation and decision

The [initial eight-pair run](https://github.com/Jagalite/illiquid/actions/runs/40639544905)
confirmed large single-victim gains but exposed a **+17.73% median paired CPU
regression** for the four-victim insertion. That version always attempted the
scan before the bulk fallback.

The refinement compares the bytes that actually need reclaiming with average
resident size. Count-only pressure keeps the fast path without a division;
likely bulk byte pressure goes straight to the existing sort. In the final
cohort, the same bulk-insertion case is **+0.27%**, while the four ordinary
insertion cases retain **94.48–96.44% reductions** in median paired CPU time.

The unchanged-path controls show small changes (+1.10% for resident hits and
−3.36% for budget reconfiguration); these are reported, not claimed as additional
optimizations. Absolute timings from the initial and final hosts should not be
compared directly: each candidate is compared against its baseline within its
own cohort.

The heuristic is intentionally conservative and is not a proof that every
admitted scan finds a sufficient victim. With skewed image sizes, it can still
scan and then fall back. There is at most one scan before the original sort;
no repeated scanning or persistent eviction index is introduced.

Both final debug and release builds matched all **2,219 checkpoints**. Their
complete verification traces have the same SHA-256:
`d0d949dce392dd35430626eca2fc70c25dae833879c51f1b1c4e84f97238c56e`.
Every timed pair also matched its complete output receipt.

### Evidence and target-platform status

`evidence/initial/` preserves the rejected first strategy's measurements and
`evidence/final/` preserves the refined candidate. Each includes the manifest,
compiler/source/binary hashes, host details, individual timings, summaries,
verification receipts and CI provenance. `receipts.json.gz` preserves the
complete compact CI bundle, including all timed output arrays and command
records; the smaller `timings.jsonl` is its readable projection. Decompressing
the bundle yields a JSON object mapping original output filenames to text.

The first portable attempt
[failed during Git ownership setup](https://github.com/Jagalite/illiquid/actions/runs/40639345682),
before compiling or measuring any variant. The runner now trusts only the
explicit benchmark checkout for its read-only Git commands. That setup failure
is not included in either measurement cohort.

The native macOS component and full app regression jobs remained queued during
this investigation. The PR is a draft pending those target-platform checks.
The added native test suite contains six functions/seven parameterized cases;
it has **not yet executed**. No live playback/UI qualification was performed.

## Qualification limits

These are cache-component measurements, not playback FPS, whole-app latency,
battery, or GPU measurements. No UI or live playback qualification is claimed.
No absolute allocation or resident-memory saving is inferred from the timing
results. The optimization removes temporary filtering/sorting from the common
single-victim path without introducing a persistent eviction index.
