# Thumbnail disk inventory memory

This experiment compares the production disk cache at
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72` with the candidate checkout.
The candidate keeps byte count, last-used date, and foreground/background tier
for each physical filename. It constructs file URLs from the shared directory
only when an operation needs a path.

The hypothesis is that retaining one URL per inventory entry also retains
unnecessary Foundation objects and resource-value caches. The cache already
owns the filename separately and does not use those URL resource values after
extracting its eviction metadata. Apple's
[resourceValues(forKeys:) documentation](https://developer.apple.com/documentation/foundation/url/resourcevalues(forkeys:))
describes the URL's resource-value cache and its main-thread run-loop behavior.
The native experiment measures the complete retained inventory after a drained
autorelease pool; it does not infer a byte saving from the API documentation.

## Reproduce

On macOS 26 with Xcode 26.6 selected:

```sh
python3 Benchmarks/ThumbnailInventoryMemory/run.py \
  --pairs 6 --output /tmp/illiquid-thumbnail-inventory-unique
```

Use a new output directory. When the shared Kyoto queue is available, submit
the complete command through it with
`ILLIQUID_THUMBNAIL_INVENTORY_QUEUED=1` and inspect the job's status,
logs, and final result. The runner explains the limitation before using direct
serial builds on an isolated host without Kyoto.

The workflow also builds the complete application dependency graph and runs
the affected native thumbnail suites.

## What is measured

The runner freezes and hashes the baseline and candidate production sources.
All supporting production sources must match the frozen baseline; no source
projections, platform substitutes, or rewritten cache methods are used.

Both variants run the same focused XCTest suites in debug and release:
inventory eligibility, duplicate aliases, failed rename/unlink, budget and
count eviction, queued foreground protection, JPEG lifetime, and reconstructed
directory paths. The complete native graph additionally runs the global cache
tests.

Four inventories contain 0, 128, 2,048, and 8,191 valid JPEG files. A small
patterned JPEG is padded to 4,096 bytes so inventory accounting has an exact
independent expected total. These files exercise metadata ownership; JPEG size
is not intended to model an average user's thumbnail compression ratio.
The 1 GiB configured disk allowance prevents byte-budget eviction, and 8,191
is below the existing entry-count eviction boundary.

Six paired repetitions alternate baseline/candidate and candidate/baseline
process order. Every observation uses a fresh process; both variants read the
same unchanged fixture directory. Filesystem caches are warm. No completed
outlier is excluded.

The retained-memory measurement surrounds the real inventory operation and
drains its enumeration autoreleases before sampling. The actor and inventory
remain alive. Allocator live bytes are
`malloc_zone_statistics(NULL).size_in_use`; process resident memory is
reported separately. These metrics are neither total allocation traffic nor a
whole-player memory, GPU-residency, or battery measurement.

Warm background image reads measure the cost of reconstructing URLs at the I/O
boundary, including the existing key hashing and real ImageIO read path.
Their output checksums must match across each pair. Inventory wall and process
CPU time are also retained, so a memory saving cannot silently hide an observed
time cost.

## Evidence

The output directory records environment, source/binary hashes, actual commands,
test receipts, fixture receipts, all observations, and paired metric summaries.
The workflow uploads those records and emits compact text records in its logs.
Measured results and limitations are recorded here after execution.
