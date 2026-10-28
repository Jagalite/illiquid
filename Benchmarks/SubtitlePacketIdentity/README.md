# ASS packet identity: share owned subtitle payloads

## Result and scope

The main and Picture in Picture subtitle pipelines can retain one owned ASS
packet payload in their deduplication keys. Previously, each pipeline copied
the payload after removing FFmpeg's changing `ReadOrder` field.

In the completed Linux component experiment, two pipelines retaining 1,024
distinct cues used **39.5–50.0% less allocator-reported memory** for 128-byte,
4 KiB, and 64 KiB cue bodies. A single pipeline retained approximately the same
memory. Both configurations avoided two intercepted allocation requests per
packet per pipeline for bodies eligible for sharing, including rejected
duplicates. Small bodies and unusual input representations retain the compact
copy path.

These measurements cover deduplication-key storage and its construction. Libass
event storage, decoding, rendering, GPU memory, total player RSS, and visible
playback are outside the experiment. Timing is retained as exploratory evidence;
the A/A control was too noisy to support a general CPU-speed claim.

## Production change

The baseline is main commit
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`. Its private `ProcessedPacketKey`
stored the expression `Data(data[data.index(after: comma)...])`. The outer
initializer rebases the slice by copying its contents. The new
[`ProcessedSubtitlePacketKey`](../../Sources/IlliquidNativePlayback/Subtitles/ProcessedSubtitlePacketKey.swift)
retains the `Data` slice directly when all of these conditions hold:

- The input starts at index zero.
- Removing the first field discards at most 32 bytes, including its comma.
- At least 64 payload bytes remain.

The 32/64 limits are conservative policy choices, not assertions about
Foundation's internal small-data capacity. Tiny bodies, long prefixes, and
nonzero-origin inputs use the original compact-copy expression. Inputs without
a comma retain their complete bytes, as before.

The extracted key retains the same timestamp fields and synthesized byte-based
equality/hashing. Millisecond validation and rounding, Set admission, pruning,
reset, and the pipeline lock remain in `SubtitlePipeline`. The complete original
packet continues to reach libass.

### Why sharing is safe on the current path

[`SubtitleDecoder.decode`](../../Sources/IlliquidNativePlayback/Media/SubtitleDecoder.swift)
constructs each text event with fresh, owned `Data(String(cString: ass).utf8)`.
Its native FFmpeg result is released before returning the events.
[`MediaSession.processSubtitlePacket`](../../Sources/IlliquidNativePlayback/Media/MediaSession.swift)
then feeds the same event to main and optional PiP pipelines. Shared Swift
storage therefore outlives the native decoder scratch result independently.
Normal Swift mutation retains copy-on-write isolation.

The pinned libass 0.17.5 implementation declares `ass_process_chunk` input
`const`, copies it to a private allocation before parsing, and frees that
temporary on return. It cannot modify the key's backing bytes. Its own parsing
and event allocations are unchanged. Sources are the repository's
[`libass archive`](../../DependencySources/archives/libass-0.17.5.tar.xz),
`libass/ass.h` and `libass/ass.c`.

The Linux copy mechanism is also visible in the pinned
[Swift 6.3.2 Foundation Data implementation](https://github.com/swiftlang/swift-foundation/blob/swift-6.3.2-RELEASE/Sources/FoundationEssentials/Data/Data.swift):
the sequence initializer constructs a new representation from contiguous bytes,
whereas the range subscript can retain existing storage. The ownership tests
and measurements establish the behavior on the tested runtime; the source link
alone is not a macOS performance result.

### Producer invariant and negative control

**Zero-based indexing does not prove compact backing storage.** Public `Data`
APIs do not expose spare capacity or a hidden trailing portion of a slice. The
sharing path relies on the audited decoder creating a fresh, complete packet.
If a future producer supplies overreserved buffers or zero-origin prefix slices,
revisit this policy or compact those inputs before sharing.

The explicit `overallocated` control calls `reserveCapacity(packet.count * 4)`
before key creation. Foundation may reserve more than requested. With 1,024
4 KiB bodies, its single-pipeline median rises from **4,345,744 to 21,155,440
bytes (+386.8%)**; two pipelines rise from **8,706,672 to 21,221,312 bytes
(+143.7%)**. This is deliberately nonproduction input and demonstrates why
fewer allocation requests alone are not sufficient evidence of lower retained
memory. The control is kept in the default suite and raw results.

## Completed Linux evidence

Swift 6.3.2, x86-64 Linux/glibc. Each group has six fresh-process pairs, alternating
baseline/candidate and candidate/baseline. Every invocation ingests 1,024
packets; timing invocations repeat ingestion 50 times. The duplicate workload
reuses 64 semantic identities with changing ReadOrder values.

The full cohort contains **648 observations / 324 pairs** across nine fixtures,
one and two pipelines, and three measurement modes. All paired key counts and
payload checksums match. The independent A/A cohort contains another **144
observations / 72 pairs** using identical baseline source in both slots for the
tiny and dense fixtures.

### Retained allocation

Values are medians of allocator-reported in-use deltas in bytes, after transient
input owners have gone out of scope and while keys remain retained. Percentage
changes use the ratio of medians. Set storage and shared original packet buffers
are included.

| Body size | Pipelines | Baseline bytes | Candidate bytes | Change |
|---|---:|---:|---:|---:|
| 32 B, compact-copy control | 2 | 384,872 | 384,872 | 0.0% |
| 128 B | 1 | 285,600 | 285,384 | -0.08% |
| 128 B | 2 | 580,904 | 351,248 | **-39.53%** |
| 4 KiB | 1 | 4,345,584 | 4,345,488 | approximately 0% |
| 4 KiB | 2 | 8,704,000 | 4,411,296 | **-49.32%** |
| 64 KiB | 1 | 67,198,640 | 67,198,560 | approximately 0% |
| 64 KiB | 2 | 134,471,680 | 67,264,416 | **-49.98%** |

The larger inputs are synthetic retained-key stress cases. The fixture named
`drawing` contains a 64 KiB synthetic text body; no ASS drawing parser or renderer
is executed. These are not measurements of the frequency or size of cues in
user media. A single shared key can retain a few extra ReadOrder bytes even when
allocator size classes make its observed footprint nearly unchanged.

On Linux the meter uses `mallinfo2().uordblks + mallinfo2().hblkhd`; allocator
caches can contribute to this accounting. On macOS it uses
`malloc_zone_statistics(NULL).size_in_use`. Neither is an exact object-byte
ledger, RSS, nor GPU accounting. Post-release deltas are retained separately in
the raw data; custom-deallocator tests verify actual last-owner release.

### Allocation requests

The separate Linux/glibc interposer counts successful `malloc`, `calloc`, and
`realloc` requests **during key construction and Set insertion**. Input packet
creation happens before the meter is enabled. Aligned and other allocation APIs
are outside this counter. These are traffic totals, not live bytes or peaks.

For each of the 128 B, 4 KiB, and 64 KiB ordinary fixtures:

| Pipelines | Baseline requests | Candidate requests | Requests removed |
|---|---:|---:|---:|
| 1 | 2,059 | 11 | 2,048 |
| 2 | 4,118 | 22 | 4,096 |

For two pipelines with 4 KiB bodies, requested bytes fall from **8,786,064 to
264,336 (-96.99%)**. Remaining requests include Set growth. The 32 B, long-prefix,
offset-input, and no-comma controls have exactly unchanged allocation traffic
in all pairs. The A/A allocation counts and requested bytes are also identical
in every pair.

### Timing interpretation

Uninstrumented timings include input String/Data construction, key creation,
Set insertion, count consumption, and intermediate history destruction. The
final history remains retained until after timing; byte checksums and JSON
serialization run afterward. No allocation interposer is loaded for timing or
retained-memory observations.

The shared Linux host is noisy: identical-source A/A CPU ratios of medians
range from about -2.0% to +18.2%, with much wider individual paired ranges.
Candidate timing medians are often lower for sizeable payloads, but this report
makes **no general CPU, latency, frame-rate, or energy improvement claim**.
Full ranges and per-pair results are available below.

## Correctness and qualification

The actual production helper and unmodified
[`ProcessedSubtitlePacketKeyTests`](../../Tests/IlliquidNativePlaybackTests/ProcessedSubtitlePacketKeyTests.swift)
passed all **eight XCTest cases in debug and release**, compiled in Swift 6
mode with warnings treated as errors. Coverage includes 1,100 input fixtures and
1,100 changed-ReadOrder duplicate attempts compared with the exact old expression;
timestamp identity; arbitrary bytes and sliced inputs; boundary controls;
copy-on-write isolation; shared ownership across two Sets; rejected duplicate
release; pruning/reset; and compaction fallbacks.

Two early measurement attempts stopped because the local filesystem filled.
Their measurements are not used in the completed tables. The second attempt's
passing test logs were preserved, and helper/test hashes were verified against
the final measurement sources. The complete cohort uses `--skip-tests` with
those separate matching receipts; this flag alone does not establish correctness.
Subsequent measurements ran in an isolated temporary directory. Kyoto was
unavailable, so all builds were direct, serial, and separate from the app's
`.build` directory.

The native `PlaybackPerformanceRegressionTests` addition checks changed ReadOrder,
different text/times/durations, retained future cues, and replay after pruning
through `SubtitlePipeline`. The existing
[`pip-subtitle-upload-performance` workflow](../../.github/workflows/pip-subtitle-upload-performance.yml)
now includes both new test suites in its real macOS application-graph build and
subtitle-consumer checks. The new
[`subtitle-packet-identity` workflow](../../.github/workflows/subtitle-packet-identity.yml)
runs the component's ownership tests and measurements on macOS.

At this initial research commit, macOS CI and live playback qualification remain
pending. PR check results provide the subsequent native status. Linux results
are not substitutes for native Foundation or visible playback qualification.

## Reproduce and audit

Use a complete Swift 6.3.2-compatible toolchain, Python 3, a C compiler, and a new
output directory. Linux allocation metering requires glibc 2.33 or later. The
runner needs the baseline commit in local git history (`fetch-depth: 0` in CI).
When Kyoto is available, submit the complete command through the shared queue
as required by `AGENTS.md`.

```sh
python3 Benchmarks/SubtitlePacketIdentity/run.py \
  --output /tmp/illiquid-subtitle-key-run \
  --pairs 6 --count 1024 --iterations 50

python3 Benchmarks/SubtitlePacketIdentity/run.py \
  --output /tmp/illiquid-subtitle-key-aa --aa-control \
  --pairs 6 --count 1024 --iterations 50 --cases tiny,dense

# Exact helper/test source only, without workloads:
python3 Benchmarks/SubtitlePacketIdentity/run.py \
  --output /tmp/illiquid-subtitle-key-tests --tests-only
```

An explicit `--swift /absolute/path/to/swift` selects a toolchain. The baseline
extraction fails closed if its unique fields or normalization expression no
longer match. Only type nesting/name and initializer wrapping are adapted;
timestamp fields and the payload expression retain baseline behavior. The
candidate helper is copied without transformation. Both variants use the same
harness and compiler flags. Actual XCTest source is copied without changes
into a dependency-free temporary package.

Durable evidence:

- [Linux manifest](evidence/linux-x86_64/manifest.json),
  [summary](evidence/linux-x86_64/summary.json),
  [raw observations](evidence/linux-x86_64/rows.jsonl.gz), and
  [matching test receipt](evidence/linux-x86_64/tests.json).
- [Linux source/command/stdout/test receipt bundle](evidence/linux-x86_64/receipts.json.gz).
  It is a gzip-compressed JSON dictionary mapping relative paths to their exact
  text contents, including all commands, process logs, staged sources, and the
  separately passing tests.
- [A/A manifest](evidence/linux-aa/manifest.json),
  [summary](evidence/linux-aa/summary.json),
  [raw observations](evidence/linux-aa/rows.jsonl.gz), and
  [complete receipts](evidence/linux-aa/receipts.json.gz).

Source and binary hashes, compiler/platform information, raw paired values,
environment overrides, command return codes, and measurement boundaries are
recorded. No benchmark opens user media or player preferences.
