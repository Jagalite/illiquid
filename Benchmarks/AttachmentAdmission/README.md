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

Pinned FFmpeg 8.1.2's `libavformat/matroskadec.c` routes recognized image MIME
types through `ff_add_attached_pic`; normal PNG/JPEG covers therefore become
video streams rather than `AVMEDIA_TYPE_ATTACHMENT`. They are an unaffected
control in this study. Font-only media and media without attachments are also
controls.

The study measures metadata projection and complete demuxer open/probe/close
with a warm filesystem cache. It does not measure time to first displayed
frame, cold storage, sustained playback CPU, FPS, or font rendering. The
generated font/PDF-labeled payloads contain deterministic arbitrary bytes;
they exercise attachment admission and copying, not font/PDF validity. The PNG
control is an actual encoded image. Container UIDs can vary between generation
runs; each run records the exact fixture hashes it used.

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
The baseline is pinned to `7f9ba073394b77a908e0589447c6edc8d10b832c`.
The benchmark compiles the actual old/new demuxer source against the same
native FFmpeg libraries, compares returned metadata and font byte hashes, and
uses alternating baseline/candidate processes with equal iteration counts.

To audit saved receipts without a macOS runtime, use a checkout containing the
two measured commits:

```sh
python3 Benchmarks/AttachmentAdmission/audit-results.py \
  --results Benchmarks/AttachmentAdmission/evidence/initial --repo .
```

The audit independently recomputes the measurements and output parity and
reconstructs production/compiled-source hashes from pinned Git revisions.
It explicitly lists omitted native binaries, dependencies, and fixture bytes;
recording their hashes does not independently revalidate their contents.

## Initial native study and confirmation protocol

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
longer run will resolve the specific uncertainty in the adverse/noisy controls;
both complete studies will be reported.
