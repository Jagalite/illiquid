# PiP output resource lifetime and idle memory

## Qualification status

**Unqualified candidate; native execution is pending.** At 06:30 UTC on
2026-10-28, [the macOS validation run](https://github.com/Jagalite/illiquid/actions/runs/40639953619)
was still queued and had executed no job steps. The run was created at
05:46:41 UTC. A repository-wide Actions snapshot at 06:25 UTC showed 644
queued runs and two in progress. These are scheduling observations, not
benchmark results.

The editing environment's execution service was unavailable, so this work
could not compile or run locally. The isolated macOS workflow is the validation
route. No test pass, memory reduction, or restart cost is claimed for this
candidate until that workflow executes and its evidence is reviewed.

The source under test is commit
[`47b51e515b11da06fc454c1209bbd189dddd7a40`](https://github.com/Jagalite/illiquid/commit/47b51e515b11da06fc454c1209bbd189dddd7a40).
Later documentation-only commits do not change the measured source.

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

## Results

There are **no measurements of this candidate yet**. The code review identifies
retained video-sized resources and the implementation supplies a retirement
path, but source inspection cannot establish the size, timing, or operating-system
effect of reclamation.

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

### Decision required before opening an optimization PR

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

All of the above are implemented checks awaiting execution for this candidate.
Static review considered worker completion, queue-local ownership, restart
races, and external output lifetimes; it cannot replace compilation or runtime
validation.

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

These SHA-256 digests identify the committed inputs selected for the queued
run. They were calculated from the exact UTF-8 file content; execution evidence
must independently record matching hashes.

| Input | SHA-256 |
| --- | --- |
| [PiPSubtitleCompositor.swift](../Sources/IlliquidNativePlayback/Presentation/PiPSubtitleCompositor.swift) | `5c15f687f02dac9ae403c0016b017a454a9bee78a2bc4bd1ae293157361ccb07` |
| [PiPIdleResourceLifetimeTests.swift](../Tests/IlliquidNativePlaybackTests/PiPIdleResourceLifetimeTests.swift) | `2dfb564674583a5e3c875ca63f7ff720cac03f1a95099e42b4198e7ed89488b8` |
| [Harness.swift](../Benchmarks/PiPIdleMemory/Harness.swift) | `f9ff897cb5cb4159f4e71af187a479f2dfb8c1dce2c349f44e9b538e4ed9d81d` |
| [run.py](../Benchmarks/PiPIdleMemory/run.py) | `22ee00c1bdbbfbc7c6bac1448911bc91ab5f6a9588f7f24cd5953c88f3fdbde2` |

The baseline and instrumentation verification procedure is documented in the
[benchmark README](../Benchmarks/PiPIdleMemory/README.md). No generated evidence
files are committed while the run remains queued.
