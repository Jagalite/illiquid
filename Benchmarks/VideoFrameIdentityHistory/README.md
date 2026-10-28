# Video frame identity history

## Hypothesis and production change

The video presenter retains the latest 128 scalar frame identities so it can
identify a displayed pixel buffer and find adjacent timestamps for frame stepping.
After the history fills, its previous enqueue path removes the first array entry
before appending each new frame. That shifts the other 127 records on every
steady-state enqueue while holding the identity lock.

`VideoFrameIdentityHistory` replaces that shift with an overwrite in circular
storage. It retains the same 128-entry bound, newest-match precedence, surface
matching policy, generation filtering, strict one-microsecond stepping tolerance,
and capacity-preserving clear. The presenter continues to own synchronization.
Only scalar IDs, timestamps and generations enter the history; it owns no pixel
buffers or IOSurfaces.

Queries traverse the two physical ranges in logical order. Identity lookup
visits newest first. Adjacent-time selection visits oldest first so equal extrema,
including positive and negative zero, retain their original first-value tie.
The helper adds one integer cursor; it is a CPU/copying optimization, not a
memory-reduction claim.

## Reproduce

Use macOS or Linux with Swift 6.1+ and Python 3.10+. The workflow pins
Xcode 26.6 on macOS 26 and the official `swift:6.3.3-noble` container on
Ubuntu 24.04. The Linux job tests and measures the platform-independent helper;
the macOS jobs separately measure native behavior and compile the application.
Follow the repository's Kyoto queue coordination when that queue is available.
Hosted CI checks that the shared queue is absent before direct builds.

```sh
python3 Benchmarks/VideoFrameIdentityHistory/run.py --tests-only \
  --output /tmp/illiquid-frame-history-tests
python3 Benchmarks/VideoFrameIdentityHistory/run.py \
  --pairs 8 --target-ms 150 --max-sample-ms 2000 \
  --output /tmp/illiquid-frame-history-timing
```

Use a new empty output directory for each attempt and run one benchmark at a time.
The component harness needs no FFmpeg/libass or app launch.

## Baseline and correctness

The frozen presenter comes from `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`.
The runner checks its SHA-256, extracts the exact original identity declaration
and history statements, and puts those statements behind the candidate's helper
interface. The adaptation removes the native presenter wrapper and external
lock; it supplies the scalar surface/buffer IDs that the original presenter
computed before entering the lock. It preserves the original array eviction,
lazy adjacency pipeline, reverse lookup and clear statements. The complete
adapted source is saved alongside source/compiler/binary hashes and commands.

Both variants run the same regression tests in debug and release with warnings
as errors. Coverage includes empty/partial/full/wrapped histories, reused IDs,
surface-only matching without buffer fallback, nonmonotonic timestamps,
generation filtering, strict tolerance boundaries, signed-zero ties, nonfinite
times, flush/refill and copy-on-write snapshots. Four seeded 4,096-step mixed
operation sequences compare complete identities and timestamp bit patterns with
an independent array reference.

## Workloads and measurement boundary

| Case | One measured operation |
| --- | --- |
| `steady-append` | Append one identity to an already full history |
| `append-lookup` | Append, then look up that newest identity |
| `cold-fill` | Clear and append 128 identities |
| `flush-refill` | Clear and append eight identities |
| `lookup-newest/middle/oldest/missing` | One buffer lookup in a full history |
| `lookup-surface-reuse` | One surface lookup with reused IDs and generations |
| `adjacent-forward/backward` | One timestamp selection in a full, nonmonotonic history |

Despite the legacy case name `cold-fill`, repeated clear/fill iterations reuse
array capacity; only the first measured fill can allocate initial storage.
It is not a startup-latency measurement.

The history module and identical driver are optimized separately, without
cross-module optimization. Fixtures and full verification are outside timing.
Full histories begin at a seed-dependent physical rotation, so lookup controls
do not accidentally measure only an unwrapped ring. Append state is consumed
by complete post-run receipts; every lookup result contributes to a checksum.
Warmup outputs and each pair's full identity/timestamp receipts must agree.
The reference calculates expected last-128 state without a timing-sized replay.

Eight fresh-process pairs alternate AB/BA order. Both variants receive the same
iteration count and seed within a pair. Calibration targets 150 ms on the faster
variant with a 1.5x margin and an estimated two-second cap on the slower variant.
Every sample is retained; no control cost is subtracted. Raw wall/process-CPU
times, calibration, receipts, tests, commands, environment and hashes accompany
the summaries. Timings are evidence, not percentage-based CI pass/fail gates.

The separate native integration job builds the actual application dependency
graph and runs the history, presentation-time observation and frame-step tests.

## Results and interpretation

Results will be recorded after the branch runs complete, with Linux and macOS
evidence labeled separately. Measurements
cover warm history operations and exclude the presenter lock, pixel-buffer
identity extraction, sample construction, decoding and rendering. They do not
establish a whole-player CPU, frame-rate, visible latency or energy improvement.
