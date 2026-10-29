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
Measured results and limitations follow.


## Qualified native results — run 40646200466

[Workflow run](https://github.com/Jagalite/illiquid/actions/runs/40646200466) (completed successfully
on 2026-10-29 UTC); [component job](https://github.com/Jagalite/illiquid/actions/runs/40646200466/job/122675485140);
[native-regressions job](https://github.com/Jagalite/illiquid/actions/runs/40646200466/job/122675485369).
The archived unrounded source data, including every completed unfavorable timing,
is in [evidence/run-40646200466/](evidence/run-40646200466/); the Actions artifacts additionally
hold 14-day raw compilation, XCTest, and process logs.

- Baseline source commit: `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`
  (original `main`).
- **Qualified candidate source/test/benchmark commit:** `8c559bb53dac08bd2ceadb569d9df63ab55c3151`.
  This is the code measured below, not any subsequent evidence-only commit.
- Runner: macOS 26.6.2 (25G83), arm64 `VirtualMac2,1`, 3 CPUs,
  7 GiB RAM; Xcode 26.6 (17F113); Apple Swift 6.3.3,
  macOS 26.5 SDK. Kyoto was unavailable on the ephemeral runner;
  the workflow disclosed this and compiled serially in an isolated checkout.
- Component qualification: **44 XCTest cases, 0 failures, in each of
  baseline debug, baseline release, candidate debug, candidate release**
  (176 test-case executions; 44 distinct tests).
  Independent native release validation: the complete application graph built,
  **44 XCTest cases and 19 Swift Testing cases passed**.
  The affected suites and five new path cases ran on native Foundation/ImageIO.
- The runner froze and hashed the baseline/candidate production sources,
  verified ten supporting production-source identities and checked fixtures,
  decoded pixel SHA-256, expected hit/miss checksums and byte-accounting.
  The recorded SHA-256 values of the original and modified production cache,
  path tests, and both benchmark drivers also match the corresponding GitHub
  commit files. The four inventories had the exact expected byte totals.
- Six balanced AB/BA process pairs at each of 0, 128, 2,048 and 8,191
  entries: **48 separate measurement processes**, same preseeded 4,096-byte
  padded real JPEG fixtures, 512 warm background reads per process.
  No completed sample or outlier was removed.

### Retained component memory

Values are the median **post-inventory minus pre-inventory** live-byte delta,
with the populated cache actor alive and inventory autoreleases drained.
The percentages are median paired candidate-versus-baseline *relative*
changes from six AB/BA pairs, not ratios inferred from the two displayed medians.
Allocator-accounted heap uses `malloc_zone_statistics(NULL).size_in_use`;
RSS uses `task_info(MACH_TASK_BASIC_INFO).resident_size`.
These are separate measurements of the component process, **not whole-player RAM**.

| JPEG files | Allocator heap Δ, baseline → candidate (MiB) | Paired change | Resident Δ, baseline → candidate (MiB) | Paired change |
| ---: | ---: | ---: | ---: | ---: |
| 0 | 0.064 → 0.064 | 0.00% | 0.641 → 0.672 | +4.88% |
| 128 | 0.195 → 0.103 | -47.17% | 1.922 → 1.813 | -5.69% |
| 2,048 | 2.025 → 0.556 | -72.54% | 6.094 → 4.547 | -25.38% |
| 8,191 | 7.881 → 2.023 | -74.34% | 18.234 → 12.094 | -33.68% |

At 8,191 files, all six pairs saved **6,143,312 allocator-accounted bytes**
(5.859 MiB; **74.34%**) and **6,438,912 resident bytes**
(6.141 MiB; **33.68%**) after inventory. At 2,048 files the paired
savings were 1,540,064 heap bytes (1.469 MiB) and
1,622,016 resident bytes (1.547 MiB). The empty-inventory RSS
delta increased by 32,768 bytes; it is not omitted.

### Inventory and warm background-read timings

The displayed times are **medians across six process pairs for each variant**,
and percentages are medians of paired relative changes. Inventory timing is the
first inventory in each fresh process, using **shared, already-warm filesystem
fixtures**; this is not guaranteed cold-disk latency. Reads are 512 background
`image(for:)` operations per process, including digest hashing, URL creation,
real ImageIO reads and decoding; values are normalized per operation.

| JPEG files | Inventory wall, baseline → candidate (ms) | Inventory CPU (ms) | Warm read wall (µs/op) | Warm read CPU (µs/op) |
| ---: | ---: | ---: | ---: | ---: |
| 0 | 0.554 → 0.568 (-3.24%) | 0.554 → 0.552 (-3.87%) | 5.494 → 5.205 (-5.56%) | 5.424 → 5.098 (-7.50%) |
| 128 | 6.429 → 5.919 (-15.63%) | 5.893 → 5.355 (-12.86%) | 156.666 → 133.082 (-13.02%) | 154.546 → 131.922 (-12.64%) |
| 2,048 | 77.315 → 80.415 (+4.02%) | 74.464 → 79.786 (+5.53%) | 134.541 → 176.564 (+18.19%) | 132.412 → 174.627 (+20.40%) |
| 8,191 | 340.997 → 332.373 (-2.24%) | 335.398 → 327.072 (-4.64%) | 186.646 → 164.709 (-8.04%) | 183.854 → 159.457 (-7.95%) |

**Observed time tradeoff:** At 2,048 files, median paired warm-read wall time
rose **18.19%** (median paired difference **+25.32 µs/read**),
and CPU time rose **20.40%** (median paired difference
**+31.05 µs/read**). Five of six wall-time pairs and all six CPU pairs
were slower, although the wall-time pairs also included an unusually favorable
candidate result (**−151.99 µs/read**); all six are preserved.
The 2,048-file inventory also increased wall time **4.02%** and CPU
time **5.53%** on median paired comparisons. At 8,191 files, warm reads
and inventory were faster on the paired medians, but individual unfavorable
timings remain in `observations.jsonl` (including a
**+78.98 µs/read** warm-read pair). The 128-file read series also
included a **+92.18 µs/read** candidate-worse pair. At zero files,
the RSS delta was slightly worse.

**Assessment:** Large, repeatable retained-memory savings in substantial
inventories justify proposing this small metadata-only optimization for review
despite the **nontrivial 2,048-entry warm-read regression**. Its measured
absolute cost is tens of microseconds per background read, not zero. A
read-dominated real workload could prefer the baseline; production usage
frequency, cold storage, and other hardware were not measured. In particular,
the experiment does **not** establish whole-player RAM, playback FPS,
startup, GPU, battery, or real-world latency improvements.

Evidence files retained verbatim from the completed component job:
`environment.json`, `sources.json`, `binaries.json`, `tests.json`,
`fixtures.json`, `observations.jsonl`, `summary.json` and
`qualification.json`. The raw process orders, paired differences,
checksums and adverse timing samples are retained, without filtering.

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

Both variants still execute all seven XCTest suites (44 tests) in debug and
release. Both AB and BA orders exercise every 0/128/2048/8191 inventory fixture,
512 reads, checksums, and decoded pixel parity. Raw observations are retained,
but no metric summary is emitted and `performance_qualified` is false. Frozen
test inputs and staged source hashes are checked before qualification. The
existing historical evidence is unchanged; this mode cannot renew its claims.

Regression runs additionally require `--whitespace-base <full-commit-SHA>`.
The whitespace gate compares that resolved commit with the actual checked-out
HEAD, retaining both IDs and pass/fail in `whitespace.json`. PR automation uses
`pull_request.base.sha` against the checked-out synthetic merge commit. Push
automation resolves `refs/remotes/origin/<repository.default_branch>` from the
full-depth checkout and uses its merge-base with HEAD, so integrating main does
not attribute preexisting main whitespace to this branch. Workflow logs record
the default-branch ref, resolved commit, and resolved boundary. Missing remote
refs or missing/all-zero PR bases fail closed without a guessed fallback. Local callers must supply the reviewed
integration base explicitly. This checks the introduced delta across all paths,
using the existing repository attributes, instead of attributing unrelated main
whitespace to the historical disk benchmark. Historical default/manual runs keep
the original pinned baseline boundary and reject `--whitespace-base` overrides.
