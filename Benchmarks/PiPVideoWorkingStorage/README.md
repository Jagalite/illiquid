# PiP video working storage retirement

This experiment measures the real PiP subtitle compositor before and after
stopping composition. It uses a native Metal device, CoreVideo pixel buffers,
the production shaders, and the full application/test graph. It does not launch
the player window, request system PiP, decode media, or measure visible playback.

## Comparison

The candidate releases its output pixel-buffer pool, pool observer, output-buffer
identity bookkeeping, and HDR intermediate after a stopped work-queue boundary.
It flushes the CoreVideo Metal texture cache. The latest decoded frame and
prepared subtitle/upload resources remain available for paused reentry.

The comparison is a **matched parent-behavior control**, not the complete
historical application. Both variants contain the candidate's identical testing
instrumentation and all other current source. The control removes exactly one
call to retireVideoWorkingStorageIfInactive() from stop(). The runner requires
the resulting entire stop() declaration to match parent commit
ea2ff568237e2667f7b1aeee67b11a44ebe95b72 byte for byte. Only this one source file
may differ between the two compiled production trees.

This isolates the retirement call while allowing the same scalar resource
snapshots to observe both variants. Source hashes, the original parent stop body,
the controlled source, and the candidate source are retained with the evidence.

## Run

Use macOS 26, full Xcode, and the repository's pinned native SDK. Check out the
full Git history, commit the candidate, and follow AGENTS.md build coordination.
When Kyoto is available, submit the complete command through its shared queue;
when it is unavailable, explain that limitation before a direct build. The runner
always serializes its two builds and all test processes.

    python3 Benchmarks/PiPVideoWorkingStorage/run.py \
      --pairs 6 --output /tmp/illiquid-pip-video-storage

The output directory must not exist. The production app/test graph is built once
per variant in separate scratch paths, using release configuration and two
compiler jobs. Every subsequent process uses swift test --skip-build.
An optional --regression-filter 'SuiteName|AnotherSuite' runs candidate
regression suites using that same compiled graph. The runner checks that the
requested tests actually execute and pass.

The measurement suite is opt-in:

- ILLIQUID_PIP_STORAGE_MEASURE=1
- ILLIQUID_PIP_STORAGE_MODE=sdr-1080p or pq-4k
- ILLIQUID_PIP_STORAGE_PASS=<unique observation identity>

No native GPU, shader failure, missing test, or absent measurement causes a
silent skip. The normal test run leaves this measurement suite disabled.

## Workload and ownership boundaries

Each observation runs in a fresh native test process and uses one source frame
plus a small opaque-white bitmap subtitle:

| Mode | Source/output | HDR intermediate |
| --- | --- | --- |
| sdr-1080p | 1920 by 1080 BGRA | None |
| pq-4k | 3840 by 2160 video-range P010, PQ, BT.2020 | Actual RGBA16Float texture |

The source is allocated, initialized, and supplied to receive() before the
first memory sample. The compositor starts through the production lifecycle and
must report its first enqueued sample successfully.

After that completion and a queue barrier, four additional outputs are composed
serially through the existing direct-composition test seam. Every GPU completion
is awaited. Holding these four outputs temporarily exercises distinct real pool
buffers without exceeding the twelve-buffer allocation threshold. This is a
controlled pool-population workload; it does not assert that ordinary playback
retains that many buffers.

The temporary output array is released inside an autorelease pool, and its
non-inlined async helper returns only scalar/checksum information. No output
pixel buffer is carried into the retained-storage samples. A 100 ms settling
interval precedes the populated-active sample.

stop() is followed by the snapshot helper's work-queue barrier. Samples are
recorded at that boundary and after another 100 ms and 200 ms, giving nominal
0/100/300 ms idle points. Actual monotonic elapsed times are retained. The
compositor, source frame, subtitle pipeline, and prepared caption stay alive.

Reentry uses the exact cached frame without another receive() call. The
first-sample callback records elapsed time independently of the polling interval.
Complete composed pixel rows are hashed before stop and after reentry, excluding
uninitialized row padding. Dimensions, pixel format, caption brightness, and
checksums must match. Subtitle uploads must remain reusable. A second stop checks
that the retirement behavior persists across another lifecycle cycle.

These checks establish native component output and callback behavior. There is
no claim of displayed HDR precision, AVKit window behavior, input-to-photon
latency, or end-to-end player responsiveness.

## Measurements and interpretation

Resource snapshots contain only values and do not retain the objects they
observe:

- Presence of the output pool, its observer, and the HDR intermediate.
- The HDR texture's actual allocated byte count.
- Output-buffer identity count.
- Prepared-caption presence and cached-frame timestamp.

These are the primary ownership observations. A stopped candidate must have no
video pool/observer/HDR texture/identity storage, while the matched control must
retain its populated video working storage. Both must retain the caption and
cached frame.

Supporting process counters are Darwin task_vm_info.phys_footprint and Metal
MTLDevice.currentAllocatedSize. They include resources beyond these specific
objects and have different accounting scopes; do not add them together.
The summary reports absolute active/idle values, within-process active-to-idle
changes, idle values relative to the pre-start sample, and paired differences.
Allocator, renderer, driver, and asynchronous cleanup effects can affect those
counters even after the ownership change is visible.

The source buffer and subtitle resources deliberately remain alive. In-flight
GPU ownership is not forcibly broken: ordinary Metal command buffers retain
encoded resources, and the compositor explicitly retains the associated
CoreVideo texture wrappers until GPU completion. See Apple's
[command-buffer lifetime documentation](https://developer.apple.com/documentation/metal/mtlcommandqueue/makecommandbuffer()),
[CoreVideo texture ownership requirement](https://developer.apple.com/documentation/corevideo/cvmetaltexturecachecreatetexturefromimage(_:_:_:_:_:_:_:_:_:)),
and [texture-cache flush API](https://developer.apple.com/documentation/corevideo/cvmetaltexturecacheflush(_:_:)).

## Evidence

The default study contains six alternating control/candidate pairs per mode:
24 measured fresh processes. Two separate SDR build-probe processes qualify the
compiled binaries and are excluded from the summary. No observations are removed
based on performance. An even --pairs value from 2 to 12 is supported; two pairs
are useful for a mechanics smoke check, not a substitute for the default study.

The evidence directory contains environment/source/binary receipts, every command
and full test log, excluded build probes, raw observations.jsonl, summary.json,
and a terminal completion.json. Raw observations and the summary are also
printed into the CI job log. A successful completion requires matched native
pixels, expected stopped resource states, balanced order, and unchanged measured
source and binary hashes.

Keep the build/ directory out of evidence uploads: it contains reproducible
worktrees and build products. Retain the text receipts, logs, source snapshots,
and raw measurements.

There are no performance pass/fail thresholds and no claimed results until a
native run has completed. Report measured medians and ranges, including any
reentry cost, as component research. Process-counter differences here are not
evidence of a specific reduction in total player RAM during typical use.
