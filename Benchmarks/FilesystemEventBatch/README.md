# Filesystem callback path materialization

This experiment compares the previous native callback's collection loop with
the production `SourceFilesystemEventBatch` decoder. The existing downstream
event buffer already replaces a callback containing more than 4,096 valid
paths with one event-loss recovery marker. Preflighting pointer presence avoids
allocating path strings and event storage that would immediately be discarded.

```sh
python3 Benchmarks/FilesystemEventBatch/run.py \
  --output /tmp/illiquid-filesystem-event-batch --pairs 6 --target-ms 60
```

Use a new or empty output directory and Swift 6.1 or later. `--swiftc` selects a
compiler explicitly. No third-party Swift packages or native media SDK are
needed. Follow `AGENTS.md` and use the shared Kyoto queue when it is available.

## Source identity and correctness

`baseline/` freezes the exact monitor and event-policy files at commit
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`. The runner verifies both their SHA-256
digests and Git blob identities. It extracts the original collection statements
using the original raw-pointer indexing, and replaces the native flag-mapping
call with the same synchronous closure
boundary used by the candidate. The candidate decoder and policy are compiled
directly from production files. `manifest.json` records their identities, the
extracted baseline adapter, harness hashes and compiled binary hashes. The
runner rejects source changes during an experiment.

Both debug and optimized binaries compare callback order, paths and flags within
the budget, and compare exact buffered events and invalidation plans for every
case. Oversized cases must produce one candidate marker without reading flags.
Inputs include empty buffers, null entries, sparse buffers whose raw count
exceeds the limit, boundary cases, Unicode, malformed UTF-8, and recovery flags.
The portable regression suite is also available through:

```sh
bash Scripts/test-filesystem-event-loss-regressions.sh
bash Scripts/test-filesystem-event-loss-regressions.sh --configuration release
```

## Measurements

Inputs are owned, null-terminated C strings prepared before measurement. The
same native-shaped pointer and synthetic flag buffers remain alive for both
implementations. This measures the collection/decoding boundary; converting
platform FSEvents flag words, native delivery and scheduling are outside it.

Each fresh process first measures live allocator growth while one decoded
callback array remains alive. Inputs and allocator warmup precede the initial
sample. The final sample precedes traversal of output strings. Path payload
bytes, event counts and flag reads are reported separately. Allocator readings
use the existing `CLeaseHeap` support: `mallinfo2().uordblks + hblkhd` on Linux
and `malloc_zone_statistics(NULL).size_in_use` on macOS. They are neither peak
memory nor process RSS, and small allocations can be absorbed by allocator
caches.

The separate timed loop includes decoding and array destruction, with a small
non-inlined sink to keep returned batches observable. Each variant calibrates
its own iteration count to avoid timing the much faster overflow path over an
interval too short to measure. Iterations are then fixed for all measured
samples. Six fresh-process pairs alternate AB/BA order. Results include all
individual observations, median service times and paired percentage changes;
there is no timing threshold in the correctness tests.

`summary.json`, `observations.jsonl`, calibration data, compressed exact
verification traces, source/compiler manifests, build logs and command receipts
are retained in the output directory. Temporary executables are under `build/`.
The macOS filesystem-event workflow runs this experiment and uploads its output.

## Scope

This is a bound on one decoded callback. It does not bound FSEvents-owned input
memory or the number of small callback tasks awaiting the main actor. The
sidebar's existing accumulated-buffer limit still handles overflow across
multiple callbacks. The experiment does not launch the player, trigger native
FSEvents, perform rescans, or measure playback or input-to-screen latency. The
million-path workload is a synthetic stress case, not an observed event rate.

See [the research report](../../Documentation/FILESYSTEM_CALLBACK_MEMORY.md)
for results and limitations.
