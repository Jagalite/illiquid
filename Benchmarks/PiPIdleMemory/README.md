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

## Reproduce

Use macOS 26 with the project's Xcode toolchain, Metal device, and pinned native
SDK. The normal package dependency setup applies.

```sh
python3 Benchmarks/PiPIdleMemory/run.py \
  --output /tmp/illiquid-pip-idle-memory --pairs 6 --iterations 6
```

The output directory must be new or empty. Run builds through the shared Kyoto
queue when it is available, as required by [AGENTS.md](../../AGENTS.md).
The harness refuses direct compilation if that queue is present. On the
isolated hosted runner, it reports the queue's absence and builds serially in
separate worktrees.

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

## Evidence

The output includes the source and binary hashes, compiler/Xcode/host/Metal
device identity, complete command journal, executed-test receipts, raw process
observations, pixel/tag parity, and summary. Logs emit exact UTF-8 evidence text
and SHA-256 digests prefixed with `PIP_IDLE_EVIDENCE_JSON`; the workflow also
uploads the evidence and staged source files as an artifact.

The final research report records the accepted run, observed memory ownership,
restart tradeoff, and any limits of the hosted Metal environment. No process
RSS or total-player-memory reduction should be inferred from the resource
measurements alone.

## Framework contracts

- [Metal command-buffer retention](https://developer.apple.com/documentation/metal/mtlcommandqueue/makecommandbuffer%28%29)
- [Core Video texture-cache flushing](https://developer.apple.com/documentation/corevideo/cvmetaltexturecacheflush%28_%3A_%3A%29)
- [Core Video pool flushing](https://developer.apple.com/documentation/corevideo/cvpixelbufferpoolflush%28_%3A_%3A%29)
- [Metal resource allocation size](https://developer.apple.com/documentation/metal/mtlresource/allocatedsize)
