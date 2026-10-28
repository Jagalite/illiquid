# Thumbnail memory eviction

This experiment measures the ordinary in-memory thumbnail insertion path in
`NativeThumbnailCache`. Once the cache reaches its byte budget or 96-image cap,
the original implementation builds a filtered dictionary and sorts every
eligible resident before evicting a prefix. Ordinary insertion commonly needs
only one victim.

The candidate finds the minimum-priority eligible victim in one scan and uses
that result only when removing it satisfies both limits. Bulk trims, oversized
inputs and equal minimum ranks retain the existing sorted path. Background
requests still cannot evict foreground or storyboard-protected images;
foreground requests keep the original protection, background and recency order.

## Reproduce

Requires Python 3 and Swift 6. Follow the repository's `AGENTS.md` build
coordination: submit the command through Kyoto when available. When the queue
is unavailable, the isolated benchmark can be built directly and serially:

```sh
python3 Benchmarks/ThumbnailMemoryEviction/run.py \
  --pairs 8 --bulk-iterations 300 --output /tmp/illiquid-memory-eviction
# Correctness only, in debug and release:
python3 Benchmarks/ThumbnailMemoryEviction/run.py \
  --tests-only --output /tmp/illiquid-memory-eviction-tests
```

Use a new or empty output directory. The pinned baseline commit
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

Eight fresh-process baseline/candidate pairs alternate AB/BA order. Both
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

## Qualification limits

These are cache-component measurements, not playback FPS, whole-app latency,
battery, or GPU measurements. No UI or live playback qualification is claimed.
No absolute allocation or resident-memory saving is inferred from the timing
results. The optimization removes temporary filtering/sorting from the common
single-victim path without introducing a persistent eviction index.
