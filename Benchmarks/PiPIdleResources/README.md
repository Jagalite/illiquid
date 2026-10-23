# PiP idle resource retirement

This research measures the actual native `PiPSubtitleCompositor` while its owner
remains alive after PiP stops. It compares the pinned baseline
`af1c1add701e49b355448cf8983eaed1e7623108` with the working candidate.
An optional historical retirement-only control can distinguish releasing owned
references from draining temporary autoreleased native objects.

## Reproduce

On macOS 26 with the repository's pinned Xcode/native SDK environment:

```bash
python3 Benchmarks/PiPIdleResources/run.py \
  --output /tmp/illiquid-pip-idle-results --repetitions 3
swift test --force-resolved-versions -c release --jobs 2 --no-parallel \
  -Xswiftc -enable-testing \
  --scratch-path .build/pip-idle-resources \
  --filter 'PiPIdleResourceRetirementTests|PiPSubtitleUploadReuseTests|PiPSubtitlePipelineTests|PiPVideoMappingTests|PiPSubtitleCompositionPolicyTests|MetalASSSubtitleCompositorTests'
```

Use an isolated checkout and an empty output directory. The runner temporarily
stages the measurement test, hides the candidate-only retirement regression file,
and replaces the compositor with baseline behavior plus the **same read-only
snapshot declarations**. It restores the exact candidate source/tests in a
`finally` block. Do not edit or build this checkout concurrently. No application
state, media files, release artifacts, or signing configuration are modified.

Each variant builds the full SwiftPM native graph. Three fresh test processes per
workload exercise 1080p BGRA SDR and 4K P010 PQ HDR with a generated 1024×256 bitmap
caption. The actual production `receive`/`start` path submits the first sample.
After its worker drains, a serial companion composition returns pixels for
readback. The source remains cached across `stop` and `start`; reentry receives no
new frame. All active output bytes and color tags must match across restart,
baseline, candidate, and repetitions. Padding bytes are excluded from the fixed
FNV-1a checksum.

After these two sessions, the same live compositor runs **eight additional
production-only start/stop cycles without companion readbacks**. Each cycle
records first-sample callback latency and the populated active resources, checks
that one frame is composed and immediately displayed with a caption, and samples
the stopped state after worker drainage, 150 ms, and one second. The second
original stop also has a 150 ms sample. After the last production-only cycle,
four more seconds of idle time produce a final sample at approximately five
seconds after drainage. Queue/observation overhead can make these intervals
slightly longer. The compositor, subtitle pipeline, and cached source stay alive
throughout; destruction cannot hide continuing retention.

## What is measured

Snapshots run on the compositor's serial work queue. The report records native
Metal `allocatedSize` for the HDR intermediate and caption upload resources,
actual packer backing `Data.count` values, prepared pixel payload, pool/observer
ownership, and the independent production staging-budget reservation. Baseline
must reproduce retained resources after stop; candidate must retire them to zero
while the compositor stays alive, then reconstruct them on reentry.

These fields are **not additive**. Prepared pixels can share backing storage with
the packer. Device allocation can include CoreVideo/IOSurface storage and driver
caches. `device.currentAllocatedSize` is preserved for every active, stopped, and
settled sample so repeated-cycle growth or stabilization can be evaluated from
the actual trajectory. No arbitrary device-allocation threshold is asserted, and
this is not a whole-player RSS/physical-footprint measurement. Owned-resource
and staging-budget assertions still apply after every stop and settling period.
The pool flag demonstrates retired ownership, not an assumed byte total for free
CoreVideo buffers. The cached decoded input frame and shader pipelines remain
alive in both variants.

First-sample latency records the actual callback timestamp before and after
reentry. The baseline-then-candidate order and small sample count make these
**descriptive reentry-cost observations**, not a rendering-speed claim. The main
acceptance criterion is deterministic idle ownership reduction plus exact output
parity and native lifecycle regressions. Pixel checksum parity covers the first
two sessions; the eight later production-only cycles check submitted-frame and
caption metrics without adding readback allocations.

Artifacts include source/instrumentation hashes, native toolchain identity,
command logs, each process's complete per-cycle measurements, output digests,
summary, completion counts, and a source
restoration receipt. The workflow prepares the existing checksum-verified native
SDK, runs this comparison, then runs the regular PiP/subtitle suites on restored
candidate sources.

## Optional historical control

Pass `--retirement-only-control <commit>` to include a third arm between baseline
and candidate. The runner loads that commit's complete compositor and requires
its snapshot declarations and upload-cache source to match the common candidate
instrumentation exactly. The full native graph uses the same remaining support
sources. Its original source and SHA are preserved in the evidence receipt.

The `retirement-only` arm has the same zero-owned-resource assertions as the
candidate. All variants share the same first-two-session pixel checks and eight
production-only cycles, and output parity includes every arm. Three repetitions
of each workload produce 18 fresh processes with the control or 12 without it.
Each process allows 120 seconds; the fixed settling periods total approximately
12.3 seconds, leaving ample room for native initialization and composition.
