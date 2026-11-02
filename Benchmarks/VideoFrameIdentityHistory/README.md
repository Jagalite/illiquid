# Submitted video frame identity history

This study replaces the video presenter's bounded array history with circular
storage. The measured improvement is in scalar bookkeeping during frame
submission. Retained video memory, playback FPS, and whole-player CPU usage were
not measured.

## Finding and change

At baseline `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`,
`SampleBufferVideoPresenter.enqueue` keeps the latest 128 `FrameIdentity` records.
Once full, it calls `removeFirst()` before every append while holding
`identityLock`. On the measured x86_64 toolchain each record has a 32-byte stride,
so the operation logically shifts 127 records, or 4,064 bytes, before inserting
the new record. The original optimized array replacement also contains a
`memmove` call.

`VideoFrameIdentityHistory` grows to the same 128-entry limit and then overwrites
the oldest slot. An insertion index preserves submission order across wrapping.
The presenter delegates its existing history operations through the same lock
scopes and keeps its nested `FrameIdentity` name as a typealias. Renderer calls,
sample-buffer ownership, generation admission, and flush placement are unchanged.

Queries use scoped, read-only access to the array's contiguous storage. They scan
the two logical spans without copying records into temporary arrays. A pointer
never escapes its closure, and all indices come from the private insertion-index
and count invariants. The array is never mutated during these reads. In the
presenter these reads remain inside `identityLock`.

The history was already bounded and already stored only scalar IDs, time, and
generation. This change removes repeated record movement; it does not fix a
pixel-buffer leak or establish a reduction in retained heap or RSS. The insertion
index adds a scalar field to the history representation. Flush continues to
retain backing-array capacity.

## Behavior qualification

Eight Swift Testing tests pass in debug, release, and AddressSanitizer builds on
Linux with Swift 6.3.2 and warnings treated as errors. The mixed-operation test
runs three deterministic seeds with 4,000 operations each against an independent
bounded-array oracle. Coverage includes:

- Empty history, the 128-entry boundary, repeated wrapping, flush, and refill.
- Reused surface/buffer IDs, newest-submission selection, surface precedence, and
  generation-independent identity lookup.
- Generation-filtered timestamp extrema, nonmonotonic timestamps, strict
  `0.000001` tolerance, direction zero, signed-zero ties, NaN, and infinities.

AddressSanitizer completed without an invalid-access report. Leak detection was
disabled (`ASAN_OPTIONS=detect_leaks=0`); that run qualifies the scoped buffer
accesses rather than retained-memory behavior. An independent code review also
checked bounds, pointer lifetime, chronological tie selection, and the presenter
integration.

These tests compile the actual helper into an isolated module. They do not
construct an Apple renderer or decode media. The focused workflow runs the same
tests and measurements on Linux and macOS. Its macOS result was still queued when
the local research was recorded. A focused macOS pass would still not establish
live rendering or paused-frame stepping. Existing native parity tests require
fixtures and `ILLIQUID_PARITY_SHOW_WINDOW=1` to exercise that behavior.

## Measured result

The final cohort uses Swift 6.3.2, Linux x86_64/glibc 2.39,
`-O -whole-module-optimization -swift-version 6`, and separate production-module
and driver compilations. There are **34 workloads and 408 timed observations**:
six fresh-process baseline/candidate pairs per workload, alternating execution
order. CPU time and wall time are both retained.

The table reports median **process CPU nanoseconds per operation**, with the
existing uncontended lock included. Percentage changes are ratios of the two
medians; the raw data also retains every paired percentage and range.

| Operation | Array baseline | Circular history | Change |
| --- | ---: | ---: | ---: |
| Append to a full history | 69.43 ns | 27.83 ns | 59.9% lower |
| Append and look up the newest record | 84.94 ns | 48.13 ns | 43.3% lower |
| Newest lookup, wrapped history | 19.13 ns | 18.99 ns | Essentially unchanged |
| Oldest lookup, wrapped history | 94.22 ns | 94.91 ns | 0.7% higher |
| Missing lookup, wrapped history | 92.25 ns | 90.91 ns | 1.5% lower |
| Forward adjacent time, wrapped history | 116.74 ns | 131.11 ns | 12.3% higher |
| Backward adjacent time, wrapped history | 105.54 ns | 128.03 ns | 21.3% higher |
| Forward adjacent time, insertion index zero | 110.06 ns | 162.73 ns | 47.8% higher |
| Missing lookup, insertion index zero | 89.15 ns | 116.95 ns | 31.2% higher |
| Clear and refill 256 records | 12,732.90 ns | 7,491.46 ns | 41.2% lower |

**Tradeoff:** full-history writes improve substantially at this component
boundary, while several read-only controls are slower. Locked timestamp-query
medians increased by about 14–53 ns, depending on direction and insertion index.
All controls, including less favorable results and clear/refill sizes
0/1/64/128, are retained. Queries remain linear scans over at most 128 entries.

The absolute savings are small: the approximately 42 ns saved per locked append
would total about 2.5 microseconds per second at a hypothetical 60 submissions per
second. That arithmetic is not a measurement of real playback. This PR offers a
bounded O(1) insertion path with explicit query tradeoffs, not an advertised
visible playback improvement.

## Experiment design and evidence

`Baseline.swift` freezes the original append, identity lookup, adjacency, and
clear statements. The runner verifies those statements against the pinned
presenter source before building. The adaptations remove Apple renderer setup
and pixel-buffer ID extraction and place the same optional lock boundary in a
shared bridge. The candidate helper is compiled unchanged.

Both variants use the same separately compiled, non-inlinable public worker
operations. Persistent history remains observable across calls, preventing an
append loop from collapsing into only its final 128 records. Warmup and fixture
creation are outside the timing interval. Timed checksums and complete final
record validation are checked against an independent numeric model. Every
surviving field, both identity modes, evictions, and surface-miss precedence are
verified outside the interval.

Append workloads naturally rotate the history. Read-only workloads explicitly
cover both 384 initial submissions (insertion index zero) and 401 (index 17).
Both lock-inclusive and lock-free controls are recorded. The benchmark excludes
contention, renderer work, decoding, and pixel-buffer ID extraction.

The runner calibrates a common iteration count for both variants toward a 60 ms
baseline interval. The shortest final measured interval was 13.7 ms. It retains
every calibration and measurement; no timing-based exclusions or pass/fail
performance thresholds are applied. Shared-host noise and compiler differences
limit extrapolation to Apple Silicon.

The initial indexed traversal and a subsequent slice-based traversal were
rejected after exploratory measurements exposed slower queries, particularly
after wrapping. The final scoped-buffer implementation reduces that overhead.
Those exploratory cohorts are retained separately and are not mixed into the
final table.

- [Final Linux evidence](Results/linux-swift-6.3.2.json.gz) includes all raw
  observations, calibration, summaries, commands, logs, source snapshots,
  source/binary hashes, completion receipt, and debug/release/sanitizer logs.
- [Exploratory evidence](Results/exploratory-linux-swift-6.3.2.json.gz) preserves
  the three earlier smoke cohorts and their exact sources.

Final evidence SHA-256:
`179d5a411aa9e1154758d87d02a760f2d334ba36ffecdb79299dbb0dcf826f18`.

## Reproduce

Use the shared Kyoto queue when it is available, as required by `AGENTS.md`.
Kyoto was unavailable in this Linux workspace; builds ran directly and serially.
The scripts require Swift 6.1 or newer with bundled Swift Testing, Python 3, and
the pinned baseline commit in the local Git history. The primary package and its
macOS dependencies are not changed by the isolated runner.

```sh
bash Scripts/test-video-frame-identity-history.sh -Xswiftc -warnings-as-errors
bash Scripts/test-video-frame-identity-history.sh -c release -Xswiftc -warnings-as-errors
ASAN_OPTIONS=detect_leaks=0 bash Scripts/test-video-frame-identity-history.sh \
  --sanitize address -Xswiftc -warnings-as-errors
python3 Benchmarks/VideoFrameIdentityHistory/run.py \
  --output /tmp/video-frame-history-results --pairs 6 --target-ms 60
```

The output directory must be empty. `--quick --pairs 2 --target-ms 15` is a
short parity/measurement smoke, not the final research cohort. The runner writes
`completion.json` only after every case, parity check, and final source/binary
identity check succeeds.
