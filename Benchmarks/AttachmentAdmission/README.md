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
  --fixtures /tmp/attachment-fixtures --output /tmp/attachment-results --pairs 6
ILLIQUID_ATTACHMENT_ADMISSION_FIXTURE=/tmp/attachment-fixtures/attachment-admission.mkv \
  swift test --force-resolved-versions -c release --jobs 2 --no-parallel \
  --filter 'FontAttachmentAdmissionTests|NativePlaybackFoundationTests'
```

Both output directories must be new or empty as specified by their runner.
The baseline is pinned to `7f9ba073394b77a908e0589447c6edc8d10b832c`.
The benchmark compiles the actual old/new demuxer source against the same
native FFmpeg libraries, compares returned metadata and font byte hashes, and
uses alternating baseline/candidate processes with equal iteration counts.

## Qualification status

Native results and their source, fixture, output, and timing receipts will be
recorded here after qualification. Local checks on the Linux research host
cover Python/workflow syntax and fixture generation only; they are not macOS
application performance results.
