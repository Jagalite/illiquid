# Video geometry metadata preparation

## Change and purpose

`VideoDecoder` previously constructed and bridged a dictionary whenever it
applied pixel-aspect-ratio or clean-aperture metadata. The common decoded-frame
path applies both; planar output preparation also applies aspect metadata.
The target is a stretch of playback where successive frames share geometry.

`VideoGeometryMetadataCache` retains one immutable dictionary per metadata
kind, owned by one decoder on its decode worker. An unchanged key reuses the
dictionary; a changed key rebuilds it. The aspect key contains the original
positive, finite dimensions, preserving independent integer rounding of the
emitted spacing values. Aperture keys contain width, height, and the exact
floating-point offset bits, including signed zero.

Every existing call and every `CVBufferSetAttachment` operation remains. The
cache prepares values; it never assumes that a buffer already has them. This
preserves behavior when buffers rotate, planar checkout clears metadata, or
attachments are replaced externally. Invalid aspect ratios retain their no-op
behavior. Cache storage is bounded to two current dictionary references; older
buffers can retain previous attachments independently.

## Exact source comparison

The baseline is commit
`7f9ba073394b77a908e0589447c6edc8d10b832c`. `run.py` reads its complete
`VideoDecoder.swift` with `git show`, extracts the original two complete
methods between checked, unique boundaries, removes only `private`, and places
them in a class with the candidate's interface. Method bodies are unchanged.
The candidate is the complete production
`Sources/IlliquidNativePlayback/Media/VideoGeometryMetadataCache.swift` file.
The runner supports the earlier prototype path but rejects differing
simultaneous prototype and production files.

Both variants are optimized Swift modules with identical names and flags.
The separately compiled driver keeps the call boundary matched between variants;
neither helper declares its methods `@inlinable`. This measures the
original methods and production helper, rather than the complete decoder.
CoreVideo buffers, CoreFoundation dictionaries, and attachment writes are
real. No substitute attachment implementation or FFmpeg build is involved.

Source snapshots accompany `manifest.json`, which records their SHA-256
hashes, compiler/host details, commands, log hashes, and compiled binary hashes.

## Reproduce

Use macOS with the supported Swift toolchain and a checkout containing the
baseline commit. Each output directory must be empty or nonexistent. Run one
timing campaign at a time.

```sh
python3 Benchmarks/VideoGeometryMetadata/run.py \
  --output /tmp/illiquid-video-geometry-tests --tests-only

python3 Benchmarks/VideoGeometryMetadata/run.py \
  --output /tmp/illiquid-video-geometry-timing --pairs 8 --target-ms 150
```

Both commands run semantic tests and output comparisons; the second also
measures performance. The workflow uses `macos-26`, Xcode 26.6, and the pinned
native SDK for its separate app qualification job. Research-branch pushes run
timings; pull requests run component correctness without repeating timings.

## Measurement protocol

The integrated experiment contains twelve workloads:

| Workload | Geometry and buffers |
|---|---|
| `stable-square` | Stable 1920×1080 square pixels, one buffer |
| `stable-anamorphic` | Stable 720×576 with 16:15 pixel aspect |
| `stable-cropped` | Stable 1920×800 aperture in a 1920×1080 buffer |
| `stable-4k` | Stable 3840×2160 square pixels |
| `rotating-square` | Stable 1080p across eight buffers |
| `rotating-anamorphic` | Stable anamorphic geometry across eight buffers |
| `rotating-cleared` | Eight stable 1080p buffers, both attachments removed before each application |
| `alternating-aspect` | Pixel aspect changes every operation |
| `alternating-aperture` | Aperture dimensions and offsets change every operation |
| `alternating-both` | Both metadata kinds change every operation |
| `invalid-aspect` | Zero, negative, NaN, and infinite aspect components |
| `rounding-and-signed-zero` | Aspect rounding boundaries and signed-zero offsets |

Each observation starts a fresh process, allocates buffers, and warms the
helper for 256 operations. One timed operation applies aspect and aperture
metadata. `rotating-cleared` also removes both attachments inside the timed
loop, identically for both variants. That control checks reuse after clearing,
so stable-geometry gains need not depend entirely on CoreVideo repeatedly
seeing the same attached dictionary object.

Calibration measures 2,048 operations per variant and selects a shared count.
It targets 150 ms for the faster variant, subject to an estimated 1.5-second
ceiling for the slower variant and a 5,000,000-iteration cap. These are
calibration targets, not runtime deadlines. Eight pairs alternate AB/BA order,
yielding 192 timed observations and 24 calibration observations. All samples,
including regressions and outliers, remain in the evidence.

Wall time uses monotonic uptime; process CPU time includes user and system
time. Buffer setup, warmup, output serialization, and checksum calculation are
outside timing. Final real attachment contents are consumed afterward, and
paired checksums must match.

Summaries report median time per operation, median paired percentage change,
each paired change, and faster-pair counts. Negative percentages mean less
time. A paired median percentage need not equal the percentage difference
between the separately reported variant medians.

## Correctness qualification

The same thirteen semantic tests run against both variants in debug and
release. They cover rounding, independent geometry changes, invalid input,
rotating buffers, removal/replacement, propagation modes, unrelated
attachments, separate caches, signed zero, and buffers retaining old/current
attachments after cache destruction. Assertions check behavior rather than
cache object identity.

Before timing, each variant emits 32 complete snapshots per workload:
384 step snapshots plus final states for every buffer. Comparisons include
all attachment fields, numeric representation and double bits, and propagation
modes. These complement the final-output checksums during timing.

The separate native job builds the application dependency graph and uses
generated, hashed media fixtures for decoder geometry, planar output,
resolution changes, rotation, and timestamp-only output. Integrated head
`9b0e52193bbc41e42e7c0cd821f05e557bb32975` passed **26 tests across five suites**
on macOS 26.6.2, Apple M1 (Virtual), Swift 6.3.3:
[native app qualification](https://github.com/Jagalite/illiquid/actions/runs/39856561208/job/120096177301).
That result qualifies the tested integration behavior, not interactive
playback or application performance.

## Results

The measured candidate is integrated commit
`9b0e52193bbc41e42e7c0cd821f05e557bb32975`. Both jobs in
[run 39856561208](https://github.com/Jagalite/illiquid/actions/runs/39856561208)
succeeded. The component ran on macOS 26.6.2, an Apple M1 virtual machine,
and Apple Swift 6.3.3. This is one measured cohort on one hosted machine.

**Accept the bounded cache for steady geometry.** All eight pairs improved
in every stable-geometry workload, in both elapsed and process CPU time.
The six ordinary stable/rotating cases reduced median paired elapsed time
by 65.4–67.6%; clearing both attachments before each operation still reduced
it by 57.8%. The latter result supports reuse even when a buffer has no
previous geometry attachments.

Times below cover one aspect-plus-aperture application, with the additional
removals in `rotating-cleared`. They are microseconds per operation, not
complete frame-processing times. Percentage columns are medians of the eight
paired percentage changes, not ratios of the two displayed medians.

| Workload | Baseline median µs | Cache median µs | Paired elapsed change | Paired CPU change | Elapsed wins |
|---|---:|---:|---:|---:|---:|
| `stable-square` | 1.235 | 0.429 | -65.7% | -65.7% | 8/8 |
| `stable-anamorphic` | 1.510 | 0.496 | -67.6% | -66.1% | 8/8 |
| `stable-cropped` | 1.237 | 0.425 | -66.0% | -66.0% | 8/8 |
| `stable-4k` | 1.335 | 0.444 | -65.5% | -65.2% | 8/8 |
| `rotating-square` | 1.221 | 0.427 | -65.4% | -65.4% | 8/8 |
| `rotating-anamorphic` | 1.369 | 0.469 | -65.6% | -66.0% | 8/8 |
| `rotating-cleared` | 1.385 | 0.577 | -57.8% | -57.8% | 8/8 |
| `alternating-aspect` | 1.193 | 0.732 | -38.7% | -38.7% | 8/8 |
| `alternating-aperture` | 1.230 | 0.918 | -25.3% | -25.3% | 8/8 |
| `alternating-both` | 1.304 | 1.408 | +7.6% | +9.9% | 2/8 |
| `invalid-aspect` | 0.733 | 0.230 | -68.8% | -68.8% | 8/8 |
| `rounding-and-signed-zero` | 1.253 | 1.313 | +6.5% | +6.5% | 1/8 |

The cache has a measurable miss cost. When both geometry kinds alternate on
every operation, median paired elapsed time increases by **7.6%**, or
**92.7 ns per operation**; process CPU increases by **9.9%**, or 122.9 ns.
Only two of eight elapsed pairs and one of eight CPU pairs improve in that
control. The rounding/signed-zero control also increases elapsed time by
**6.5%**, or 78.1 ns. These results are retained, not treated as failures to
exclude from the sample. Changing just one metadata kind still benefits from
reuse of the other.

Hosted-runner variation is visible. The alternating-both elapsed changes
range from −17.7% to +58.0%; the +58.0% observation remains in the reported
median and raw data. CPU changes for that workload range from −13.9% to
+15.4%. Stable workloads save approximately 0.77–0.94 µs per operation by
median paired elapsed difference. These small absolute savings, the bounded
storage, and passing behavior checks justify the change for the intended
steady-geometry path; the study does not measure how often each workload
occurs during a user's playback.

All **192 timed observations and 24 calibrations** are retained. The same
13 semantic tests passed for baseline and candidate in debug and release
(52 test executions), with warnings treated as errors. All **384 step
snapshots plus 43 final buffer states per variant** matched exactly before
timing, and every timed pair's output checksum matched.

The native app run passed its 26 selected test declarations (44 expanded
invocations), with no skips. Its logs retain compiler warnings from unchanged
files and a demuxer “Packet corrupt” warning at the synthetic concatenated
transport-stream boundary. The resolution-transition test still decoded both
expected sizes and checked every returned aperture's dimensions, offsets, and
propagation mode. Raw generated media is not included in the evidence; media
hashes are runner-produced receipts.

An earlier eleven-workload prototype run,
[39853545272](https://github.com/Jagalite/illiquid/actions/runs/39853545272),
was superseded while both jobs were queued. It produced no timing cohort;
there is no omitted prototype measurement or independent replication claim.

## Retained evidence

Evidence is committed under [`evidence/macos-arm64`](evidence/macos-arm64):

- [`summary.json`](evidence/macos-arm64/summary.json),
  [`observations.json`](evidence/macos-arm64/observations.json), and
  [`calibrations.json`](evidence/macos-arm64/calibrations.json) retain every
  reported measurement.
- [`manifest.json`](evidence/macos-arm64/manifest.json) identifies sources,
  compiled inputs, toolchain, commands, and their hashes.
- [`component-records.json.gz`](evidence/macos-arm64/component-records.json.gz)
  is the complete component bundle: a gzip-compressed JSON object mapping
  relative filenames to text contents. It contains all 247 retained records,
  including both output receipts, exact source snapshots, and command logs.
- [`native-app.zip`](evidence/macos-arm64/native-app.zip) contains the native
  test log, host receipt, fixture commands, fixture hashes, and timestamp
  oracle logs. Both complete GitHub job logs are also retained as `.log.gz`.
- [`provenance.json`](evidence/macos-arm64/provenance.json) records the run,
  jobs, artifact identities, and retained archive checksums.
- [`independent-audit.json`](evidence/macos-arm64/independent-audit.json)
  records the separate source, output, pairing, and summary audit.

To inspect the component archive as a single JSON object:

```sh
gzip -dc Benchmarks/VideoGeometryMetadata/evidence/macos-arm64/component-records.json.gz \
  > /tmp/illiquid-video-geometry-records.json
```

The committed archives remain available after the temporary Actions artifacts
expire. Neither archive contains generated executables or build directories.

## Scope and tradeoffs

These are warm component measurements of preparation and attachment writes,
including common driver overhead. Changing-geometry controls expose cache
lookup/replacement costs and must accompany favorable stable results. The
cache adds bounded retained metadata; allocations and physical memory
footprint are not directly measured.

The experiment excludes decoding, pixel conversion, renderer enqueue and
presentation, UI latency, energy, and other frame preparation. It does not
establish changes in whole-player CPU, frame rate, dropped frames, or battery
life. Hosted virtual-machine timings do not establish tail-latency bounds on
physical Macs.
