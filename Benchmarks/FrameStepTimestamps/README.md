# Frame-step timestamp discovery

`NativeFrameStepReader` opens a short-lived software decoder when the presented
frame history cannot answer a paused forward/backward step. Previously it
prepared a complete BGRA `CVPixelBuffer` and display metadata for every accepted
frame, then kept only `presentationTime`.

The candidate uses the same codec submission, reordering, temporal deinterlacer,
timestamp validator, seek strategy, cancellation and decode budgets. A dedicated
output route returns accepted presentation times before display-pixel
preparation. It does not replace decoded frame timestamps with packet timestamps
or assume constant frame rate.

## Native qualification

The `Frame step timestamp discovery` GitHub workflow uses the repository's pinned
Apple Silicon native SDK and Xcode. It generates synthetic inputs and requires the
new regression suite on relevant pull requests. Manual workflow dispatch also
measures both the baseline and candidate on the same macOS runner; its
`baseline_ref` input defaults to the pinned research baseline. No installed app
data, user media, or graphical session is used.

To reproduce on a Mac with the project's native dependencies installed:

```sh
python3 Benchmarks/FrameStepTimestamps/generate-fixtures.py --output /tmp/illiquid-step-fixtures
ILLIQUID_FRAME_STEP_FIXTURE_DIR=/tmp/illiquid-step-fixtures \
ILLIQUID_FRAME_STEP_REQUIRE_FIXTURES=1 \
swift test --force-resolved-versions -c release --jobs 2 --no-parallel \
  --filter VideoTimestampDiscoveryTests
python3 Benchmarks/FrameStepTimestamps/run.py \
  --output /tmp/illiquid-step-results --fixtures /tmp/illiquid-step-fixtures \
  --pairs 6 --iterations 3
```

Both output directories must be new when first used. The benchmark adds its own
four larger inputs to the fixture directory after correctness qualification.
It creates a detached baseline worktree and independent release build directories
inside the result directory; their disk use is intentionally excluded from the
uploaded receipt artifact. Remove that temporary worktree with `git worktree
remove` before deleting the result directory.

## Correctness coverage

Eight tiny inputs cover reordered H.264 B frames, variable frame rate, a two-second
stream origin, a single-frame movie, and top/bottom-field-first MPEG-2 in both
program-stream and indexed Matroska containers. The fixture
generator records rational PTS from FFmpeg `showinfo`, including an independent
BWDIF pass for interlaced inputs. It checks frame counts, field order, B-frame
presence, irregular cadence and origin before writing the oracle manifest.

The tests compare exact `CMTime` arrays between full-frame and scalar output and
compare their normalized times with the independent oracle. They also exercise
EOF drain, repeated drain, flush/seek, seek-floor generation fences, cancellation,
throwing consumers followed by continued filtered output, and both BGRA and
planar output-pool bypass. Full-frame decoding is the positive control for pool
creation. Reader-level tests cover both directions at boundaries and between
frames using indexed containers. Separately, the identical benchmark harness
records 76 reader requests on all eight fixtures against the actual baseline and
candidate implementations and requires exact target equality, including `nil`.
That differential qualification runs outside timed measurements.

Qualification initially exposed a test-oracle mismatch for MPEG program streams:
seeking to the stream origin can skip an initial keyframe, whereas a sequential
open starts with that keyframe. Cancellation/replay assertions now compare the
same seek on both decoder output routes. Indexed interlaced inputs support
absolute adjacency assertions; program streams retain decoder coverage and
baseline/candidate reader equivalence coverage. This change preserves the
existing demuxer seek policy.

The fixture suite is explicitly disabled in ordinary tests without its fixture
environment. Setting `ILLIQUID_FRAME_STEP_REQUIRE_FIXTURES=1` prevents a missing
path from silently skipping dedicated qualification. The performance suite is
separately opt-in via `ILLIQUID_FRAME_STEP_BENCHMARK=1`.

## Measurement method and scope

`run.py` compiles the identical `FrameStepPerformanceTests.swift` against pinned
baseline `a2de305c8dbcaa81aac1477df7c9a0017c14eae3` and the candidate checkout.
Each pair alternates baseline/candidate order in fresh processes. Each process
warms one request, then times three complete reader requests. Every request still
opens, probes, seeks, decodes and destroys its own decoder. The filesystem cache
is warm; these are not cold disk measurements.

The cases use deterministic five-second, 30 fps H.264 videos at 320×180, 1920×1080
and 3840×2160. Long GOPs contain 150 frames; the short-GOP control contains 15.
The requested position is 3.2 seconds. The harness checks the exact expected
adjacent timestamp, and the runner checks matching outputs for every pair.
A normal full-frame BGRA decode case checks for added overhead in the shared
decoder path, verifies all 150 frames, and compares the timestamp sum.

Receipts include source/harness and fixture hashes, compiler/OS/hardware details,
commands and logs, raw process rows, and medians/ranges. Wall time and process CPU
are reported per request. Peak RSS is the **whole test process** high-water mark,
not isolated decoder allocation or whole-app memory, and includes the warm-up.

The primary result concerns fallback **target discovery**. It excludes the
subsequent playback seek and presentation of the selected frame, renderer-history
hits, UI responsiveness, steady playback FPS, hardware decode and energy use.
The codec and BWDIF still decode/process images internally; only preparation of
display output is removed.

## Native results — 2026-10-21

[Native research run](https://github.com/Jagalite/illiquid/actions/runs/39669102988)
passed using baseline `a2de305c8dbcaa81aac1477df7c9a0017c14eae3` and candidate
`b5336dc96b31c6f4122d232dbd53dcae049bc21c`. The production-source and harness
hashes in [environment.json](evidence/native/environment.json) identify exactly
what was measured. Subsequent changes only document the results and configure
ongoing qualification.

The runner was an arm64 `VirtualMac2,1` with three CPUs and 7 GiB RAM, running
macOS 26.6.2, Apple Swift 6.3.3, and the pinned FFmpeg 8.1.2 SDK. This is one host
and synthetic local media, so the observations are descriptive, not a hardware-
or media-independent performance guarantee.

| Discovery workload | Baseline median (ms) | Candidate median (ms) | Paired wall reduction | Paired CPU reduction |
| --- | ---: | ---: | ---: | ---: |
| 320×180, backward | 21.60 | 17.46 | 12.8% | 21.9% |
| 1080p, long GOP, backward | 256.84 | 213.95 | 16.4% | 13.0% |
| 1080p, long GOP, forward | 300.56 | 221.61 | 17.6% | 17.7% |
| 1080p, short GOP, backward | 33.97 | 29.57 | 15.1% | 13.9% |
| 4K, long GOP, backward | 925.55 | 751.01 | 19.7% | 18.6% |
| 4K, long GOP, forward | 948.60 | 755.78 | 13.4% | 13.8% |

Each time column is the median of six process means, each based on three timed
requests after one warm-up. The percentage columns are medians of six **paired**
reductions, so they need not equal the percentage difference between the two
separately reported medians. Long GOPs contain 150 frames and the short GOP
contains 15 frames at 30 fps. The requested position is 3.2 seconds.

All 36 discovery CPU pairs improved; 35 of 36 elapsed-time pairs improved.
The full data retains the slower 4K-forward sample: baseline 1,185.5 ms versus
candidate 1,527.4 ms elapsed, with CPU still decreasing from 2,226.6 to
1,975.9 ms. Its cause was not measured. These results do not establish a
worst-case or tail-latency bound.

### Ordinary decoding control

The control decodes all 150 frames of the 1080p long-GOP input into BGRA output.
Its median elapsed times were 358.3 ms baseline and 344.1 ms candidate, with
ranges of 318.9–431.5 ms and 313.8–461.5 ms. Two of six pairs were slower.
Comparing arithmetic means gives **0.9% more elapsed time and 1.1% less CPU**.
The differing averages and paired medians reflect substantial variability.
Treat this as no clear systematic change in the limited software BGRA control;
it does not demonstrate an additional normal-decoding speedup or a strict
no-regression bound.

### Allocation and correctness evidence

Whole test-process peak RSS medians were about 8.6–8.7 MiB lower for the 1080p
lookup cases and 32.3–32.4 MiB lower for 4K. These high-water measurements include
startup and warm-up. The direct decoder tests additionally confirm that neither
the BGRA nor planar presentation output pool is created during timestamp-only
output; FFmpeg and the temporal filter still allocate decoded images.

The mandatory native qualification passed **80 tests in eight suites**. Its
eight generated media fixtures provide **545 independently checked output
timestamps**. The actual old/new reader comparison matched **all 76 requests**,
including 27 `nil` results, and all **84 timing rows** passed their output checks.

### Preserved receipts

- [Raw timing rows](evidence/native/measurements.jsonl), [summary](evidence/native/summary.json), and [verification](evidence/native/verification.json).
- [All baseline/candidate reader outputs](evidence/native/reader-parity.json).
- [Environment and source hashes](evidence/native/environment.json), [workloads](evidence/native/workloads.json), and [command metadata](evidence/native/commands.json).
- [Correctness fixture oracle](evidence/native/fixture-manifest.json), [performance fixture hashes](evidence/native/fixtures.json), and [native qualification log](evidence/native/qualification.log).
- [Workflow/artifact provenance](evidence/native/source.json). The original workflow artifact also contains every per-command build/run log.

The evidence preserves every measured sample, including the outliers. The result
concerns fallback target discovery; the subsequent seek and display operation
remain outside the measured interval.
