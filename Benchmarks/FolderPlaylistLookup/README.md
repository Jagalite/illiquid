# Folder playlist identity lookup

Measure `FolderPlaylist.index(of:)` against the unmodified production version at
`68274d1b09dcc866296321a5a8858efc297c4f19`. The candidate computes the query's
normalized key once, after encountering the first item with a valid local
identity, and retains normalization of each visited item's URL. Empty and
all-invalid playlists perform no query normalization. For an all-valid scan of
K items, key normalization calls fall from 2K to K+1. Iterating the original
indices preserves the first matching index. No persistent cache is added.

## Reproduce

Requires Python 3.10+ and Swift 6.1+ with Foundation and Testing. From the repo:

```sh
bash Scripts/test-folder-playlist-lookup.sh --jobs 2
python3 Benchmarks/FolderPlaylistLookup/run.py \
  --output Benchmarks/FolderPlaylistLookup/results.json
```

The script builds an isolated Swift package from four unmodified source files
and the checked-in `UtilitiesTests`, `FolderPlaylistTests`, and
`FolderPlaylistLookupTests`. It runs debug and release. To run the same tests on
the original sources, set
`ILLIQUID_LOOKUP_SOURCE_REVISION=68274d1b09dcc866296321a5a8858efc297c4f19`.

The benchmark retrieves three source files with `git show` at the pinned
baseline commit, which must exist locally. `--baseline-revision` and
`--baseline-root` select another baseline; `--candidate-root` and `--swiftc`
select another checkout/compiler. Repeat `--case` to select a subset.
Defaults are 12 balanced AB/BA rounds and `--target-ms 100` per process.

## Workloads

| Cases | Purpose |
| --- | --- |
| `empty`, `singleton-hit`, `singleton-miss` | Small-input controls |
| `last-{2,16,250,1000}`, `miss-{2,16,250,1000}` | Last-item hit and missing local file |
| `first-1000`, `middle-1000` | Early and middle hits |
| `long-path-1000` | Last-item hit under a roughly 400-character parent path |
| `unicode-relative-1000` | Last-item hit via decomposed relative, localhost, and direct URL forms |
| `invalid-query-1000` | Unsupported query rejected after the first valid stored item |
| `invalid-items-{1,16}` | Decoded unsupported item authorities with a valid local query |

Valid-folder last/middle hits and misses are the useful performance cohorts.
Invalid-query rejection is a robustness case, not a representative headline.
The initial eager prototype normalized the query before examining any items.
The all-invalid controls exposed the extra work that this introduced when the
original scan never needed a query key. The implementation was refined to
compute that key only after finding a valid stored item. An invalid query then
returns no match immediately; an all-invalid playlist never computes the key.
All 18 cases are retained. The empty, singleton, and first-hit controls expose
overhead where there is little or no repeated work.

## Method and evidence

Each variant uses byte-for-byte snapshots of `FolderPlaylist.swift`,
`NaturalFilenameOrdering.swift`, and `NormalizedFileURL.swift`. These form a
separate `IlliquidCore` module/object compiled with
`-swift-version 6 -O -whole-module-optimization -parse-as-library`. The driver is
compiled with `-swift-version 6 -O`, imports that module, and links its object.
The public API boundary prevents driver fixture specialization into production
functions. This benchmark contains no natural-filename sorting optimization.

Fixtures, playlist construction/sorting, and decoding are outside the timer.
An independent oracle evaluates the original
`items.firstIndex { NormalizedFileURL.representsSameFile($0.url, query) }`
predicate for every query. Every fresh process performs one excluded warmup.
One excluded baseline calibration chooses a common iteration count, bounded at
10,000, for both variants. Every timed invocation performs 32 lookups; returned
indices are consumed and compared with the oracle after timing. Runtime case
selection and an `@inline(never)` driver function keep the fixture inputs opaque.

Wall time uses `DispatchTime`. The POSIX process CPU `clock()` is sampled just
outside the wall interval; raw CPU ticks and `CLOCKS_PER_SEC` are retained.
[Apple documents that clock and its conversion](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/clock.3.html).
The batch includes query iteration and result-array allocation. CPU time also
includes the two wall-clock reads and CPU sampling overhead. No estimated
overhead is subtracted. Batching amortizes sampling costs, but small controls
remain sensitive to clock granularity and fixed overhead.

All reported `median_ms` and per-operation timings are **per individual lookup**,
divided by both iterations and `operations_per_iteration` (32). Raw rows retain
batch totals, the divisor, and total lookup counts. Use
`cpu_summaries[case].median_paired_speedup` as the primary comparison when host
scheduling causes wall jitter; `summaries` retains separate wall results.
CPU time excludes descheduled waiting, but includes all process threads and
still reflects frequency/cache effects. It is not application latency.

Full decoded receipts compare the exact `[Int?]` result plus query/item URL
representations across every process. The adjacent `*.receipts.json.gz` stores
those complete receipts; checksums alone never establish equivalence. JSON
also records raw timings, pair order, compiler/platform/locale, source revision,
and SHA-256/Git blob hashes of source snapshots and harness files.

These are warm, in-memory lookups. They exclude filesystem access, folder
enumeration, playback, and visible UI latency. The application performs this
lookup on its main actor after folder discovery, but a microbenchmark does not
measure that complete interaction. Linux results require macOS confirmation
before claiming the same improvement on the target platform.
