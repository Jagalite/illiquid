# Nearest thumbnail cache lookup research

## Production path

`NativeTimelineThumbnailGenerator.cachedThumbnail` first tries an exact cache
hit, then calls `NativeThumbnailCache.nearest` to display an existing preview
near the requested timeline position. The resident cache holds at most 96
images. Storyboard fallback times also supply potential disk keys after a
restart.

The original lookup filters resident keys, constructs a `Set<Key>`, and sorts
that set into another array. Hashing each complete key includes the media path,
content version, dimensions, and renderer identifier. All admitted candidates
already have equal source, version, and dimensions; only their integer
half-second bucket varies.

The candidate keeps the filtered array, deduplicates fallback times with a
`Set<Int>` of those buckets, and sorts the array in place. It avoids full-key
hashing during candidate deduplication and the conversion from a set of
complete keys back into an array. The normal image-cache lookup still uses its
complete key.

## Behavioral contract

The change retains the original resident key values. Swift string equality
can consider differently encoded Unicode strings equal, while the JSON used
for a disk-cache digest can preserve their different representations.
Rebuilding resident keys from the query could change which disk entry gets
promoted or loaded.

All admitted resident keys have equal path, version, width, height, and renderer
fields. The resident dictionary cannot contain two equal keys for the same
bucket. Deduplicating a fallback by bucket therefore makes the same decision as
inserting its complete key into the original set, including retaining the
resident key when a fallback duplicates it.

Distance calculations continue to convert each bucket to `Double` before
subtraction. The existing inclusive distance bound, rounding of fallback times,
invalid-input handling, earlier-bucket tie-break, cancellation checks, and
ordered asynchronous image attempts are preserved. Large integer buckets keep
the existing floating-point precision and tie behavior.

## Reproduce

Follow [AGENTS.md](../../AGENTS.md) and submit builds through Kyoto when it is
available. On an isolated macOS host without Kyoto, with Swift 6.1 or newer:

```sh
python3 Benchmarks/ThumbnailNearest/run.py \
  --output /tmp/illiquid-thumbnail-nearest --pairs 8 --target-ms 100
```

The output directory must be new or empty. `--tests-only` runs the regression
suites without the optimized differential benchmark. The workflow checks for
Kyoto before direct compilation and keeps its isolated builds sequential.

The historical cache baseline is main commit
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`, Git blob
`66b8127d5c1ea269860b2c1b63e3dcede4262807`. Its blob hash is verified.
Both variants compile against the same frozen current supporting production
sources. All input hashes are checked again before a successful receipt.

Five complete core files and six complete native files are compiled; there are
no replacement cache implementations or FFmpeg dependencies. The same ten
Swift Testing regressions run against both variants in debug and release.
The runner requires ten tests to have executed successfully in every run.

Optimized core and native modules are built separately from the driver with
`-O -whole-module-optimization -disable-cmo` in Swift 6 language mode.
The generated package and compiler target macOS 15 for this standalone cache
component. The actual compiler, Xcode, SDK, architecture, and host versions are
recorded in the manifest.

## Workloads and receipts

Each timed operation calls the actual asynchronous `nearest` method. The clock
includes actor calls, candidate filtering/deduplication/sorting, foreground
cache accounting, and consumption of the returned time and image dimensions.
Fixture construction, cache population, 512 warmup lookups, and result
serialization are outside the measured interval. Fixtures remain alive until
after the stop clock.

| Case | Resident entries | Fallback times | Search radius |
|---|---:|---|---:|
| empty | 0 | None | 7,200 s |
| one-resident | 1 | None | 7,200 s |
| 24-residents | 24 | None | 7,200 s |
| 96-residents | 96 | None | 7,200 s |
| 96-mixed-identities | 96; 24 match the request identity | None | 7,200 s |
| 96-long-path | 96 | None | 7,200 s |
| 24-fallback-duplicates | 24 | 24 times duplicating eight resident buckets | 7,200 s |
| missing-fallbacks | 0 | 24 distinct missing buckets | 7,200 s |
| 96-nearby | 96; only the nearby subset is eligible | None | 3 s |
| 24-storyboard | 24 | 24 interleaved missing buckets | 7,200 s |

Four query positions alternate within each case. The storyboard case tries a
missing earlier fallback before a tied resident image. Real generated
`CGImage` fixtures are 8–11 pixels wide and 8–10 pixels high, below the byte
budget; this isolates lookup from pixel processing while covering the
cache's maximum resident count. The long-path case uses 64 repeated directory
components. Timed cases disable disk access.

The optimized verification run compares all 59 selection receipts, including
returned time bit patterns, image dimensions, decoded pixel checksums, and
resident image identity. Additional assertions cover cancellation, signed
distance ties, actual disk fallback rounding, and Unicode-sensitive disk
promotion. The complete receipts must match before measurements start.

Each case uses 1,000-call calibration and a pilot targeting 20 ms, then chooses
a shared iteration count targeting 100 ms for the faster variant. There are
eight fresh-process pairs per case, alternating baseline/candidate order.
Case order is fixed. Every pair must have identical operation counts, hit
counts, and result checksums. All 160 final observations are retained.

Summaries report variant medians and ranges, every paired reduction, the
median paired reduction, and the number of pairs favoring the candidate.
There is no timing threshold in CI and no removal of inconvenient samples.
The manifest, calibration, commands, complete source snapshots, logs,
verification receipts, and raw timings are available in the workflow artifact.

## Supplementary portable planning probe

The Linux probe compiles the candidate-collection and sorting statements
extracted directly from each complete `nearest` method. It verifies the pinned
baseline blob, identical code outside that method, identical key field
declarations, and an identical asynchronous attempt tail before generating its
two modules.

The generated adapter returns the planned keys before image lookup. It stores
membership in `Dictionary<Key, UInt8>`, so its value layout differs from the
real resident cache. Its measurements cover candidate planning and result
consumption. Actor scheduling, `CGImage` ownership, foreground recency
accounting, asynchronous image attempts, and disk I/O require the native run.
Portable percentages must be reported separately from complete-cache or hover
latency results.

```sh
python3 Benchmarks/ThumbnailNearest/portable.py \
  --output /tmp/illiquid-thumbnail-nearest-portable --pairs 8 --target-ms 100
```

The same Kyoto build-coordination policy applies. The dedicated Linux workflow
uses an official Swift container and records its actual compiler and host
metadata. It runs for the research branch and explicit dispatches.

The portable driver compares 247 full ordered-key receipts, preserving path and
version UTF-8 bytes, signed bucket values, dimensions, and renderer identity.
The Python runner compares the complete results before measuring and retains
per-fixture SHA-256 receipts. Ten timing cases use the same query definitions
as the native harness. Calibration confirms that the faster pilot reaches the
target duration before fixing equal work counts for eight alternating pairs.
All final samples remain in the evidence, including shorter or noisy ones.
Generated module sources, extraction hashes, raw verification outputs,
calibration, commands, and measurements are retained by the workflow.

## Recorded portable results — 2026-10-28

[Run 40641694743](https://github.com/Jagalite/illiquid/actions/runs/40641694743)
successfully measured commit
`378a1160f2777cdd673ec3bcc0fb77385af98821` with Swift 6.3.2 on a
four-vCPU x86_64 Linux runner (AMD EPYC 9V74, glibc 2.35).

The complete ordered-key results matched for all **247 fixtures**. All **80
baseline/candidate pairs** favored the candidate. The figures below measure
the extracted planning stage with the lightweight dictionary adapter described
above. They are separate from complete native-cache lookup or UI latency.

| Workload | Baseline µs/plan | Candidate µs/plan | Median paired reduction | Faster pairs |
|---|---:|---:|---:|---:|
| Empty | 0.200 | 0.174 | 13.35% | 8/8 |
| One resident | 0.470 | 0.338 | 27.33% | 8/8 |
| 24 residents | 4.891 | 2.136 | 55.98% | 8/8 |
| 96 residents | 21.735 | 11.385 | 48.81% | 8/8 |
| 96 mixed identities | 5.151 | 2.443 | 52.77% | 8/8 |
| 96 residents, long path (stress) | 64.554 | 11.410 | 82.09% | 8/8 |
| 24 residents, duplicate fallbacks | 7.216 | 2.433 | 66.25% | 8/8 |
| Missing fallbacks | 5.879 | 2.193 | 62.77% | 8/8 |
| 96 residents, three-second radius | 1.169 | 0.840 | 27.75% | 8/8 |
| 24 residents plus storyboard | 12.148 | 5.620 | 53.75% | 8/8 |

Times are medians of each variant's eight process observations. The percentage
column is the median of the eight within-pair reductions; it can differ from a
percentage calculated from the two displayed time medians. The long-path case
is a stress workload. The 24-resident and storyboard cases provide more useful
lead examples for the ordinary candidate-planning cost.

All 160 final samples were retained. Seven fell below the 100 ms calibration
target after calibration: one 96-resident sample and six long-path samples.
The shortest was 87.944695 ms; none was shorter than 50 ms. These samples remain
in the results. An independent audit recomputed every pair, checked balanced
AB/BA ordering, compared all operation/checksum/candidate-count receipts,
recomputed summaries, and verified executed source hashes. It found no
planning correctness or measurement blocker.

Permanent evidence is in
[evidence/linux-20261028](evidence/linux-20261028/): raw final measurements,
summaries, compiler/source/container provenance, per-fixture verification
hashes, command records, and the audit. The
[workflow artifact](https://github.com/Jagalite/illiquid/actions/runs/40641694743/artifacts/12796062620)
also contains the complete ordered-key JSON, generated Swift sources,
calibration measurements, and process logs; its retention is 14 days.

### Native qualification status

At 2026-10-28 06:12 UTC,
[native run 40639609155](https://github.com/Jagalite/illiquid/actions/runs/40639609155)
was still queued for a macOS runner. Its ten dedicated regression tests,
both-variant debug/release checks, 59 complete-cache selection receipts, and
native timing campaign had **not executed**. The production Swift source, native harness, native runner, regression tests,
and native workflow in that queued commit are identical to their counterparts
in the measured portable commit. Consult the run for its current status.

## Scope

These synthetic component measurements establish the cost of choosing and
retrieving a cached approximation on the recorded host. They do not measure
video decoding, filesystem latency, end-to-end hover latency, frame rate,
energy use, or live UI responsiveness. The macOS 26 player build and live
playback path require their own qualification.

