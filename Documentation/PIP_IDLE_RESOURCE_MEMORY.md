# Retiring the Picture in Picture working set

## Scope and baseline

This investigation addresses memory retained after closing subtitle-composited
Picture in Picture (PiP). The baseline is
`af1c1add701e49b355448cf8983eaed1e7623108`, after integration PR #85. There were
no open PRs when this area was selected on October 23, 2026.

`NativePlaybackRuntime` creates `PiPSubtitleCompositor` once and reuses it across
PiP sessions. Ending a session calls `stop()` while retaining the compositor.
The baseline stop path invalidates pending work and flushes the display layer,
but retains its output pixel-buffer pool, HDR intermediate texture, prepared
subtitle pixels, subtitle upload resources, and reusable CPU staging buffers.
Consequently, closing PiP does not retire those optional allocations.

The existing HDR intermediate limit is 64 MiB and the output pool has a
12-buffer allocation threshold. These are limits, not measured retained memory.
This study measures actual resource capacities and reports pool ownership
separately.

## Change

Inactive PiP now retires its working resources on the compositor's existing
serial work queue:

- Flush the presenter and remove the old output-pool notification observer.
- Release the pool, its cached dimensions/format, and its diagnostic identities.
- Release the HDR working texture and subtitle texture/vertex buffer.
- Clear the prepared caption and its source revision.
- Retire the subtitle packer's backing storage and release its budget reservation.
- Flush unused Core Video texture-cache resources.

The follow-up candidate also gives the work queue a per-item autorelease pool.
Apple documents [`.workItem`](https://developer.apple.com/documentation/dispatch/dispatchqueue/autoreleasefrequency/workitem)
as draining that pool after each block, and documents command buffers and
encoders as autoreleased temporary objects in its
[Metal programming guide](https://developer.apple.com/library/archive/documentation/Miscellaneous/Conceptual/MetalProgrammingGuide/Cmd-Submiss/Cmd-Submiss.html).
Explicit command-buffer and `MetalFrameResources` ownership still protects
resources through GPU completion. This queue change is being qualified against
the initial retirement-only candidate as a separate control.

The latest decoded input frame, bound subtitle pipeline, source geometry, and
compiled Metal pipelines remain available for paused re-entry. The first
composition of a new session rebuilds its optional working resources; subsequent
unchanged captions still reuse uploads within that session. Re-entry can therefore
cost additional allocation and preparation time. This change targets idle memory,
not rendering throughput.

## Ownership and concurrency

A delayed stop action checks whether PiP is still inactive on the work queue.
If a new session has already started, that obsolete action cannot flush its
display or discard its resources. A restart after the check schedules its draw
behind retirement on the same queue.

`stop()` does not reset the worker gate. An outstanding GPU completion still
owns the transition back to an idle worker and the opportunity to consume a
restarted session's pending frame. The existing composition fence continues to
reject output and failures from the stopped session.

The compositor creates ordinary
[`MTLCommandQueue.makeCommandBuffer()`](https://developer.apple.com/documentation/metal/mtlcommandqueue/makecommandbuffer%28%29)
command buffers, which retain their encoded resources through execution, as
described in Apple's [Metal programming guide](https://developer.apple.com/library/archive/documentation/Miscellaneous/Conceptual/MetalProgrammingGuide/Cmd-Submiss/Cmd-Submiss.html).
Its existing `MetalFrameResources` separately retains the Core Video texture
wrappers and output buffer until the completed-handler path returns. Apple
requires that explicit wrapper lifetime for
[`CVMetalTextureCacheCreateTextureFromImage`](https://developer.apple.com/documentation/corevideo/cvmetaltexturecachecreatetexturefromimage%28_%3A_%3A_%3A_%3A_%3A_%3A_%3A_%3A_%3A%29).
Releasing compositor references therefore does not require blocking for the GPU.

After a stopped worker drains, idle retirement runs again. This permits
[`CVMetalTextureCacheFlush`](https://developer.apple.com/documentation/corevideo/cvmetaltexturecacheflush%28_%3A_%3A%29)
to discard entries whose wrappers were still in use during the first stop flush.
Already queued pool notifications still obey the existing active/worker/pending
gates and cannot create parallel or inactive composition work.

## Native measurement

The reproduction harness lives in `Benchmarks/PiPIdleResources`. It compiles and
executes the complete native compositor, including Core Video, the production
Metal shaders, subtitle packing, and GPU completion. Both variants use the same
supporting code, fixtures, and read-only ownership probe. The baseline compositor
is extracted from the pinned Git revision and receives only that identical probe;
its stop behavior is not replaced with a model.

The workloads include a 1920×1080 SDR source and a 3840×2160 P010 HDR source with
a fixed bitmap caption. The compositor stays alive while the harness observes
resources after composition, after stop/drain, and after re-entry. A deterministic
checksum of active pixel bytes excludes Core Video row padding and verifies that
recreated output matches the original output and the other variant.

Measurement categories are deliberately separate:

| Observation | Meaning |
| --- | --- |
| HDR and subtitle Metal `allocatedSize` | Capacity of actual resources still owned by the compositor/cache |
| Packer storage bytes | Backing `Data.count` across reusable staging slots |
| Prepared pixel bytes | Prepared caption payload; may share packer storage |
| PiP staging budget | Independent production reservation accounting |
| Pool/observer presence | Whether the compositor still owns its pool and notification registration |
| Device allocated bytes | Supplemental process/device diagnostic, including framework resources |

Prepared pixel bytes must not be added to staging bytes. Pool identity history
does not measure live occupancy, so this report does not multiply observed output
identities by frame size. Device allocation may overlap other reported resources
and does not measure process RSS or physical footprint.

## Initial native result and follow-up

[Native run 40009592397](https://github.com/Jagalite/illiquid/actions/runs/40009592397)
qualified the initial retirement-only implementation at
`d79da1b6e9b0fd2a6598b378f4ec0353e063fbcd`: all 12 measurement processes and
66 focused tests in six suites passed, including seven new retirement tests,
without skips. It ran on an Apple M1 virtual arm64 runner with macOS 26.6.2,
Xcode 26.6, and Swift 6.3.3. The evidence is retained under
[`preliminary-macos-arm64-20261023`](../Benchmarks/PiPIdleResources/evidence/preliminary-macos-arm64-20261023/).

The directly owned resources became zero after each stop. The baseline retained
4,194,304 bytes of subtitle texture, 16,384 bytes of vertices, and 4,194,304 bytes
of CPU staging in both workloads; HDR additionally retained 66,355,200 bytes of
working texture. Pool and observer ownership also ended in the candidate.
Output checksums and color tags matched across all variants/repetitions and
after reentry.

However, the broader device counter exposed a concern that ownership probes
alone missed. Every second candidate session added 16,588,928 device bytes in
SDR or 99,567,616 bytes in HDR, still present at the second stopped snapshot.
The increments match the newly allocated output buffers' Metal views. The
initial trace had no second-stop settling measurement, so this does not yet
establish the retaining owner or unbounded growth. It prevents treating that
first result as a demonstrated net memory improvement across repeated sessions.

The initial reentry first-sample callback median also rose from 2.758 to
20.954 ms for SDR and from 5.151 to 74.218 ms for HDR. These are descriptive
measurements from three fresh processes per variant/workload, with baseline
measured first; they are not end-to-end AVKit window timings.

The follow-up compares three arms in the same native run: original baseline,
the historical retirement-only candidate, and retirement with per-work-item
autorelease pools. It preserves the original readback checks and adds eight
production-only start/stop cycles without companion readbacks, with immediate,
150 ms, 1 second, and final 5 second idle observations. Native qualification of
this follow-up is pending. Device allocations remain diagnostic rather than an
RSS estimate, but sustained cycle growth is a reason to reject or revise a
memory-management change.

The focused native suite covers resource retirement while keeping the compositor
alive, same-frame subtitle reconstruction, HDR storage, retained output lifetime,
idempotent stop, and rapid stop/re-entry. The workflow also runs the existing PiP
pipeline, upload-reuse, mapping, eligibility, and subtitle-compositor regressions.
Broader repository PR checks remain a separate integration gate.
