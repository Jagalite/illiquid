# PCM sample sanitization performance research

## Decision and scope

This experiment improves the cost of checking ordinary PCM output for invalid
Float samples. It changes only `sanitizeInterleavedFloatPCM` in
[`AudioDecoder.swift`](../Sources/IlliquidNativePlayback/Media/AudioDecoder.swift).
The comparison baseline is main commit
`8c3cc3d4008d5d1b8d436bcf2d51d891382b6548`.

On the native Apple M1 virtual runner, the four tested healthy stereo/surround
layouts show a **70.9–75.9% median paired wall-time reduction**, with every
pair favoring the candidate in both wall and CPU time. Linux independently
shows **75.1–81.3%** for the same layouts. This is a microsecond-scale
component gain with explicit dense-invalid repair tradeoffs; the full app
build and native audio regressions also pass.

The decoder calls the sanitizer after normal resampling and resampler draining
at end of stream or a format change. Its output rate is 48,000 frames per
second, so stereo, 5.1, and 7.1 output require 96,000, 288,000, and 384,000 Float
checks per second of decoded audio.
Those figures follow directly from the decoder's output rate and channel
counts; they are not profiling measurements. The original helper visits every
sample individually, even when an entire buffer contains valid finite audio
or silence.

The optimization checks eight sample bit patterns together. If all eight are
finite normal values or signed zero, it advances without individual sample
classification. A group containing an invalid value takes the scalar repair
path, using the original `Float.isFinite` and `Float.isSubnormal` predicates.
Fewer than eight remaining samples also use scalar repair.

This is a component optimization. No decoder options, resampling parameters,
channel negotiation, buffer allocation policy, audio delay, scheduling, or
presentation timing change. The experiment does not establish a whole-player
CPU, energy, memory, startup, or audible playback improvement.

## Correctness and memory access

For an IEEE binary32 Float, removing the sign bit produces either zero, a
finite normal magnitude in `[0x00800000, 0x7f800000)`, a subnormal magnitude
between zero and that interval, or an infinity/NaN magnitude at or above the
interval. The SIMD fast path accepts only zero and the finite normal interval.
Every other group goes through scalar classification.

Both positive and negative zero remain bit-for-bit unchanged. Finite normal
values outside `[-1, 1]` remain unchanged too: this helper sanitizes invalid
samples and does not clip audio. All NaN payloads, both infinities, and both
signs of subnormal samples become positive zero. Separate replacement counters
retain their original meanings. The final one to three bytes of an incomplete
Float remain untouched, matching the existing helper's behavior.

The implementation keeps the existing mutable `Data` borrow and its
copy-on-write behavior. It uses raw unaligned loads and raw stores instead of
binding byte storage to a Float pointer. A first prototype retained the old
binding; independent review identified that a byte-offset slice need not meet
the typed pointer's alignment requirement. Passing a test on hardware that
allows an unaligned instruction would not satisfy that language contract.
The final implementation removes that assumption. See the
[Swift standard-library maintainers' explanation of typed pointer alignment](https://forums.swift.org/t/unaligned-pointers-why-doesnt-this-crash/77617).

All vector loads cover complete groups within `data.count / 4` samples. Scalar
loads and stores cover exactly one complete sample. No typed pointer or Data
storage address escapes the mutable borrow.

## Measurement method

[`Benchmarks/PCMSanitization/run.py`](../Benchmarks/PCMSanitization/run.py)
extracts the exact result type and decorated sanitizer function from the pinned
baseline and the candidate working tree. It imports Foundation so the actual
`Data` implementation participates. It does not benchmark a second handwritten
implementation of the candidate.

Each implementation is compiled with Swift 6, `-O`, and whole-module
optimization into a separate testable module/object. The harness is then
compiled and linked against that object. This boundary keeps the optimizer
from discarding sanitizer stores merely because a later benchmark step
restores the buffer. Compiler version, flags, complete source hashes, extracted
declaration hashes, harness/runner hashes, binary hashes, command records, and
the host environment are retained in the evidence.

There are 55 predefined cases, all retained in the results:

| Dimension | Cases |
| --- | --- |
| Buffer sizes | 1,024 frames × 1, 2, 6, or 8 channels; 4,096 frames × 8 channels |
| Normal content | Finite sine-wave samples including both zero signs; signed-zero silence |
| Invalid content | Sparse invalid samples; 75% nonfinite samples; 100% subnormal samples |
| Ownership | Independently allocated unique buffers; deliberately shared healthy buffers |
| Restoration controls | Matching sparse, dense, and subnormal restoration work without sanitization |
| Boundary cases | 0, 1, 7, 8, and 9 samples, with zero to three trailing bytes; matching restoration controls |

Each case rotates through 16 deterministic input variants. Unique buffers are
passed directly inout from their pool; assigning a retained pool member to a
temporary Data value would accidentally benchmark a copy on write. The shared
case deliberately measures that copy and is labeled separately.
The one-channel case is additional helper coverage; the player's negotiated
output uses two, six, or eight channels. These synthetic buffers establish
component behavior under the chosen cache conditions, rather than reproduce
a captured playback trace.

Dirty buffers are restored to their original invalid bit patterns on every
iteration. Otherwise the first pass would turn them clean and later iterations
would measure the wrong path. Timed replacement totals are checked against
the known fixtures, as well as compared between implementations. The dirty
case timings include restoration, sampled output reads, and the harness loop.
Matching restoration-only controls expose that overhead; the report does not
subtract noisy control medians or present the residual as an isolated repair
cost. Clean/shared timings also include output sampling and harness overhead.

Before timing, full output bytes and both replacement counts are compared
between baseline and candidate for every fixture. The preflight also verifies
that restoration recovers every original byte and that a retained shared
owner remains unchanged. Warmup and timed checksums must match as well.

Formal runs use six paired fresh processes per implementation, alternating
AB/BA order and forward/reverse case traversal. Iteration counts are calibrated
from baseline toward 80 ms per baseline case, rounded to complete 16-fixture
cycles. Baseline and candidate use identical counts. Wall time and process CPU
time are recorded. A reported reduction is the median of the six within-pair
reductions; separately reported baseline/candidate times are their own medians.
Consequently dividing the displayed medians need not reproduce the paired
percentage exactly. These are repeat measurements on one host, not population
confidence intervals.
The separate module also creates a function call boundary; whole-player
compilation may inline the helper into its actual decoder call sites, so these
measurements do not quantify the exact cost inside a release app binary.

## Results

### Linux component qualification

The formal run on 17 October 2026 used Swift 6.3.2 on Linux x86_64,
an AMD EPYC 9V74 host, and a process affinity of CPU 4. It retained all
55 cases across six balanced pairs, for **660 timing records**. Full
preflight comparison matched **880 fixture records and 28,904,816 output
bytes**, including the repeated control families. All warmup checksums,
timed checksums, and expected replacement totals matched.

Positive percentages below mean less measured time; negative percentages mean
more measured time. The selected rows include the slower repair paths.

| Case | Baseline µs | Candidate µs | Wall reduction | Process CPU reduction |
| --- | ---: | ---: | ---: | ---: |
| `healthy_sine/1024x2` | 1.870 | 0.462 | +75.1% | +75.1% |
| `healthy_sine/1024x6` | 5.371 | 1.067 | +81.3% | +81.3% |
| `healthy_sine/1024x8` | 7.003 | 1.508 | +78.5% | +78.5% |
| `healthy_sine/4096x8` | 27.633 | 5.709 | +79.7% | +79.7% |
| `silence/1024x8` | 7.069 | 1.573 | +77.1% | +77.1% |
| `sparse_invalid/1024x8` | 7.379 | 1.779 | +75.6% | +75.6% |
| `sparse_invalid/4096x8` | 28.363 | 6.297 | +78.5% | +78.5% |
| `shared_healthy/1024x8` | 8.000 | 2.198 | +72.6% | +72.6% |
| `dense_invalid/1024x2` | 2.627 | 2.978 | -13.5% | -13.5% |
| `dense_invalid/1024x8` | 9.940 | 11.058 | -12.2% | -12.3% |
| `dense_invalid/4096x8` | 38.481 | 43.095 | -11.3% | -11.3% |
| `subnormals/1024x8` | 13.987 | 14.739 | -8.1% | -8.2% |
| `subnormals/4096x8` | 55.478 | 56.925 | -1.8% | -1.8% |

Every healthy, silence, sparse-invalid, and shared-healthy case improved in
all six pairs. For the tested stereo and surround buffer configurations,
healthy PCM showed a **75.1–81.3%** median paired reduction. That supports the
chosen clean-buffer optimization under these component conditions.

The tradeoff is real: the dense-invalid sanitize-plus-restoration cases took
**7.8–13.5% more time** across the five sizes. The all-subnormal operations
took **1.8–8.1% more time**. The candidate classifies those blocks in SIMD and
then performs scalar repair, adding work when every block is dirty. The
4,096-frame/eight-channel dense case increased from 38.481 to 43.095 µs for
the measured complete operation. Invalid-value frequency in actual playback
was not measured; these are synthetic stress cases, not a claim about how
rare or common damaged PCM is in the field.

Unchanged restoration-control paired reductions ranged from −1.6% to +5.4%.
Tiny sanitize-plus-restoration cases ranged from −2.0% to +3.5%, broadly
comparable to the small control variation. Process CPU measurements closely
track wall time. No inference of a small-case speedup is warranted.

The gain is a few microseconds per ordinary buffer, so its absolute player
impact is likely modest. This experiment supports reducing local validation
work; it does not establish an application-level percentage improvement.

All 55 rows, including mono helper coverage and every restoration control,
are in [the complete result table](../Benchmarks/PCMSanitization/evidence/linux-formal/results.md),
[the structured summary](../Benchmarks/PCMSanitization/evidence/linux-formal/summary.json),
and [the raw observations](../Benchmarks/PCMSanitization/evidence/linux-formal/measurements.jsonl).
The full [provenance report](../Benchmarks/PCMSanitization/evidence/linux-formal/report.json)
records source, compiler, harness, and binary identities.

### Native macOS qualification

[The native qualification workflow](https://github.com/Jagalite/illiquid/actions/runs/39055879742)
passed on an **Apple M1 virtual runner**, ARM64, three logical CPUs,
macOS 26.6.2 (25G83), and Apple Swift 6.3.3 from Xcode 26.6. It tested merge
commit `a178c2df8506ef464db518019bf2dc7bbadce237`, containing PR source head
`6322d2836a77a28fe4d4802706960714304d2832` and the pinned baseline.

The native cohort contains the same 55 cases, six balanced pairs, and 660 raw
observations. It also passes all four baseline/candidate debug/release suites
(32 test executions). Its 880 fixture records, counts, and 28,904,816 output
bytes match exactly. The complete native output receipt is byte-identical to
the retained Linux receipt, so both refer to the same compressed record file.

| Case | Baseline µs | Candidate µs | Wall reduction | Process CPU reduction |
| --- | ---: | ---: | ---: | ---: |
| `healthy_sine/1024x2` | 2.847 | 0.749 | +70.9% | +68.6% |
| `healthy_sine/1024x6` | 7.107 | 1.784 | +75.9% | +75.8% |
| `healthy_sine/1024x8` | 8.171 | 2.282 | +72.1% | +74.3% |
| `healthy_sine/4096x8` | 32.051 | 7.255 | +75.6% | +74.5% |
| `silence/1024x8` | 9.182 | 1.958 | +75.0% | +75.0% |
| `sparse_invalid/1024x8` | 8.579 | 3.158 | +69.9% | +70.1% |
| `shared_healthy/1024x8` | 9.421 | 3.707 | +58.8% | +59.4% |
| `dense_invalid/1024x8` | 22.400 | 22.858 | -10.4% | -7.5% |
| `subnormals/1024x8` | 30.585 | 32.100 | -9.1% | -11.2% |

Each of the four healthy player-layout cases improves in all six pairs in
both wall and CPU time. Signed-zero silence improves 72.2–75.0% in wall time;
sparse-invalid sanitation plus restoration improves 57.7–74.9%. Shared healthy
buffers, including COW, improve 16.4–60.9%, with the weakest gain in the largest
shared allocation. These ranges cover the stereo/surround layouts, excluding
mono helper coverage.

The hosted VM's unchanged controls are substantially noisier than the Linux
controls: their paired wall reductions span **−25.8% to +14.8%**, and CPU
reductions span **−23.0% to +11.7%**. Dense-invalid wall estimates range from
−17.0% to +8.7% across all five large sizes; all-subnormal estimates range from
−11.0% to +2.6%. Their CPU estimates range from −10.9% to +1.1% and −11.2% to
−5.4%, respectively. Those smaller apparent improvements should not be read
as demonstrated gains. The dense/subnormal tradeoff established by the more
stable Linux comparison remains relevant.

Mono has one healthy wall outlier with a candidate/baseline ratio of 1.346;
its six CPU ratios remain between 0.314 and 0.409. This is additional evidence
of scheduling noise and is retained in the full cohort. It does not affect
the all-pairs result for the four actual player-output layouts.

The native-audio job built `IlliquidNativePlayback`, `IlliquidApp`, the
`Illiquid` executable, and the package test executable, then reported **22
tests in four suites passed**. The resampler rate cases at 32,000, 44,100,
48,000, and 96,000 Hz and the six/eight-channel decoder cases ran successfully.
Three fixture-dependent session methods returned without exercising their
playback assertions, as qualified below. The initial workflow misnamed the
suite containing the older basic sanitizer test; that method is excluded from
this first-run 22-test count. The workflow now selects its unique method name
`audioSanitizationZerosInvalidSamplesOnly` for subsequent runs. The eight new
sanitizer tests were selected and passed in the initial run.

[All native rows](../Benchmarks/PCMSanitization/evidence/macos-component/results.md),
[raw timing records](../Benchmarks/PCMSanitization/evidence/macos-component/measurements.jsonl),
[component provenance](../Benchmarks/PCMSanitization/evidence/macos-component/qualification.json),
and [the native app/audio build log](../Benchmarks/PCMSanitization/evidence/macos-native-audio/job.log)
are checked in. The GitHub artifact's downloaded SHA-256 was verified before
extracting the retained evidence. These measurements exclude audible playback
and whole-player profiling.


## Validation

The new
[`AudioSampleSanitizationTests`](../Tests/IlliquidNativePlaybackTests/AudioSampleSanitizationTests.swift)
contains eight tests with an independent byte-oriented scalar oracle. It
covers exact IEEE boundary values and NaN payload families, every dirty lane,
counts around the eight-sample boundary, trailing bytes, nonzero Data indices,
unaligned externally owned storage, retained copies, idempotence, every
exponent with representative mantissas, and 65,536 deterministic raw bit
patterns. The oracle classifies each original word with the scalar Float
predicates and preserves all accepted bytes.

Local qualification with the final source and test files passed:

| Qualification | Result |
| --- | --- |
| Scalar baseline, debug | 8/8 tests passed |
| Scalar baseline, release | 8/8 tests passed |
| SIMD candidate, debug | 8/8 tests passed |
| SIMD candidate, release | 8/8 tests passed |
| SIMD candidate, release AddressSanitizer | 8/8 tests passed; exit zero; leak detection enabled |

The four ordinary runs total 32 test executions. The instrumented run adds
another eight. Full logs and source hashes are in
[the normal test evidence](../Benchmarks/PCMSanitization/evidence/linux-tests/report.json)
and [the AddressSanitizer evidence](../Benchmarks/PCMSanitization/evidence/linux-address-sanitizer/report.json).

The first instrumented attempt passed the PCM tests but failed overall when
the separately launched empty XCTest runner reported a 368-byte leak. This
standalone package contains only Swift Testing tests. Selecting those tests
with `--disable-xctest --enable-swift-testing` removed the unused runner, and
the repeat passed with leak detection still enabled and no `ASAN_OPTIONS`
override. The initial unsuccessful log and report remain in
[the evidence](../Benchmarks/PCMSanitization/evidence/linux-address-sanitizer-unused-xctest-failure/).
No production change was needed for that harness correction.


The dedicated
[`pcm-sanitization-performance.yml`](../.github/workflows/pcm-sanitization-performance.yml)
is configured to run the component comparison on macOS 26 with the repository's pinned
Xcode 26.6 toolchain. Its native-audio job prepares the existing pinned native
SDK, builds the app graph, and runs the new tests plus existing resampler-drain,
multichannel, audio-delay, and sanitizer regressions. The drain and multichannel
decoder tests create PCM packets in memory and exercise real FFmpeg conversion.
Two existing audio-delay session tests require `ILLIQUID_NATIVE_FIXTURE_DIR`.
The multichannel session test also checks `TestFixtures/Generated` when that
variable is absent. Without the required media fixtures these methods return
early, so this workflow does not claim that they exercised playback. There is
no noisy wall-time pass/fail threshold.

## Reproduction and evidence

From a checkout containing the pinned baseline commit and with a compatible
Swift toolchain on PATH:

```sh
python3 Benchmarks/PCMSanitization/run.py \
  --mode all --test-variant both --test-configuration both \
  --pairs 6 --target-ms 80 --output /tmp/illiquid-pcm-results

python3 Benchmarks/PCMSanitization/run.py \
  --mode test --test-variant candidate --test-configuration release \
  --sanitize address --output /tmp/illiquid-pcm-asan
```

See the [benchmark README](../Benchmarks/PCMSanitization/README.md) for output
formats, source extraction, optional toolchain selection, and controls. Checked-in
evidence contains raw measurements and complete summaries, compressed byte
receipts, extracted source snapshots, provenance, and test logs. Build caches
and executable binaries are omitted; their hashes and build commands are
retained so they can be reproduced.

The first exploratory run used the prototype's inherited typed binding; a
second pilot and all qualification runs use the final raw-access implementation.
Exploratory timing is not combined with the formal results. Another concurrent
PR already covered adaptive text opacity, so that earlier candidate selection
was abandoned before publication; this PR changes only the audio sanitizer.
