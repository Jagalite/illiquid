# PiP output resource lifetime and idle memory

## Qualification status

**Optimization rejected after completed native qualification (2026-10-29).** [Run 40639953619](https://github.com/Jagalite/illiquid/actions/runs/40639953619), job [122655532955](https://github.com/Jagalite/illiquid/actions/runs/40639953619/job/122655532955), completed successfully on the isolated macOS runner, but a green workflow **does not demonstrate a memory improvement**. The candidate releases its stopped pool/observer and HDR working-texture owner correctly; nevertheless, in all six paired comparisons for each workload, its settled `MTLDevice.currentAllocatedSize` is **higher** than the baseline, and production first-sample re-entry is slower. **No optimization PR should be opened.**

The actual measured source/test/harness/runner commit is
[`47b51e515b11da06fc454c1209bbd189dddd7a40`](https://github.com/Jagalite/illiquid/commit/47b51e515b11da06fc454c1209bbd189dddd7a40).
The [raw evidence](../Benchmarks/PiPIdleMemory/evidence/run-40639953619/) is retained from that run; subsequent documentation/evidence-only commits do not change the tested inputs. The [workflow artifact](https://github.com/Jagalite/illiquid/actions/runs/40639953619/artifacts/12867161212) also contains staged source files and build/measurement logs.

## Scope

This study compares the native subtitle Picture in Picture compositor at
baseline `ea2ff568237e2667f7b1aeee67b11a44ebe95b72` with the candidate that
retires stopped output resources after GPU completion and drains its dedicated
queue's autorelease pool after each work item.

The compositor survives between PiP sessions. The baseline stops admission and
flushes the presenter but retains its output pool, observer, HDR working
texture, and cache ownership. The candidate preserves the cached decoded
input, prepared captions, subtitle uploads, and compiled pipelines while
retiring the video output storage.

## Why the cleanup has two lifetime boundaries

A stop request invalidates pending work immediately. Submitted GPU operations
still finish with their explicit resource ownership intact. The existing
composition fence rejects their stale outputs, and an inactive worker schedules
retirement only after its completion-processing work item returns. A later
restart prevents obsolete cleanup from flushing or retiring the new session.

Swift local references ending does not by itself drain Objective-C autoreleased
objects. Apple's [Metal guide](https://developer.apple.com/library/archive/documentation/Miscellaneous/Conceptual/MetalProgrammingGuide/Cmd-Submiss/Cmd-Submiss.html)
identifies command buffers and encoders as autoreleased transient objects.
The dedicated queue now uses [`.workItem`](https://developer.apple.com/documentation/dispatch/dispatchqueue/autoreleasefrequency/workitem),
which drains those temporary owners after each asynchronous block. The next
cleanup operation can then flush unused Core Video wrappers and pool buffers.

This distinction matters because an [earlier unmerged experiment](https://github.com/Jagalite/illiquid/blob/428c511b324b1e5388f64f5470aafa06107cec16/Documentation/PIP_IDLE_RESOURCE_MEMORY.md)
observed rising device allocation counters despite cleared owner fields.
That prior result motivates the repeated-session check; it is not evidence for
this candidate's result. Its [completed follow-up](https://github.com/Jagalite/illiquid/actions/runs/40014008137/job/120621291116)
later showed that the initial growth settled by the second production-only
cycle. Retirement-only and work-item-autorelease variants reached identical
allocation plateaus, so it did not establish an independent memory benefit
from the autorelease setting. This study likewise measures the joint candidate
and does not isolate a separate benefit from that queue setting.

## Method and provenance

See the [reproduction protocol](../Benchmarks/PiPIdleMemory/README.md).
The runner builds the complete native test graph for each variant in separate
worktrees. It verifies the frozen baseline blob and round-trips every inert
testing instrumentation change to recover the original source exactly.
It records compiler, host, Metal device, source, executable, and command hashes.

The comparison contains six fresh-process pairs in alternating order. Each
process first runs eight real production start/stop cycles for 1080p SDR and
4K HDR, with no retained output buffers or companion readbacks. Stopped-device
observations include 150 ms settling after each cycle, a final one-second
settle, and an extra five-second observation for both variants in pair zero.

Eight separate direct-composition cases cover 1080p/4K, SDR BGRA/HDR PQ P010,
and one/twelve simultaneously retained outputs. They compare every logical
pixel byte and output color tag, verify resource ownership, and record six
resource-recreation samples through GPU completion. Those timings exclude
normal worker scheduling, presenter enqueue, and AVKit UI. The production
cycle timing separately ends at the actual first-sample callback after enqueue.

## Results — actual completed qualification

### Test execution, provenance, and parity

The isolated `macos-26-arm64` runner used macOS **26.6.2**, Xcode **26.6**, Swift **6.3.3**, a virtual Apple M1 CPU, and an **Apple Paravirtual** Metal device. Baseline `ea2ff568237e2667f7b1aeee67b11a44ebe95b72` and tested candidate `47b51e515b11da06fc454c1209bbd189dddd7a40` built their full native test graphs serially in separate worktrees. The baseline original source blob `6ec0cd6317cbecbe40d92ed894fec86a4134438c` was preserved; the read-only baseline instrumentation reversed to exactly the original source. The manifest records each executable's SHA-256 and the command journal ties builds/tests/measurements to their variant-specific binaries.

The existing five selected suites executed **44/44 tests** on the baseline and passed. The baseline's idle-retirement negative-control test **actually executed and failed** the intended pool/observer ownership expectations (exit 1; four assertion issues), rather than failing to compile or selecting zero tests. The candidate executed **49/49 selected tests** and passed, including all five new lifetime functions. The HDR test actually exercised both **PQ and HLG**, and the GPU-drain/shared-event, externally retained buffers/twelve-buffer limit, gated restart, and caption upload-reuse tests executed. The separately selected `mediaSessionMirrorsEmbeddedPacketsAndSeekInvalidationToBothPipelines` test returned early without its optional fixture; **embedded-media behavior was not exercised**.

Across **six alternating-order fresh-process pairs (12 processes)**, eight direct cases have identical complete logical-pixel SHA-256 and color tags across baseline, candidate, restarts, and processes. Each case has six GPU-completed direct-composition recreation samples. Checks of all 28 recorded commands, log receipts, staged-source hashes, baseline negative-control log, process order, raw observations, pixel parity and independently recomputed paired summaries agreed. The **21** `PIP_IDLE_EVIDENCE_JSON` emitted files were independently SHA-256 checked and matched the retained artifact bytes.

### Production stopped-state device allocations and first-sample re-entry

Each fresh process ran eight real receive/start/first-sample/stop cycles per workload **before direct output readbacks** and without holding output buffers or output probes. Stopped compositor and cached input remained alive. Final values below are after the 1 s settle. The growth column compares stopped cycle 1 with stopped cycle 8; all allocation values are **Metal device counters, not RSS or reclaimed physical memory**. Re-entry values are per-process medians of the seven cycles after cold start and end at the actual presenter first-sample callback, including GPU completion and enqueue.

| Workload | Pair | Baseline final MiB | Candidate final MiB | Candidate excess MiB | Cycle 1→8 growth B / C MiB | First-sample re-entry B → C ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1080p SDR BGRA | 0 | 16.8 | 48.5 | +31.6 | 0.0 / 31.6 | 2.80 → 14.89 |
| 1080p SDR BGRA | 1 | 24.7 | 48.5 | +23.7 | 7.9 / 31.6 | 2.47 → 7.54 |
| 1080p SDR BGRA | 2 | 16.8 | 48.5 | +31.6 | 0.0 / 31.6 | 2.51 → 8.91 |
| 1080p SDR BGRA | 3 | 16.8 | 56.4 | +39.6 | 0.0 / 39.6 | 2.46 → 6.58 |
| 1080p SDR BGRA | 4 | 16.8 | 48.5 | +31.6 | 0.0 / 31.6 | 1.72 → 11.15 |
| 1080p SDR BGRA | 5 | 16.8 | 48.5 | +31.6 | 0.0 / 31.6 | 2.33 → 11.48 |
| 4K HDR PQ P010 | 0 | 183.0 | 285.9 | +102.9 | 23.7 / 189.9 | 5.25 → 43.26 |
| 4K HDR PQ P010 | 1 | 183.0 | 285.9 | +102.9 | 23.7 / 189.9 | 5.99 → 29.08 |
| 4K HDR PQ P010 | 2 | 183.0 | 262.1 | +79.2 | 23.7 / 166.2 | 5.20 → 46.89 |
| 4K HDR PQ P010 | 3 | 183.0 | 238.4 | +55.4 | 23.7 / 142.4 | 5.61 → 40.61 |
| 4K HDR PQ P010 | 4 | 183.0 | 190.9 | +7.9 | 23.7 / 95.0 | 5.24 → 92.03 |
| 4K HDR PQ P010 | 5 | 183.0 | 285.9 | +102.9 | 23.7 / 189.9 | 5.24 → 58.59 |

Every candidate has a higher final settled device counter: **+23.7 to +39.6 MiB** at 1080p SDR (median excess **31.6 MiB**) and **+7.9 to +102.9 MiB** at 4K HDR PQ (median excess **91.0 MiB**). The baseline's 4K cycle-one allocation (159.2 MiB) rose once to 183.0 MiB and then stabilized; the candidate's lower first-stop reading (96.0 MiB) rose over subsequent cycles to 190.9–285.9 MiB. This initial ownership saving therefore did **not** produce a durable lower observed device counter. At 1080p the candidate generally rose by 7.9 MiB per new pool through warmup, whereas the baseline stayed nearly flat. The candidate often plateaued by later cycles, so the evidence does **not** establish unbounded leakage. After the extra **5 s** settle in pair zero, both variants' device counters remained unchanged from their 1 s values (including the adverse candidate readings).

Production re-entry was slower in every pair. The median of paired per-process slowdown percentages was **+323.6%** for 1080p SDR (paired range +167.1–+548.9%) and **+762.7%** for 4K HDR PQ (+385.7–+1655.6%). These are first-sample callback timings, **not** visible PiP-window latency. Cold start was measured separately and not mixed into these medians.

### Direct GPU-completed resource recreation

The following are medians of each variant's six per-process median values; the last column is the separately recomputed median of six **paired** percentage changes. These component-only timings exclude normal worker scheduling, presenter enqueue, AVKit, shader initialization, source preparation, and output hashing.

| Case | Held outputs | Baseline median ms | Candidate median ms | Median paired slowdown |
| --- | ---: | ---: | ---: | ---: |
| 1080p-SDR BGRA | 1 | 1.74 | 5.47 | +299.7% |
| 1080p-SDR BGRA | 12 | 1.42 | 4.80 | +224.7% |
| 1080p-HDR PQ P010 | 1 | 2.00 | 8.59 | +392.4% |
| 1080p-HDR PQ P010 | 12 | 2.07 | 10.13 | +402.3% |
| 4K-SDR BGRA | 1 | 2.60 | 15.22 | +477.6% |
| 4K-SDR BGRA | 12 | 2.67 | 18.52 | +630.7% |
| 4K-HDR PQ P010 | 1 | 4.57 | 44.06 | +924.2% |
| 4K-HDR PQ P010 | 12 | 4.44 | 39.58 | +756.4% |

All eight direct-composition cases are slower in the candidate; no case demonstrates a restart latency improvement.

### Actual ownership versus allocation counters

After idle drain the candidate has **no strongly owned output pool or pool observer** in any of the eight cases across all twelve processes, and no owned HDR working texture. The baseline retains its pool and observer; its HDR texture reports `allocatedSize` **16,596,992 bytes** at 1080p and **66,355,200 bytes** at 4K, versus zero for the stopped candidate. Weak output-buffer probes are zero after strong owners are dropped in both variants; externally retained old outputs still work as asserted by the test. This verifies the lifetime behavior but does **not** offset the adverse multi-cycle device-counter result. The new pool's twelve-buffer limit is per pool, not a global cap on externally held old-pool buffers.

### Decision

**Not successful; do not create a PR against `main`.** The correctness and pixel-fidelity checks passed, but the candidate failed the required net settled-memory and acceptable re-entry tradeoff criteria. Its explicit resource retirement can coexist with larger observed Metal allocator footprints after repeated starts; neither the virtual device's allocator behavior nor the recorded data proves why. There is no claim of an OS page reclamation, RSS, whole-player RAM, FPS, energy or visible-window benefit. The candidate code remains confined to this unmerged experiment branch; the [complete run artifact](https://github.com/Jagalite/illiquid/actions/runs/40639953619/artifacts/12867161212) retains staged sources and raw logs.

### Historical evidence used to improve the protocol

The October 23 follow-up belongs to a different implementation and baseline.
It compared three fresh processes per variant and workload. Its production
cycles followed two direct-composition sessions; initial device allocation
growth settled by the second production cycle. The reported settled
`MTLDevice.currentAllocatedSize` observations were:

| Historical workload | Baseline bytes | Retirement-only bytes | Retirement plus work-item autorelease bytes |
| --- | ---: | ---: | ---: |
| 1080p SDR | 30,142,656–38,437,120 | 17,637,504 | 17,637,504 |
| 4K HDR | 245,857,792 | 125,508,096 | 125,508,096 |

Source: the [completed follow-up job's summary and raw observations](https://github.com/Jagalite/illiquid/actions/runs/40014008137/job/120621291116).
These are Metal allocation counters, not RSS. The historical candidate also
released caption resources. Its baseline, retained resources, warmup, and
measurement order differ from this study, so none of those values is an
estimate of this candidate's result.

The identical retirement-only and work-item trajectories do not isolate an
autorelease benefit. They also show why a single stop observation would give an
incomplete picture: cleared compositor fields and a temporarily elevated
device counter can coexist. This study consequently measures repeated
production sessions before any readbacks and preserves the complete
trajectories, including settling time.

### Optimization PR decision criteria (evaluated)

1. Both variants must build their complete native test graph with the recorded
   toolchain and real Metal/Core Video resources.
2. Existing selected regression suites must pass. The candidate's new lifetime
   tests must pass. The baseline negative control must fail the intended
   retirement assertion after executing the test; a build failure or empty
   selection does not qualify.
3. Logical pixel bytes and color tags must match across variants, restarts, and
   fresh processes.
4. Candidate stopped-state ownership must retire only after submitted work has
   drained. Externally held outputs and the twelve-buffer limit must retain
   their specified behavior.
5. Review all six pairs' production allocation trajectories, including warmup
   and cycles two through eight. Field clearing alone does not establish a
   net memory benefit. A growing device allocation trend or no meaningful
   settled reduction needs investigation rather than a success claim.
6. Report the production first-sample re-entry cost separately from direct
   composition recreation cost. An idle-memory reduction can trade away
   re-entry speed.
7. Verify emitted evidence hashes and source provenance, retain the actual
   logs and observations, and check the current base plus overlapping changes
   before integration.

A green workflow is necessary but not sufficient for the memory conclusion:
the runner deliberately does not impose a numeric device-allocation threshold
on the hosted environment. The evidence needs interpretation.

## Correctness

The candidate adds five regression functions, with the HDR test parameterized
for PQ and HLG:

| Regression | Required behavior |
| --- | --- |
| Idle bitmap-caption retirement | Pool and observer ownership ends; identical recreated pixels reuse unchanged caption uploads. |
| PQ and HLG HDR retirement | The old HDR working texture loses its final strong owner; recreated pixels and output tags match. |
| Externally held output buffers | Twelve old outputs remain valid after retirement; the new pool admits twelve outputs and rejects its thirteenth. |
| Queued stop followed by restart | A deterministic CPU queue gate shows that stale stop work cannot flush or retire the restarted session. |
| Submitted GPU operation followed by stop | A shared-event gate keeps the real command outstanding; resources survive until completion, the stale sample is rejected, and restart uses the cached frame. |

The workflow also selects the existing PiP pipeline, upload-reuse, composition
policy, video-mapping, and transition suites for both variants. The existing
`mediaSessionMirrorsEmbeddedPacketsAndSeekInvalidationToBothPipelines` test
returns early without a configured media fixture. This workflow does not
supply that optional fixture, so its selection must not be presented as
executed embedded-media coverage.

All five new lifetime functions were executed and passed on the candidate;
the baseline's intended negative control failed as required. This runtime
validation establishes the specified ownership behavior, not a favorable
idle-memory or performance outcome.

## Interpretation and limitations

Metal resource ownership, `MTLDevice.currentAllocatedSize`, and process RSS
are different measurements. This study reports the first two and does not
claim a total-player RAM, physical-page reclamation, energy, or playback-FPS
improvement. Buffer payload bytes exclude allocation overhead; device counters
may include framework caches and are not additive with individual resource
bytes.

Externally held output buffers remain valid after their old pool is retired.
A new pool retains the existing twelve-buffer threshold; this is a per-pool
limit, so old externally held outputs can briefly coexist with a new pool.
Caption uploads and the cached input remain intentionally alive.

The same cleanup area is also explored in unmerged branches
`perf/pip-video-storage-retirement-20261028`,
`perf/pip-hdr-texture-stop-20261028`, and
`perf/pip-idle-resources-20261023`. These implementations overlap and should
be reconciled during integration. This candidate combines deferred GPU drain,
restart-safe presenter cleanup, warm caption reuse, explicit autorelease
boundaries, and a protocol for repeated-session allocation evidence.

## Candidate integrity

These SHA-256 digests identify the committed inputs of the **completed** run.
They were independently cross-checked against the emitted manifest and staged
sources, where available; the runner separately recorded executable hashes.

| Input | SHA-256 |
| --- | --- |
| [PiPSubtitleCompositor.swift](../Sources/IlliquidNativePlayback/Presentation/PiPSubtitleCompositor.swift) | `5c15f687f02dac9ae403c0016b017a454a9bee78a2bc4bd1ae293157361ccb07` |
| [PiPIdleResourceLifetimeTests.swift](../Tests/IlliquidNativePlaybackTests/PiPIdleResourceLifetimeTests.swift) | `2dfb564674583a5e3c875ca63f7ff720cac03f1a95099e42b4198e7ed89488b8` |
| [Harness.swift](../Benchmarks/PiPIdleMemory/Harness.swift) | `f9ff897cb5cb4159f4e71af187a479f2dfb8c1dce2c349f44e9b538e4ed9d81d` |
| [run.py](../Benchmarks/PiPIdleMemory/run.py) | `22ee00c1bdbbfbc7c6bac1448911bc91ab5f6a9588f7f24cd5953c88f3fdbde2` |

The baseline and instrumentation verification procedure is documented in the
[benchmark README](../Benchmarks/PiPIdleMemory/README.md). The 21 exact emitted
evidence files are committed under [run-40639953619](../Benchmarks/PiPIdleMemory/evidence/run-40639953619/).
The complete build, staged-source and measurement logs remain in the
[workflow artifact](https://github.com/Jagalite/illiquid/actions/runs/40639953619/artifacts/12867161212).
