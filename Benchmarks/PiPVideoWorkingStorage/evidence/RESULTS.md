# Native PiP video working-storage retirement: measured results

**Result: qualified 4K HDR memory reduction, with a measurable paused-reentry cost.** Tested on October 28, 2026, using the real CoreVideo/Metal compositor, release SwiftPM app/test graph and pinned native SDK. 62 relevant native regressions passed; all 24 paired measurement processes passed. The CI job and the complete 14-day evidence artifact are linked below.

## Summary

| Measurement | Parent-behavior control median | Candidate median | Paired candidate minus control median |
| --- | ---: | ---: | ---: |
| **4K PQ idle process physical footprint** | 237.291 MiB | 173.971 MiB | **−63.289 MiB** |
| 4K PQ idle Metal device current allocation | 372.932 MiB | 309.651 MiB | −63.281 MiB |
| 4K PQ retained HDR RGBA16Float working texture | 63.281 MiB | 0 MiB | −63.281 MiB |
| **4K PQ start-to-first-composited-sample on paused reentry** | 5.933 ms | 50.149 ms | **+44.412 ms** |
| 1080p SDR idle process physical footprint | 78.760 MiB | 78.682 MiB | −0.117 MiB (no reproducible within-process drop) |
| 1080p SDR idle Metal device current allocation | 48.508 MiB | 48.508 MiB | 0 MiB |
| 1080p SDR paused reentry first sample | 2.809 ms | 10.579 ms | +7.636 ms |

All 4K PQ candidate processes independently released **66,355,200 bytes (63.281 MiB)** from their active-to-300-ms-idle physical footprint, exactly matching the allocated HDR intermediate's byte count. Control runs retained that texture and had a median 0-MiB within-process drop. A paired six-run comparison of the idle footprint was −63.289 MiB. The live **CVPixelBufferPool**, its observer and observed-buffer identities were also retired by the candidate; those objects were retained by control. This experiment did **not** establish additional process RAM reclaimed from the SDR output pool.

The downside is a cold resource-recreation cost on returning to PiP. The candidate's 4K PQ reentry ranged **45.048–77.618 ms**, versus **5.164–6.458 ms** for the control, and SDR reentry ranged **7.380–17.502 ms**, versus **2.401–3.475 ms**. The per-pair median penalties were +44.412 ms (4K PQ) and +7.636 ms (SDR). The 4K HDR memory saving is real in this component experiment; the restart cost should inform acceptance of the tradeoff.

## Workload and comparison

Six alternating AB/BA control-versus-candidate pairs per mode used one paused synthetic source frame with a small white bitmap subtitle; every measured process ran fresh on a native Apple Silicon Metal device. SDR used 1920×1080 BGRA. HDR used 3840×2160 video-range P010 with PQ/BT.2020 and the production RGBA16Float intermediate. Four additional completed outputs were temporarily held to exercise a populated real output pool, released before ownership and process-memory sampling. Both variants used identical instrumented source and shaders except for **one stop-time retirement invocation**. Removing that call restored the original `stop()` declaration byte-for-byte from `ea2ff568237e2667f7b1aeee67b11a44ebe95b72` (not a full independent historical rebuild).

The candidate's stopped queue snapshot removed the pixel-buffer pool, free-buffer notification observer, HDR working texture and observed-output bookkeeping; both variants retained the cached decoded frame and prepared subtitle resources. In-flight command-buffer/output ownership remained intact. Production reentry, subtitle pixel hashes, pixel formats, dimensions and subtitle upload reuse were checked and matched the control across all 24 observations. All 62 selected regression tests passed in five suites, including SDR/PQ/HLG output, retained old outputs, pool exhaustion, interrupted GPU completion and paused reentry.

## Scope and cautions

The primary observation is deterministic **component ownership**; `task_vm_info.phys_footprint` and `MTLDevice.currentAllocatedSize` are separate whole-process/device counters, **not additive**. Physical memory may vary with allocators and drivers. The 63.281-MiB texture is an allocation, not a universal per-user saving. On SDR the pool lifetime was shortened but the measured process footprint did not drop. The test does **not** launch a visible PiP window or decode real media, and start-to-first-sample latency is **not** AVKit visible-playback or input-to-photon latency. HLG has regression coverage but no six-pair HLG memory benchmark. Verify visible PiP on physical macOS hardware before release.

## Evidence and reproduction

This folder preserves all 24 unfiltered raw native observations (`observations.jsonl`), source-and-host receipts (`receipt.json`) and the complete computed summary (`summary.json`). The [GitHub Actions run](https://github.com/Jagalite/illiquid/actions/runs/40637230442) succeeded and uploaded [full logs, original source snapshots, binary receipts and build probes](https://github.com/Jagalite/illiquid/actions/runs/40637230442/artifacts/12800834575) for 14 days. The in-repository raw observations and receipts survive artifact expiry. Both builds used Xcode 26.6 / Apple Swift 6.3.3 on macOS 26.6.2 arm64, with the repository's pinned native SDK. The CI environment lacked the local Kyoto coordinator, so the native builds and tests were serialized directly (two Swift compile jobs).

See [the experiment design and execution instructions](../README.md). Build probes were excluded from all medians. No observations were dropped based on timing, and no performance pass/fail threshold was imposed. Source and binary hashes were verified unchanged at the end of the measurement.
