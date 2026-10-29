# PiP idle output memory

This study measures the lifetime of video-sized output storage in the native
subtitle Picture in Picture compositor. The player keeps the compositor alive
between PiP sessions. Before this change, stopping PiP left its output pixel
buffer pool, pool observer, Core Video texture cache, and HDR working texture
available indefinitely for reuse.

The change releases output storage after a stopped production worker has
drained. It preserves the latest decoded video frame, subtitle pipeline,
prepared caption, subtitle upload cache, device, and shader pipelines. A
delayed stop callback checks the active state before flushing the presenter.
The dedicated queue also drains an autorelease pool after every work item,
including GPU completion processing.

## Completed qualification: negative result (2026-10-29)

[Native run 40639953619](https://github.com/Jagalite/illiquid/actions/runs/40639953619) completed green for tested source commit `47b51e515b11da06fc454c1209bbd189dddd7a40`. Baseline selected regressions passed (44 tests), the intended ownership negative control executed and failed, and the candidate passed 49 selected tests including the five new lifetime functions (PQ/HLG parameterization covered). Full logical pixels and color tags matched across all eight cases and twelve measurement processes.

**Do not open an optimization PR:** clearing the candidate's pool/observer/HDR texture owners did not establish a lower settled Metal device allocation. After eight real production cycles, candidate final device allocation exceeded baseline in all six paired processes: +23.7 to +39.6 MiB at 1080p SDR and +7.9 to +102.9 MiB at 4K HDR PQ. Median paired production first-sample re-entry slowdown was +323.6% and +762.7%, respectively. All eight direct-composition recreation cases were slower. The device counter is not RSS or a whole-player RAM measurement.

See the [full result and pair tables](../../Documentation/PIP_IDLE_OUTPUT_MEMORY.md#results--actual-completed-qualification), the [21 exact emitted evidence files](evidence/run-40639953619/), and the [52-file run artifact](https://github.com/Jagalite/illiquid/actions/runs/40639953619/artifacts/12867161212) with additional logs and staged sources. No `main` or other experiment branch was changed.

## Reproduce

Use macOS 26 with the project's Xcode toolchain, Metal device, and pinned native
SDK. The normal package dependency setup applies.

```sh
python3 Benchmarks/PiPIdleMemory/run.py \
  --output /tmp/illiquid-pip-idle-memory --pairs 6 --iterations 6
```

The output directory must be new or empty. This automated runner targets an
isolated macOS host without the shared Kyoto installation. It refuses to build
if that installation is present. On the hosted runner, it reports Kyoto's
absence and builds serially in separate worktrees.

For work on a shared local host, coordinate build commands through Kyoto and
inspect their job status and logs as required by [AGENTS.md](../../AGENTS.md).
The workflow below is the supported automated reproduction route for this
study; the standalone runner does not implement Kyoto job orchestration.

The [workflow](../../.github/workflows/pip-idle-memory.yml) performs the same
experiment using the repository's hash-verified native dependencies. Its PR
checkout is the proposed head commit so the frozen research comparison is not
silently changed by GitHub's synthetic merge commit. Other native PR checks
remain responsible for integration with the current base.

## Production lifetime

`stop()` invalidates the composition fence and stops admission of pending
frames. Its work-queue callback flushes the old presenter only if the
compositor has not restarted. If no production worker remains, it releases the
pool observer, HDR texture, unused Core Video texture wrappers, and unused pool
buffers, then clears the pool and its bookkeeping.

A GPU operation already submitted retains its resources and completes normally.
The stale output cannot be presented because the existing composition fence
rejects it. When the stopped worker drains, retirement is queued after the
completion-processing work item returns. This lets its result references leave
scope before the caches are flushed. The retirement helper rechecks that PiP is
still stopped and idle; an intervening restart keeps its current resources.

Metal command buffers and encoders are autoreleased temporary objects.
A later queue item alone is not an autorelease-pool boundary. The queue uses
`.workItem` so temporary Objective-C ownership ends after each asynchronous
operation, while explicit command-buffer and frame-resource ownership continues
to protect submitted GPU work.

Externally held output pixel buffers remain valid after compositor ownership
ends. Re-entry creates a new pool with the existing twelve-buffer allocation
threshold and can reuse unchanged subtitle uploads.

## Correctness qualification

The native regression suite exercises these boundaries using real Core Video
and Metal resources:

| Case | Observation |
| --- | --- |
| Bitmap caption, stop, recreation | Complete logical output pixels remain identical; texture and vertex uploads are reused. |
| HDR PQ and HLG | HDR working texture ownership ends; recreated output pixels and color tags match. |
| Twelve externally retained outputs | Old output pixels remain valid; a newly created pool admits twelve new outputs and rejects its thirteenth. |
| Stop and restart while work queue is gated | The restarted session keeps its resources and receives its first sample; gate timeout is checked. |
| GPU command held by a shared event | Stop preserves resources until completion, rejects the old sample, retires storage after drain, and re-enters using the cached frame. |

The production `receive`/`start` path is used for the GPU and scheduling
lifetime tests. Sequential pixel checks use the existing direct-composition
test seam and await GPU completion before the next call. These tests do not
automate AVKit's visible PiP window.

The existing PiP pipeline, upload-reuse, composition policy, video mapping, and
transition suites also run. A baseline negative control executes the new
idle-retirement test against the old production code and must fail the intended
ownership assertion. Compilation failure or an empty test selection does not
satisfy that control.

## Baseline integrity

The baseline is commit
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`, with compositor blob
`6ec0cd6317cbecbe40d92ed894fec86a4134438c`. The runner verifies that blob
before staging any instrumentation.

Both variants compile the full native test graph. The baseline receives only
queue-synchronized observation APIs and a nil-by-default GPU test hook. The
runner reverses every instrumentation substitution and requires exact recovery
of the original source. It rejects unrelated production-source differences.
The candidate is the committed production file without algorithm extraction or
a substitute implementation.

## Measurement

Eight cases cover 1920 × 1080 and 3840 × 2160 output, SDR BGRA and HDR PQ P010,
and one or twelve simultaneously retained output buffers. Each case first
composes real frames, fingerprints all logical pixel bytes and color tags, and
records resource ownership. The test then drops its strong output references,
stops the compositor, waits for its idle state, and observes the remaining
resources.

Measurements record the HDR texture's Metal-reported `allocatedSize`, pool and
observer ownership, weak resource lifetimes, and the payload size of observed
live output buffers. Weak-buffer probes are calibrated while the buffer array
is explicitly kept alive. Buffer payloads exclude allocator and driver
overhead. A released API object does not prove immediate operating-system
reclamation of all backing pages.

Restart samples time `start()` followed by the direct composition test seam
through completion of a real GPU command. Shader initialization, source
preparation, and output hashing are outside that interval. Normal production
worker scheduling, presenter enqueue, visible PiP startup, decoding, energy,
and whole-player performance are outside this component measurement.

Six fresh-process pairs alternate baseline/candidate order. Each process
records six restart samples per case. Per-process medians and paired changes
are retained; positive changes mean slower. Every process compares recreated
pixels with its reference, and the runner compares full pixel hashes and color
tags across variants and processes.

### Repeated production sessions

A prior unmerged [PiP resource study](https://github.com/Jagalite/illiquid/blob/428c511b324b1e5388f64f5470aafa06107cec16/Documentation/PIP_IDLE_RESOURCE_MEMORY.md)
observed growing Metal allocation counters despite cleared compositor fields.
That result motivates an additional lifetime check here; it is not used as a
measurement of this candidate. Its [later follow-up](https://github.com/Jagalite/illiquid/actions/runs/40014008137/job/120621291116)
found that the growth settled and that retirement-only and `.workItem`
variants reached the same allocation plateau. The queue setting gives this
candidate an explicit temporary-object lifetime boundary; this two-arm study
does not claim an independently measured benefit from that setting.

Before any companion readbacks, every measurement process performs eight real
`receive`/`start`/first-sample/`stop` cycles for 1080p BGRA and 4K HDR PQ.
No output buffers or output probes are retained. The stopped compositor and
its cached decoded input remain alive throughout the observations.

The harness records `MTLDevice.currentAllocatedSize` after each first sample,
after requesting stop, after the stopped-state queue barrier, and after a
requested 150 ms settling interval. It also observes a final one-second
settle. Both variants in the first pair receive an additional five-second
settle. Requested and actual elapsed intervals are recorded.

These device counters are separate from the owned HDR texture and buffer
payload observations. They may include framework caches and other resources;
they are not process RSS and must not be added to the resource byte counts.
Inspect nonzero populated values, successive stopped-state deltas, and the
cycle-one-to-eight trend before accepting a memory improvement. An automatic
numeric threshold is deliberately avoided on a shared runner.

Production re-entry timing ends inside the real first-sample callback, after
GPU composition and presenter enqueue. The initial cold start is separate from
the following seven re-entries. This still does not measure an AVKit window
becoming visible.

## Evidence

The output includes the source and binary hashes, compiler/Xcode/host/Metal
device identity, complete command journal, executed-test receipts, raw process
observations, pixel/tag parity, and summary. Logs emit exact UTF-8 evidence text
and SHA-256 digests prefixed with `PIP_IDLE_EVIDENCE_JSON`; the workflow also
uploads the evidence and staged source files as an artifact.

The [research report](../../Documentation/PIP_IDLE_OUTPUT_MEMORY.md) records the
actual negative qualification result, observed ownership, restart cost, and
hosted Metal limitations. The exact emitted evidence has been retained under
`evidence/run-40639953619/`. No process RSS or total-player memory reduction
can be inferred from these resource measurements.

## Framework contracts

- [Metal command-buffer retention](https://developer.apple.com/documentation/metal/mtlcommandqueue/makecommandbuffer%28%29)
- [Core Video texture-cache flushing](https://developer.apple.com/documentation/corevideo/cvmetaltexturecacheflush%28_%3A_%3A%29)
- [Core Video pool flushing](https://developer.apple.com/documentation/corevideo/cvpixelbufferpoolflush%28_%3A_%3A%29)
- [Metal resource allocation size](https://developer.apple.com/documentation/metal/mtlresource/allocatedsize)

The dedicated queue's [work-item autorelease behavior](https://developer.apple.com/documentation/dispatch/dispatchqueue/autoreleasefrequency/workitem)
provides a release boundary for [Metal transient objects](https://developer.apple.com/library/archive/documentation/Miscellaneous/Conceptual/MetalProgrammingGuide/Cmd-Submiss/Cmd-Submiss.html).
[Metal device allocation counters](https://developer.apple.com/documentation/metal/mtldevice/currentallocatedsize)
remain distinct from process-memory measurements.
