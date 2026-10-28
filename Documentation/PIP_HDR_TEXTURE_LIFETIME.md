# HDR Picture in Picture working-texture lifetime

## Finding

The native runtime retains its `PiPSubtitleCompositor` between Picture in Picture
sessions so paused playback can reenter PiP using the latest decoded frame.
HDR composition additionally owns one reusable private Metal RGBA16Float texture
in `hdrLinearTexture`. The old `stop()` invalidated presentation authority and
flushed the renderer but left this texture alive until a later SDR composition,
size change, or compositor destruction.

A UHD frame needs 3840 × 2160 × 8 = 66,355,200 bytes (63.28125 MiB) of logical
RGBA16Float pixel storage. The production allocation guard limits this working
texture to 64 MiB of logical storage. Native `MTLTexture.allocatedSize` is measured
separately because allocation alignment can differ from logical payload size.

This is retained reusable storage after PiP stops, rather than unbounded growth
or an orphaned allocation. The optimization makes that large allocation follow
the active session's lifetime.

## Change and ownership

`retireHDRTextureIfStoppedAndIdle()` runs only on the compositor's serial work
queue. It clears the texture only when both `active` and `workerActive` are false.

Three sites cover the relevant transitions:

- Queued stop cleanup handles an already idle compositor.
- The no-work path in `consumePendingFrame()` handles the last successful,
  failed, or stale completion returning to a stopped compositor.
- Output-pool backpressure handles the separate path that clears `workerActive`
  without scheduling another consume.

The existing worker remains active from submission until completion returns to
the owner queue. Stop therefore cannot retire its intermediate prematurely.
A newer start keeps the texture reusable. If start races just after an idle
check, its actual composition is still serialized behind cleanup and can create
a new texture before encoding. The latest decoded frame remains available for
paused reentry.

The allocation tradeoff is intentional: a fully stopped HDR PiP session releases
its working texture, and a later HDR PiP session allocates it again. Active
same-size composition continues reusing one texture.

## Native experiment

The reproducible driver is
[Benchmarks/PiPHDRTextureLifetime/run.py](../Benchmarks/PiPHDRTextureLifetime/run.py).

It reads the original compositor from pinned commit
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`, then adds exactly the same observation
hooks used by the candidate. The hook manifest is retained and every source
anchor must match once. The driver verifies that baseline and candidate differ
only by the retirement helper and its three calls. It saves both source
snapshots and both diffs.

Both variants compile the current full production package in release mode with
the same resolved dependencies, native SDK, tests, and compiler. Separate scratch
directories prevent stale build reuse. Builds are serial.

The workload matrix covers small PQ, 1080p PQ, UHD PQ, and UHD HLG. Each workload
runs three baseline/candidate pairs in fresh test processes, alternating order.
This is a repeated ownership experiment; it does not measure throughput.

Every observation checks:

- Native allocation size and a weak reference to the real Metal texture.
- Continued texture identity reuse while PiP is active.
- Ownership and object lifetime after stop, with the compositor still alive.
- Retained P010 output checksums and color attachments before and after stop.
- Paused reentry without receiving another decoded frame.
- Full visible-plane checksum equality after reentry and after final stop.

The driver requires the baseline to retain its texture after stop and the
candidate to relinquish it. It separately requires the original candidate
texture object to disappear, so clearing a diagnostic counter is insufficient.
Returned pixel buffers remain alive while those checks run.

## Regression coverage

The focused lifetime suite covers PQ and HLG idle stop, active reuse, paused
same-frame reentry, a held completion followed by stop, restart before the old
completion returns, output-pool exhaustion, and an SDR control.

The completion gate holds delivery on Metal's external callback thread after
GPU completion. This leaves the compositor queue available for stop cleanup and
proves that cleanup respects an outstanding logical completion. It does not
freeze physical GPU execution. The gate is one-shot, bounded, and released during
test cleanup.

The qualification also runs the existing PiP subtitle pipeline, upload reuse,
video mapping, composition policy, and Metal subtitle packer suites. These cover
HDR precision, subtitle pixels, color tags, backpressure, and subtitle consumer
behavior beyond the new lifetime assertions.

## Evidence boundaries

Native allocation and weak lifetime observations establish the retirement of
this particular working texture. They do not imply an equal reduction in process
RSS or physical footprint: Metal may retain reusable allocator backing.
The experiment does not measure frame rate, energy use, or a live user-controlled
AVKit PiP window. The existing cached subtitle resources and output pool are
independent owners.

Apple documents [MTLResource.allocatedSize](https://developer.apple.com/documentation/metal/mtlresource/allocatedsize)
as the resource's size in bytes. The player uses ordinary
[makeCommandBuffer()](https://developer.apple.com/documentation/metal/mtlcommandqueue/makecommandbuffer%28%29),
whose command buffers retain referenced resources. The fix additionally preserves
the compositor's own ownership until its existing completion protocol is idle.

## Qualification results

Native qualification is pending. Recorded measurements and the exact CI receipt
will be added after the run completes.
