# Transient subtitle-result ownership

This native macOS experiment measures how much **live allocation storage remains
owned by `SubtitleDecoder`'s temporary FFmpeg `AVSubtitle` result after `decode`
returns**. It compares the complete original decoder at
`af1c1add701e49b355448cf8983eaed1e7623108` with the working-tree implementation.

The original implementation copies text into owned `Data` and bitmap rectangles
into owned premultiplied BGRA `Data`, then retains the original FFmpeg result until
the next decoded packet, an explicit flush, or decoder destruction. Sparse
subtitle packets leave that redundant output alive between captions. A cropped
PGS object can make the difference especially large: the source output retains
the entire decoded indexed image even when the application copies only a tiny
crop.

The candidate resets that result when the synchronous decode method exits. The
experiment establishes ownership lifetime independently from application-event
lifetime and codec-private state.

## Run

Use the repository's macOS/Xcode configuration and install its verified native
SDK using `Scripts/install-ci-native-sdk.py`, then run:

```sh
python3 Benchmarks/SubtitleResultLifetime/run.py \
  --output /tmp/illiquid-subtitle-result-lifetime
```

The output directory must be absent or empty. `--ffmpeg-prefix` and `--swiftc`
allow explicitly selecting installed paths. The runner downloads no dependencies
and makes no changes to the application or pinned baseline.

A portable input-integrity check is available without Swift or native libraries:

```sh
python3 Benchmarks/SubtitleResultLifetime/run.py --validate-inputs
```

## Scope and measurement

`LifetimeProbe.h` synchronously visits the original, still-live result's rectangle
pointer array, each rectangle, its four data pointers, and its text/ASS strings.
It deduplicates non-null pointers and calls native `malloc_size` on their
allocation bases. It also records the indexed-plane byte extent, text byte
extent, rectangle count, output flag, and live allocation count. The probe aborts
if a fixture supplies a non-null pointer that is not recognized as a live malloc
allocation base. Cropped local rectangle copies are never observed: their plane
pointers may be interior addresses.

The same read-only `ProbeExtension.swift` is appended to both staged decoder
files, permitting Swift same-file access to the private result. No production
method is rewritten for observation. The complete baseline file is retained in
`baseline/`, and the runner verifies its Git provenance. Complete support files
and several complete support declarations are staged verbatim from production;
all are hash-pinned and identical in both variants. Extracted declarations and
their hashes are recorded explicitly. There are no platform stubs or replacement
codec implementations.

The primary number is **live malloc block bytes owned by the transient decoded
result**, including allocator rounding and result-owned headers. It excludes:

- The small persistent result structure itself.
- FFmpeg's codec-private object, palette, and other caches.
- Caller-owned Swift event data, which remains intact.
- Allocator-retained free pages, process RSS, and whole-player footprint.

Thus releasing four MiB of result-owned blocks does not prove a four MiB process
RSS reduction. The lifetime result is bounded to the most recent subtitle output;
this is unnecessary retention, not a demonstrated accumulating leak. Neither
decoder throughput nor whole-player speed is measured.

## Workloads and checks

The harness authors real compressed subtitle packets and decodes them through the
actual production `SubtitleDecoder` and pinned FFmpeg libraries.

| Workload | Purpose |
|---|---|
| SubRip text | Own ASS bytes survive transient-output release |
| 2 × 2 PGS object | Tiny bitmap, palette, forced flag, and reset control |
| 1920 × 1080 PGS object | Full bitmap output and large original index plane |
| 4096 × 1024 PGS object cropped to 1 × 1 | Large original output with a four-byte application bitmap |
| 4096 × 1025 PGS object | Application display-byte rejection after FFmpeg has produced output |
| 1920 × 1080 PGS with a 1024-byte event budget | Budget rejection after decode |
| Truncated PGS composition | Error before FFmpeg decode; zero-allocation control |
| 2 × 2 DVB page | Stateful second bitmap codec and page reset |

Every workload runs in both debug and optimized builds of both implementations:
**32 separate process observations and 16 baseline/candidate output comparisons**
when the complete runner succeeds. Process order alternates by workload. There
are no timing samples or discarded observations.

For each process, the harness observes the result before decode, immediately
after return, after a 50 ms interval with no new packet, after another real packet,
after caller events are dropped, after explicit flush, after decoding again, and
at final cleanup. The idle interval is an observation of a quiescent decoder;
there is no timer-based release mechanism being tested and no assertion that
longer wall-clock playback was executed.

The first output is checked against authored expectations for timing, generation,
bitmap geometry, complete white BGRA pixels, or text presence. Expected rejection
messages are checked. Complete length-prefixed output streams contain all event
metadata and every text/bitmap byte, including the first event after another
packet and events retained across flush. The runner compares those streams
byte-for-byte, retains deterministic gzip copies, and records the original length
and SHA-256. The same semantic outputs are also checksummed independently at each
lifecycle point.

The candidate must report zero transient output at every measured boundary. The
baseline must retain nonzero output after the initial successful decode or
post-decode rejection in each target workload. That expected failure of the
candidate's zero-retention assertion is recorded explicitly in
`baseline-regression-demonstration.json`. Initial, explicit-flush, final, and
pre-decode malformed controls must be empty. Caller-event budget reservations
must match the baseline at every boundary and return to zero after events are
dropped.

## Evidence layout

- `completion.json`: machine-readable completion, comparison, and expected-failure counts.
- `summary.json`: native block sizes and complete-output comparison receipts.
- `observations/`: all individual lifecycle snapshots and event checksums.
- `outputs/*.bin.gz`: the exact complete event streams from both variants.
- `baseline-regression-demonstration.json`: original implementation fails the new lifetime invariant.
- `receipt.json`: host, compiler, source/extraction, binary, SDK, and loaded-library provenance.
- `commands.json` and `logs/`: every command, exit status, and complete diagnostic output.
- `sources/`: the actual staged input files and observer used to build the binaries.

The runner rehashes all inputs and executables after measurement. Results are
valid only when `completion.json` reports `complete: true`. This README describes
the protocol; native results must be read from a completed retained evidence set.
