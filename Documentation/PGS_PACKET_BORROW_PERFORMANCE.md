# PGS composition metadata: avoid a temporary packet copy

> Integration review update (2026-10-22): the previously pending [native rerun](https://github.com/Jagalite/illiquid/actions/runs/39851029701) completed successfully at `18ff51664de46c55b3b9aae1c195efd2b09259d0`. Its app/test graph build and 29 tests in four suites passed. Pending statements below describe the original publication snapshot. Combined-branch validation is reported separately by the integration PR checks.


## Question and scope

Can the bitmap-subtitle adapter inspect PGS composition metadata without copying
the complete compressed packet first, while preserving the parser's results,
errors, packet ownership, and decoded subtitle output?

The baseline is `7f9ba073394b77a908e0589447c6edc8d10b832c`. The production change
affects `SubtitleDecoder.decode` and `PGSSubtitlePresentation` only. It is separate from
the existing bitmap palette conversion, subtitle timeline, GPU upload, and
read-ahead investigations.

## Identified work

Before each PGS decode, `SubtitleDecoder` obtained `FFmpegPacket.data`. That
getter constructs `Data(bytes:count:)` from the packet's entire payload. The
metadata parser then reads segment headers and composition references, skipping
palette/object payloads using their advertised lengths. A large object payload
was therefore copied even when the metadata result was `nil`.

The new packet overload borrows a bounded `UnsafeBufferPointer<UInt8>` for the
synchronous parser call. `withExtendedLifetime(packet)` retains the owner until
the parse returns or throws. The existing `Data` entry point forwards to the
same private parser. All parsing statements, bounds checks, error codes, and
rectangle/crop handling are preserved.

The returned presentation stores an array of value objects containing integer
coordinates and crop fields. It retains no packet pointer or payload storage.
Parsing still finishes before `illiquid_decode_subtitle` runs. A packet with no
composition continues to leave prior presentation metadata unchanged; an empty
composition continues to clear its object references. Missing data and
nonpositive packet sizes continue to produce no metadata.

FFmpeg still decodes the compressed subtitle pixels. The existing conversion
from decoded palette pixels into BGRA regions and the renderer upload remain.
This change removes the temporary compressed-packet copy from metadata intake.

## Measured result and validation status

**The native component benchmark qualifies. Native integration tests are pending.**

The reported cohort is [run 39846875975](https://github.com/Jagalite/illiquid/actions/runs/39846875975),
measured at `b2a16b1b490de055606f783f92b86d795f99a8ac`, on Apple M1 (Virtual),
macOS 26.6.2 arm64, Apple Swift 6.3.3, and the pinned FFmpeg 8.1.2 SDK.
Executables use `-O -whole-module-optimization` and Swift language mode 6.

| Workload | Baseline wall ns/packet | Borrowed wall ns/packet | Wall reduction | CPU reduction |
| --- | ---: | ---: | ---: | ---: |
| Tiny END control | 23.546 | 12.235 | 48.04% | 48.61% |
| One-object composition | 195.981 | 95.095 | 51.48% | 54.26% |
| Two cropped objects | 277.349 | 159.654 | 42.44% | 42.25% |
| Object payload, about 4 KiB | 315.569 | 14.856 | 95.29% | 95.30% |
| Object payload, about 64 KiB | 7,138.276 | 18.371 | 99.74% | 99.74% |
| Composition + object, about 64 KiB | 20,512.741 | 127.910 | 99.38% | 99.37% |
| Multiple segments, about 256 KiB | 68,462.677 | 37.629 | 99.95% | 99.94% |
| Composition + segments, about 256 KiB | 55,675.400 | 117.407 | 99.79% | 99.78% |

Absolute values are the median of eight per-process mean times, normalized by
that process's packet count. Reduction is calculated from the two displayed
medians, not from the median paired ratio. All 64 paired comparisons favor the
borrowed path for both wall and process CPU time. All 128 timed observations
exceed the 60 ms minimum: the shortest is 202.528 ms wall and 202.030 ms CPU.
No observations were removed. The [raw summaries](../Benchmarks/PGSPacketBorrow/evidence/measured-summary.json)
retain ranges, individual paired ratios, payload sizes, and iteration counts.

Both implementations produced identical complete snapshots for **509 cases**,
including **143 authored expectations**. Across all 509 cases, the outcomes were
114 compositions, 72 absent compositions, and 323 errors. An independent recomputation verified the source
and library hashes, all 128 observations and 36 calibration pilots, all 164
measurement-process stdout hashes, output checksums, sample ordering, and
summary calculations. All nine recorded production source/module files and the
benchmark driver/runner are byte-identical at the subsequent test-fix commit
`18ff51664de46c55b3b9aae1c195efd2b09259d0`.

### Native integration is still pending

The same run compiled the production `IlliquidCore`, `IlliquidNativePlayback`,
and `IlliquidPlayer` targets. Its overall `swift test` invocation then failed
while compiling a new test: a throwing parser call inside `#require` needed an
explicit inner `try`. The fix separates the throwing parse from the optional
assertion. This changes only the test helper; it does not change production or
benchmark code. The [test build log](../Benchmarks/PGSPacketBorrow/evidence/native-test-build.log)
is preserved. **This run did not execute the selected native tests, and it is
not a successful full app/test build.**

The [rerun after the test fix](https://github.com/Jagalite/illiquid/actions/runs/39851029701)
is pending at publication. The PR remains a draft until native integration is
confirmed. Its workflow is
[`pgs-packet-borrow-performance.yml`](../.github/workflows/pgs-packet-borrow-performance.yml).
The selected suites are `PGSSubtitlePacketBorrowTests`, `PGSSubtitleCropTests`,
`BitmapSubtitleTests`, and `PacketOwnershipTests`.

These suites define 29 tests, expanding to 35 argument-specific executions;
those are expected coverage counts, not claimed pass counts. The five new tests
cover complete composition and crop values, legal maximum segment lengths,
malformed/truncated input, geometry limits, missing and nonpositive payloads,
and metadata surviving packet overwrite and release. Existing native tests
provide independent pixel expectations, crop placement, palette-only updates,
separate presentation packets, seek/reset behavior, zero-area crops, and
multiple references to one object.

The workflow generates original PGS, DVD, and DVB containers and supplies the
fixture environment variables needed by container, paused-seek, forced-selection,
and demux-ownership tests. The fixture generator has an optional `--skip-vobsub`
mode because the pinned SDK supplies `ffmpeg` but not `ffprobe`. Its default
behavior is unchanged. External VobSub integration is outside this qualification.

The [evidence index](../Benchmarks/PGSPacketBorrow/evidence/README.md) retains all
completed attempts, including rejected or incomplete qualifications, with exact
compressed bundles and provenance. The latest component timing is reported even
though that workflow's subsequent test compilation failed; the overall workflow
is not being represented as successful.

## Experiment design

[`Benchmarks/PGSPacketBorrow`](../Benchmarks/PGSPacketBorrow/README.md) contains the
frozen original parser, full source hashes, a Swift driver, and a Python runner.
Both benchmark executables use the complete production packet owner, parser,
timing/error dependencies, and CFFmpeg module with real FFmpeg libraries. The
runner verifies baseline ancestry and rejects changes in their shared sources.
Only the driver call site selects the original copying path or the new packet
overload.

Before timing, both variants emit complete per-case metadata and error snapshots.
Their entire traces must match. Authored expected outcomes additionally check
valid coordinates/crops, nil versus explicit clear, bounds errors, and malformed
tails. The corpus also includes deterministic random bytes and mutated valid
compositions. Packet-vs-Data comparisons inside the new unit tests share the
current parser; the frozen-baseline trace comparison supplies the independent
check against the previous implementation.

Eight timed workloads each rotate the same sixteen packets. They include a
three-byte END control, small compositions, two cropped objects, object-only
payloads around 4 KiB and 64 KiB, and approximately 256 KiB split across legal
segments, with and without a composition. Large object bytes are deterministic
pseudo-RLE used to measure packet-size scaling. These particular benchmark
payloads are not claimed to decode to valid pixels; the actual decoder tests use
separate valid authored subtitles.

Eight fresh-process pairs alternate baseline/candidate and candidate/baseline.
Fixture allocation, validation, and warmup occur outside the measured interval.
Every metadata field feeds an emitted checksum. Each variant is independently
calibrated to complete cycles of the identical packet distribution, then time is
normalized per packet. Both CPU and monotonic wall observations must last at
least 60 ms; short samples are retained and fail qualification. No observations
are discarded. Raw records preserve iteration counts, payload sizes, checksums,
order, CPU/wall durations, ranges, and paired ratios.

## Qualification history

The original 80 ms calibration target produced 17 observations shorter than the
required 60 ms in two workloads. The runner retained every sample and rejected
the cohort. The target was increased to 240 ms, then the entire balanced cohort
was rerun. No source optimization was made in response to those timings and no
observation was selectively removed.

An already-running fixture-update workflow finished its benchmark at the
original target as the duration change superseded it; its completion receipt is
preserved, but native tests never started. The first 240 ms cohort then passed all
timing and correctness gates, but its workflow stopped during fixture generation
because the pinned SDK does not bundle `ffprobe`. The optional generator mode
described above addresses that test-setup dependency while retaining the
relevant native container tests. All earlier benchmark bundles remain in the
evidence directory, with provenance distinguishing each attempt.

The next run compiled the production targets and passed the benchmark, then
found a compile error in a new test: the throwing parser call needed to be
separated from the Swift Testing `#require` optional assertion. That test-only
correction left production and benchmark sources unchanged. Its receipt is also
preserved. The reported figures use that latest completed benchmark cohort.
The native integration rerun is pending after the test-only correction.

## Interpretation limits

The experiment measures the synchronous metadata-intake component before pixel
decoding. It does not measure whole-player CPU, frame rate, peak or resident
memory, battery use, or the user's actual media collection. Real PGS packet sizes
and update frequency determine the absolute playback benefit. Eliminating a
temporary copy is a structural property of the changed path; a large percentage
improvement in that helper must not be reported as the same improvement in the
player.

## Reproduce

On macOS with the repository's pinned native dependencies installed:

```sh
python3 Benchmarks/PGSPacketBorrow/run.py \
  --pairs 8 --target-ms 240 --output /tmp/pgs-packet-borrow

python3 Scripts/generate-bitmap-subtitle-fixtures.py \
  /tmp/pgs-packet-borrow-fixtures --skip-vobsub
export ILLIQUID_BITMAP_FIXTURE_DIR=/tmp/pgs-packet-borrow-fixtures
export ILLIQUID_PACKET_OWNERSHIP_FIXTURE=/tmp/pgs-packet-borrow-fixtures/generated-pgs.mkv
swift test --force-resolved-versions -c release --jobs 2 --no-parallel --filter \
  'PGSSubtitlePacketBorrowTests|PGSSubtitleCropTests|BitmapSubtitleTests|PacketOwnershipTests'
```

The runner records compiler/platform information, source and library hashes,
binary hashes, calibration trials, complete parity traces, and raw measurements.
The workflow preserves logs and receipts even when a qualification stage fails.
