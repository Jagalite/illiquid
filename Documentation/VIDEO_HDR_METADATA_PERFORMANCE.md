# Reusing decoded video HDR metadata

## Finding and change

At baseline `7f9ba073394b77a908e0589447c6edc8d10b832c`,
`VideoDecoder.makeFrame` prepares mastering-display and content-light payloads
inside `applyColorMetadata` for CoreVideo attachments, then prepares the same
payloads again for `NativeDecodedVideoFrame`.

The candidate prepares each payload once, passes the resulting immutable
`Data?` to `applyColorMetadata`, and stores the same values in the decoded frame.
The production change is confined to `VideoDecoder.swift`: 17 added lines and
21 removed lines. It introduces no cache, invalidation rules, shared mutable
state, dependencies, or changes to the C serializers.

The mastering-display serializer returns either zero or 24 bytes; the
content-light serializer returns either zero or four bytes. The attachment
setter retains the same exact-size checks and `shouldPropagate` mode. Missing
source metadata continues to preserve any existing pixel-buffer attachment.
The frame's `hasMasteringDisplayMetadata` and `hasContentLightMetadata` flags
continue to inspect the actual output buffer, including inherited hardware
attachments.

## Confirmation protocol

The initial study below was exploratory. Before any confirmation measurements
were available, the [confirmation plan](PerformanceEvidence/VideoHDRMetadata/confirmation-plan.json)
fixed twenty AB/BA pairs, a 300 ms calibration target, all ten workloads, and
`hdr10_bgra` and `hdr10_p010` as the two primary cases. Each primary case must
have a median paired process-CPU ratio at most 0.95, a median paired saving of
at least 100 ns, at least 16 of 20 CPU-pair wins, improvement in both execution
order groups, and a lower overall wall-time median. The controls must not show
a repeatable CPU regression above 5%.

These are practical acceptance criteria for this narrow change on a shared CI
host. All samples and scheduling outliers are retained. The two runs are
reported separately; the confirmation is not pooled with the initial study,
and the production code is not tuned or rerun until a favorable timing appears.

## Initial native results

The initial run used macOS 26.6.2 on an arm64 GitHub-hosted runner,
Apple Swift 6.3.3, SDK 26.5, and candidate
`5e77f6602f3e9abf7b484252e8183352a1baf24d`.
[Run 39844949774](https://github.com/Jagalite/illiquid/actions/runs/39844949774)
passed the 103-record component parity check and all selected native integration tests:
5 test functions across 3 suites, comprising 13 parameter/fixture invocations.
Nine of those invocations are the newly added decoder-route cases.

Ten AB/BA pairs per workload, 100 ms calibration target. Times are medians in
microseconds per metadata preparation. Negative changes mean lower cost.

| Workload | Baseline wall µs | Candidate wall µs | Wall change | CPU change | Wall pair wins |
| --- | ---: | ---: | ---: | ---: | ---: |
| `sdr_bgra` | 1.412 | 1.319 | -6.6% | -6.1% | 8/10 |
| `sdr_nv12` | 1.565 | 1.382 | -11.7% | -11.7% | 7/10 |
| `hdr10_bgra` | 2.967 | 2.440 | -17.8% | -17.6% | 7/10 |
| `hdr10_p010` | 3.442 | 2.658 | -22.8% | -18.2% | 8/10 |
| `mastering_only` | 2.706 | 2.495 | -7.8% | -7.8% | 8/10 |
| `light_only` | 2.361 | 1.981 | -16.1% | -12.7% | 10/10 |
| `metadata_changes` | 2.913 | 2.614 | -10.3% | -10.5% | 6/10 |
| `preexisting_attachments` | 0.768 | 0.549 | -28.5% | -30.7% | 10/10 |
| `hdr10_p010_cleared` | 2.911 | 2.547 | -12.5% | -12.5% | 7/10 |
| `sdr_nv12_cleared` | 1.758 | 1.472 | -16.3% | -14.4% | 9/10 |

Every median improved, but some individual process pairs varied substantially.
These first-run percentages are preliminary estimates; a predefined second
run uses twenty pairs and a 300 ms target, with production code, the harness,
compiler flags, fixtures, and default scheduling policy unchanged. That run checks whether the
result survives longer samples rather than selecting the fastest observation.

[Preserved initial evidence](PerformanceEvidence/VideoHDRMetadata/initial-macos/)
contains every timing sample, exact parity traces, source/compiler/library
receipts, and the complete native build/test log. The compact summary removes
only duplicate sample objects already preserved in `measurements.jsonl`.

## Measurement scope

`Benchmarks/VideoHDRMetadata/run.py` extracts the production metadata methods
from the pinned baseline and candidate. It changes only their access modifier
and supplies a small wrapper preserving their call order. Both executables use
identical Swift optimization flags, the full unchanged CFFmpeg shim, pinned
FFmpeg libraries, real AVFrame side data, and real CoreVideo pixel buffers.

The measured operation includes color attachment preparation and the returned
HDR payloads. It excludes video decoding, pixel conversion, pixel-buffer and
frame allocation, geometry attachment preparation, and presentation. This is a
component measurement; no whole-player CPU, frame-rate, battery, peak-memory,
or allocation-count improvement was measured.

Eight workloads use a warm ring of 32 frame/buffer pairs. Two additional
controls clear all attachments before each preparation, with clearing inside
the timed interval, to exercise fresh attachment insertion. The controls use
`CVBufferRemoveAllAttachments` rather than the production planar path's
individual key removals, so their absolute cost includes this fixture operation.

Fixture construction, warmup, process startup, and JSON output are outside the
timed interval. Temporary autorelease cleanup is inside it. The final fixture
buffers and their attachment values remain live after timing. Returned payloads
are consumed and dropped per iteration; the benchmark does not simulate the
entire decoded-frame queue lifetime.

The runner checks the exact production call-site ordering and consumers before
constructing its wrappers, and saves the inspected source snippets and hashes.
The initial run uses the runner defaults: matched iteration counts targeting
approximately 100 ms for the faster variant and ten separate-process pairs,
alternating AB/BA order. Confirmation increases those settings to 300 ms and
twenty pairs. The runner records wall and process CPU time, all samples, paired ratios,
checksums, source/compiler/library hashes, and native environment information.
It requires exact correctness parity before timing, and imposes no automated
performance threshold.

## Correctness qualification

The component harness verifies 103 exact output records per variant. Its corpus
covers SDR, HDR10 and HLG color mappings; BGRA, NV12 and P010 outputs; independent
mastering/content-light payloads; all mastering validity-flag combinations;
truncated and oversized side data; clipped coordinates; content-light integer
truncation; inherited attachment bytes and propagation modes; repeated mutation
and clearing of one AVFrame; retained Data lifetime after source release; and
reused output buffers.

Golden mastering bytes are specified independently from the existing HDR10
fixture: `33c286c41d4c0bb884d03e803d1340420098968000000032`. Golden content-light
bytes are `03e80190`. The existing serializer's rounding, clipping and encoding
remain unchanged.

`VideoHDRMetadataTests` adds nine parameterized native fixture cases across
required VideoToolbox hardware decoding, forced software BGRA, and forced
software planar output. The tests compare source payloads with independent
expected bytes and actual attachments, retain the first output through later
frame decoding and decoder destruction, and verify value-semantic copies.
H.264 SDR and HLG controls check absent static HDR data. A configured missing or
empty fixture fails the suite rather than silently skipping it.

The dedicated macOS workflow also runs existing hardware HDR/HLG tests and
software HDR/SDR planar-versus-BGRA comparisons, while compiling the complete
application dependency graph in release configuration.

## Reproduction

Prepare the pinned native SDK as documented in the benchmark README, then run:

```sh
python3 Benchmarks/VideoHDRMetadata/run.py --pairs 10 --target-ms 100 \
  --output /tmp/illiquid-video-hdr-metadata
```

The workflow `.github/workflows/video-hdr-metadata.yml` generates the required
native fixtures and runs the release integration tests. Source extraction can
be inspected without Apple frameworks using `--prepare-only`; Linux extraction
is not native performance or decoder qualification.
