# Video geometry metadata research

## Question

Can the decoder reuse the immutable pixel-aspect-ratio and clean-aperture
dictionaries instead of constructing and bridging both dictionaries for every
output frame?

The baseline is `7f9ba073394b77a908e0589447c6edc8d10b832c`. It calls the two
metadata methods from the common decoded-frame path and also applies aspect
metadata during planar output preparation. This experiment preserves those
calls and every `CVBufferSetAttachment` operation. It changes only how the
attachment values are prepared.

## Candidate and qualification plan

The prototype has one cached dictionary for each metadata kind, scoped to one
decoder. Every output buffer still receives its attachments. A changed key
rebuilds that dictionary; invalid aspect ratios retain the existing no-op
behavior. Clean-aperture offsets use their exact floating-point bit patterns
as keys, including the sign of zero.

Before integrating the candidate, run the actual original methods and the
candidate with real CoreVideo buffers on macOS. Require identical attachment
values and propagation modes, the same semantic tests in debug and release,
and balanced baseline/candidate timings. Preserve changing-geometry controls
and all individual observations. The intended acceptance signal is a
repeatable reduction in stable-geometry preparation, with control overhead
small enough to justify the bounded cache. A failed or inconclusive study does
not justify a production PR.

After integration, build the native application graph and run relevant real
decoder, planar-output, geometry, and timestamp-only tests. Keep the prototype
and integrated helper source byte-identical when attributing measurements.

## Reproduce

On macOS with the repository's supported Swift toolchain:

```sh
python3 Benchmarks/VideoGeometryMetadata/run.py \
  --output /tmp/illiquid-video-geometry --pairs 8 --target-ms 150
```

The standalone component runner uses CoreVideo directly and requires no
FFmpeg installation. Full decoder qualification uses the pinned native SDK
and fixtures in `.github/workflows/video-geometry-metadata.yml`.

## Scope

The component measurement includes attachment preparation and attachment
writes. It excludes decoding, scaling, renderer enqueue/presentation, UI
latency, energy, and the rest of video-frame preparation. It is not a measure
of whole-player CPU or frame rate. No result has yet been claimed.
