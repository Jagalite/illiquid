# PiP idle resource retirement

This research measures the actual native `PiPSubtitleCompositor` while its owner
remains alive after PiP stops. It compares the pinned baseline
`af1c1add701e49b355448cf8983eaed1e7623108` with the working candidate.

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

## What is measured

Snapshots run on the compositor's serial work queue. The report records native
Metal `allocatedSize` for the HDR intermediate and caption upload resources,
actual packer backing `Data.count` values, prepared pixel payload, pool/observer
ownership, and the independent production staging-budget reservation. Baseline
must reproduce retained resources after stop; candidate must retire them to zero
while the compositor stays alive, then reconstruct them on reentry.

These fields are **not additive**. Prepared pixels can share backing storage with
the packer. Device allocation can include CoreVideo/IOSurface storage and driver
caches. `device.currentAllocatedSize`, sampled again after 150 ms, is a secondary
diagnostic; it is not an assertion or whole-player RSS/physical-footprint result.
The pool flag demonstrates retired ownership, not an assumed byte total for free
CoreVideo buffers. The cached decoded input frame and shader pipelines remain
alive in both variants.

First-sample latency records the actual callback timestamp before and after
reentry. The baseline-then-candidate order and small sample count make these
**descriptive reentry-cost observations**, not a rendering-speed claim. The main
acceptance criterion is deterministic idle ownership reduction plus exact output
parity and native lifecycle regressions.

Artifacts include source/instrumentation hashes, native toolchain identity,
command logs, each process's measurements, output digests, summary, and a source
restoration receipt. The workflow prepares the existing checksum-verified native
SDK, runs this comparison, then runs the regular PiP/subtitle suites on restored
candidate sources.
