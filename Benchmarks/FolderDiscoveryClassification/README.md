# Folder discovery classification research

## Question and change

`FolderPlaylistDiscovery.discover` originally collected every accepted regular
file into `regularFiles`, then filtered that array once for media and once for
subtitles. The scan had already classified each resolved URL. Those filters
repeated extension extraction and POSIX-locale lowercase conversion, and the
combined array was additional temporary storage.

The candidate appends accepted URLs to the media and subtitle arrays during the
existing scan. It retains the original unsupported-entry shortcut, symlink
resolution, regular-file queries, metadata reads, and cancellation checkpoints.
The two classifications remain independent, including if supported extension
sets overlap in the future. Media-looking directories are rejected before an
additional subtitle classification. `makePlaylist`, sorting, normalization,
deduplication, and subtitle matching are unchanged.

The research hypothesis is lower allocation-request volume during folder
discovery, with potentially lower CPU time. Filesystem and model-construction
costs can dominate the complete operation, so removing passes does not by itself
establish a faster user-visible folder open or a lower process memory footprint.

## Reproduce

On macOS 26 with Xcode 26.6 selected:

```sh
python3 Benchmarks/FolderDiscoveryClassification/run.py \
  --pairs 6 --output /tmp/illiquid-folder-classification-results
```

The output directory must be new or empty. When the shared Kyoto queue is
available, submit that command through the queue as required by `AGENTS.md`:

```sh
python3 /Volumes/seed1/Projects/kyoto/kyoto.py submit -- \
  python3 Benchmarks/FolderDiscoveryClassification/run.py \
  --pairs 6 --output /tmp/illiquid-folder-classification-results
```

The workflow checks queue availability before running isolated builds directly.
The portable workflow uses Swift 6.3.2 on Linux/glibc, with a narrower allocator
probe. Platform results must be reported separately.

## Experiment design

The baseline is `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`; the original discovery
file is pinned to Git blob `ed360be504b966541b75ccda98486cbe788dfd92`.
The runner snapshots and hashes seven complete production source files and
rejects changes to any supporting production file. Baseline and candidate are
compiled as separate optimized Swift modules. The driver does not reimplement
the discovery algorithm.

Both versions run the same discovery, filesystem, classification, playlist, and
prepared-playlist regression suites in Debug and Release. The new tests compare
mixed listings with the original discovery pipeline, cover every supported
uppercase extension, and test cancellation at every original checkpoint. On
Darwin, injected forward and reversed listings additionally verify order
independence. Linux uses actual filesystem enumeration because corelibs
Foundation does not permit overriding that `FileManager` method. Existing tests
exercise broken, hidden, relative, chained, and
retargeted symlinks; directory links; named pipes; missing folders; and shallow
enumeration.

The measurement campaign uses these real temporary directories. Ordinary files
are empty because discovery reads their identity and metadata, not media bytes.

| Fixture | Media files | Subtitle files | Other entries |
| --- | ---: | ---: | --- |
| Empty | 0 | 0 | 0 |
| Small mixed | 25 | 50 | 0 |
| Media only | 1,000 | 0 | 0 |
| Medium mixed | 250 | 500 | 0 |
| Large mixed | 1,000 | 2,000 | 0 |
| Subtitle only | 0 | 1,000 | 0 |
| Unsupported control | 0 | 0 | 1,000 unsupported files |
| Symlink rich | 100 canonical targets | 200 canonical targets | Unsupported targets, duplicate media aliases, broken/hidden/directory links, misleading extensions, and a nested directory |

The default/native campaign uses six pairs per fixture and alternates
baseline/candidate execution order. Fixture
order rotates across pairs. Each observation starts a fresh process, performs
one untimed discovery and complete result serialization, and then measures one
discovery. Timing and allocation campaigns are separate: eight fixtures times
six pairs times two variants times two modes yields 192 measured processes.
All observations are retained.

The portable CI campaign uses two pairs, yielding 64 measured processes:
32 uninstrumented timing observations and 32 allocation observations. This is
two observations per variant, fixture, and measurement mode. Timing from this
smaller campaign is exploratory; it does not establish a stable speedup.

Timing uses a binary with no allocation hooks. It records monotonic wall time
and process CPU time across the complete `discover` call. Fixture creation and
result serialization are excluded. Inputs and the returned model stay alive
until the clock reads finish. There is no empty-loop subtraction or automatic
timing threshold.

Every observation compares the complete result against its warmup result and
every other process for the fixture. Receipts include production Codable items,
all dates and subtitle lists, and the absolute/relative/base representations of
URLs. Equality is byte-for-byte after sorted-key JSON encoding. Identical
receipts are retained once per fixture; each observation records their SHA-256.

## Allocation metric and controls

The allocation probe counts successful covered allocation requests and their
requested sizes on the thread calling `discover`. It is active only during the
measured call. Reallocation contributes its entire requested size. The counters
are allocation traffic, not live bytes, peak memory, RSS, or allocations on
other threads.

On macOS the probe intercepts ordinary, typed, and zone allocator entry points.
Typed entry points matter because the
[Swift runtime](https://github.com/swiftlang/swift/blob/main/stdlib/public/runtime/Heap.cpp)
uses `malloc_type_malloc` and `malloc_type_posix_memalign` on supported Darwin
versions. A thread-local nesting guard prevents one request being counted again
as it passes through a lower-level allocator entry point. On Linux/glibc the
probe covers `malloc`, `calloc`, and `realloc`.

Each metered binary must pass a control that allocates and consumes a real
262,144-element Swift byte array. The probe must observe its large request, and
the total requested bytes must be less than twice the payload size. This detects
missing Swift-array coverage and obvious double counting. The control is a
qualification gate, not a substitute for the declared coverage limits.

## Evidence

`manifest.json` records the host, compiler versions, source identities, build
outputs, and experiment boundaries. `tests.json` records positive Swift Testing
completion receipts. `meter-controls.json` records the real-array controls.
`observations.jsonl` retains every measurement; `summary.json` reports medians,
ranges, paired differences, and paired percentage changes. `verification.json`
binds all complete result receipts. Command arguments, exit codes, and logs are
retained alongside the source snapshots.

The accompanying results report identifies each platform's completed and pending
validation separately. These component measurements do not qualify interactive UI latency,
network filesystems, cold-cache scans, decoding, playback, or whole-player memory.
