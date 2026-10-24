# Font attachment admission

`FFmpegDemuxer.makeMediaInfo` previously copied every positive-length
`AVMEDIA_TYPE_ATTACHMENT` payload into Swift `Data`, retained those copies in an
array, and then removed entries whose filename/MIME did not identify a font.
The candidate evaluates the same metadata predicate before copying. Every
stream still appears in `FFmpegMediaInfo.streams`; accepted fonts retain their
original names, MIME values, bytes, order, and owned storage.

This removes an additional Swift copy of unsupported embedded extras such as
PDF-labeled or generic binary attachments. FFmpeg still reads and owns the
container's attachment bytes. The existing font count and byte limits are
unchanged.

## Scope

Pinned FFmpeg 8.1.2's [image MIME mapping](https://github.com/FFmpeg/FFmpeg/blob/38b88335f99e76ed89ff3c93f877fdefce736c13/libavformat/matroskadec.c#L816-L823)
and [Matroska attachment dispatch](https://github.com/FFmpeg/FFmpeg/blob/38b88335f99e76ed89ff3c93f877fdefce736c13/libavformat/matroskadec.c#L3427-L3445)
route correctly tagged PNG/JPEG covers through `ff_add_attached_pic`. The
[helper marks them as attached-picture video streams](https://github.com/FFmpeg/FFmpeg/blob/38b88335f99e76ed89ff3c93f877fdefce736c13/libavformat/demux_utils.c#L107-L135),
so they do not enter the `AVMEDIA_TYPE_ATTACHMENT` branch changed here. The
real PNG fixture is an unaffected control. Font-only media and media without
attachments are also controls.

The study measures metadata projection and complete demuxer open/probe/close
with a warm filesystem cache. It does not measure time to first displayed
frame, cold storage, sustained playback CPU, FPS, or font rendering. The
generated font/PDF-labeled payloads contain deterministic arbitrary bytes;
they exercise attachment admission and copying, not font/PDF validity. The PNG
control is an actual encoded image. Container UIDs can vary between generation
runs; each run records the exact fixture hashes it used.

## Confirmed native results

The fixed longer confirmation, [benchmark job 120064479401](https://github.com/Jagalite/illiquid/actions/runs/39847482020/job/120064479401),
completed on `d3fcfe25c9933a17c9dee0506d67d8231cb00323` on October 22, 2026.
The four fixtures with rejected payloads showed **28–34% less warm-cache
full demuxer setup-cycle time**, with every one of their 48 wall-time pairs and
48 CPU-time pairs favoring the candidate. The three setup controls ranged from
−0.51% to +0.47% paired time change. Peak process memory did not improve.

Both studies used native arm64 macOS hosted VMs: Apple M1 (Virtual), 3 cores,
7 GB RAM, macOS 26.6.2, Xcode 26.6 / Swift 6.3.3, macOS SDK 26.5, and the
repository's pinned FFmpeg 8.1.2 SDK. These are hosted-VM component results,
not measurements on a physical user machine or a representative media corpus.

### Full demuxer setup cycle

This includes actual open, probe, metadata construction, and close, with a warm
filesystem cache. Each row contains 12 alternating baseline/candidate pairs.

| Fixture | Baseline ms | Candidate ms | Paired wall change | Paired CPU change | Faster wall pairs |
|---|---:|---:|---:|---:|---:|
| No attachments (control) | 0.080 | 0.081 | +0.47% | +0.18% | 5/12 |
| 2 MiB accepted font (control) | 0.943 | 0.939 | -0.51% | -0.48% | 7/12 |
| 1 MiB rejected | 0.622 | 0.436 | -31.15% | -33.50% | 12/12 |
| 16 MiB rejected | 10.034 | 7.152 | -28.83% | -29.52% | 12/12 |
| 64 MiB rejected (stress) | 40.371 | 27.132 | -33.55% | -33.50% | 12/12 |
| 16 MiB rejected + 128 KiB font | 10.183 | 7.319 | -28.45% | -28.46% | 12/12 |
| PNG cover (control) | 0.102 | 0.102 | +0.21% | +0.18% | 5/12 |

Absolute times are separate per-variant medians. Percentage changes are the
median of the paired ratios, not the ratio of those two medians. Negative
changes mean less time. All four affected fixtures also favored the candidate
in 12/12 CPU-time pairs. The setup controls support a near-neutral result;
no speedup is attributed to them.

### Metadata projection alone

| Fixture | Baseline µs | Candidate µs | Paired wall change | Faster wall pairs |
|---|---:|---:|---:|---:|
| No attachments (control) | 0.619 | 0.631 | +1.82% | 3/12 |
| 2 MiB accepted font (control) | 148.948 | 148.818 | -0.08% | 6/12 |
| 1 MiB rejected | 182.172 | 18.276 | -89.76% | 12/12 |
| 16 MiB rejected | 20.452 | 17.959 | -14.04% | 10/12 |
| 64 MiB rejected (stress) | 20.627 | 17.450 | -16.44% | 12/12 |
| 16 MiB rejected + 128 KiB font | 55.565 | 56.138 | -0.75% | 6/12 |
| PNG cover (control) | 1.082 | 1.063 | -2.02% | 10/12 |

The mixed fixture is approximately neutral in this mode (6/12 pairs favor the
candidate). Projection gains are not monotonic with payload size and should
not be extrapolated from the 1 MiB case. The no-attachment projection control
was +1.82%, approximately 0.012 µs per operation; PNG projection was −2.02%.
These small control changes are retained without assigning them a causal benefit.

### Memory and observation duration

Full-setup process peak RSS was approximately unchanged. Repeated projection
peaks were higher by 2.33 MiB, 2.31 MiB, and 2.56 MiB for the 16 MiB, 64 MiB,
and mixed cases respectively. This study supports avoiding work during demuxer
setup; it **does not demonstrate lower peak process memory**.

All 432 confirmation observations matched exactly: 336 timed observations and
96 calibration observations. Measured intervals ranged from 236.14 ms to
2,991.83 ms, with no samples below 5 ms. The no-attachment projection
calibration narrowly missed its 250 ms target; the actual observations were
still longer than 236 ms. No observations were removed.

Raw results and independent audit output are retained in
[`evidence/confirmation`](evidence/confirmation). Production and compiled
source hashes, compiler hash, native library/header hashes, harness, and runner
are identical to the initial study. The only measurement change was the
predefined longer sampling protocol.

## Measurement method

The baseline is pinned to `7f9ba073394b77a908e0589447c6edc8d10b832c`. Each
variant compiles the complete production demuxer and its dependencies against
the same pinned native FFmpeg libraries. The only change to the demuxer for
measurement removes `private` from `makeMediaInfo`; the runner verifies that
reversing that access change restores the exact source. Required presentation
error and bitmap packet declarations are extracted verbatim. Source, compiler,
SDK, header, library, harness, and executable receipts accompany the results.

`projection` repeatedly calls the actual metadata method on a real, opened and
probed `AVFormatContext`. `setup` repeatedly constructs and destroys the actual
`FFmpegDemuxer`, including open, probe, metadata construction, and close. Each
observation starts a fresh process and performs warm-up before timing. The
production code is in a separate optimized module; a non-inlined checksum
consumes every timed result. Complete returned metadata and accepted payload
SHA-256 hashes are checked outside the timed region, including exact floating
point bit patterns.

Baseline/candidate pairs use equal iteration counts and alternate AB/BA order.
Times are normalized per operation before taking each variant's median.
The paired change is the median of `100 * (candidate / baseline - 1)` within
pairs, so it need not equal the percentage change between the two displayed
medians. Negative changes mean less time. All calibration and measured
observations are retained, including adverse controls and short samples.

Wall time and process CPU time cover only the timed loop. Darwin `ru_maxrss`
is reported in bytes as a **process-lifetime peak**, including initial probing
and warm-up, without dividing by iterations or subtracting the earlier peak.
It is not an incremental allocation count or a measurement of steady playback
memory. The sources prove that an owning `Data` construction is avoided for
each rejected payload; they do not establish an equal reduction in physical
memory use.

## Reproduce on Apple Silicon macOS

Use the repository's pinned FFmpeg SDK and the compiler selected by
`.github/workflows/attachment-admission.yml`. The workflow validates the SDK
and corresponding source before installing it on an ephemeral runner.

```sh
python3 Benchmarks/AttachmentAdmission/generate-fixtures.py --output /tmp/attachment-fixtures
python3 Benchmarks/AttachmentAdmission/run.py \
  --fixtures /tmp/attachment-fixtures --output /tmp/attachment-results \
  --pairs 12 --target-ms 250 --max-iterations 1000000
ILLIQUID_ATTACHMENT_ADMISSION_FIXTURE=/tmp/attachment-fixtures/attachment-admission.mkv \
  swift test --force-resolved-versions -c release --jobs 2 --no-parallel \
  --filter 'FontAttachmentAdmissionTests|NativePlaybackFoundationTests'
```

Both output directories must be new or empty as specified by their runner.
The current runner also permits the executor's default-enabled font-inclusion
option to differ from the historical baseline. This benchmark continues to use
the default font-inclusive behavior and requires the same complete metadata and
payload hashes from both versions. Auxiliary readers' opt-out is measured
separately in [`../AuxiliaryFontAttachments`](../AuxiliaryFontAttachments).
All generated containers have a 0.25-second stereo FLAC audio track. Attachment
payloads are dense deterministic repetitions of bytes 0 through 255, except for
the real encoded PNG control and the small native integration fixture.

To audit saved receipts without a macOS runtime, use a checkout containing the
two measured commits:

```sh
python3 Benchmarks/AttachmentAdmission/audit-results.py \
  --results Benchmarks/AttachmentAdmission/evidence/confirmation --repo .
```

The audit independently recomputes the measurements and output parity and
reconstructs production/compiled-source hashes from pinned Git revisions.
It explicitly lists omitted native binaries, dependencies, and fixture bytes;
recording their hashes does not independently revalidate their contents.

## Native regression qualification

The release application graph built successfully in
[run 39846074333](https://github.com/Jagalite/illiquid/actions/runs/39846074333).
Swift Testing reported **65 tests in 6 suites passed**. The new native fixture
integration test executed (it was not skipped): one rejected attachment and two
accepted fonts retained all three attachment stream entries, preserved font
names/MIME/order/bytes, allowed reading the audio packet, and kept font bytes
valid after demuxer destruction. Two parameterized classifier tests cover nine
accepted and nine rejected metadata combinations. Existing font detection and
aggregate-byte-limit tests also passed.

The original host receipt and native test log are retained in
`evidence/native-regressions`, with artifact and relevant source hashes. That
qualification used candidate `50c1265a5ca53f5d1a7e092369090f42c221dec8`; the
production files, tests, and fixture generator are unchanged in the confirmation
commit.

## Initial study and the confirmation decision

The first complete native benchmark, [run 39846074333](https://github.com/Jagalite/illiquid/actions/runs/39846074333),
used six alternating pairs per fixture/mode and a 10 ms calibration target.
All 252 output receipts (168 measured plus 84 calibration observations) matched
exactly. Full warm-cache demuxer setup favored the candidate in all six pairs
for each of the four fixtures with rejected payloads; paired median reductions
were 32.72%, 44.63%, 49.65%, and 37.46% for the 1 MiB, 16 MiB, 64 MiB, and mixed
fixtures respectively.

The controls prevent treating that first run as conclusive: font-only metadata
projection was 10.90% slower, PNG-cover setup was 29.76% slower, and the
no-attachment setup control appeared 37.16% faster despite no expected payload
benefit. Process peak RSS did not improve; large repeated-projection cases
were approximately 2.1–2.4 MiB higher. These observations are retained in
`evidence/initial`.

Before viewing a second run, the confirmation protocol was fixed at all seven
fixtures, both modes, 12 alternating pairs, a 250 ms target, a 5,000 ms
estimated slower-side cap, and a 1,000,000 iteration cap. Production code,
fixture generation, harness, and benchmark runner remain unchanged. This
longer run addressed the specific uncertainty in the adverse/noisy controls.
Its setup controls settled near zero, and all affected setup cases repeated
the improvement. Both complete studies are retained; the confirmation's
28–34% setup reduction is the principal finding, rather than the larger
percentages from the initial short samples.
