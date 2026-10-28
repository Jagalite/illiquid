# Video format-description reuse

## Research question

The video presenter at main commit
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72` creates a new
`CMVideoFormatDescription` for every frame. This experiment retains one
description and reuses it only when Core Media's native matcher accepts the
current image buffer. The matcher runs even when a buffer object is reused;
pixel-buffer identity alone is not a format or metadata key.

The cache is protected by its own lock, replaces its entry only after successful
creation, and resets when the presenter flushes. No image buffer is stored in the
cache. Sample timing, ownership tokens, renderer enqueue, and error handling stay
on their existing paths.

## Reproduce

When Kyoto is available, submit the complete runner through the shared queue:

```sh
python3 /Volumes/seed1/Projects/kyoto/kyoto.py submit -- \
  python3 Benchmarks/VideoFormatDescription/run.py --mode all --pairs 10 \
  --target-ms 100 --output /tmp/illiquid-video-format-description
```

Inspect the submitted job's status and logs before reporting results. When Kyoto
is unavailable, disclose that limitation and run the same runner directly.
Builds within the runner are serialized. The output directory must be new or
empty and outside the clean checkout.

The GitHub Actions workflow uses hosted `macos-26` with Xcode 26.6 and checks
that Kyoto is unavailable before direct builds.

## Method and scope

The runner verifies the frozen presenter's Git blob and the unchanged signpost
source against the pinned revision. It extracts the original native format
creation, sample creation, and error-handling blocks. The candidate's presenter
must reverse exactly to the baseline after removing the cache integration.
Both generated adapters therefore use the same original native operations.

The baseline always invokes that original factory. The candidate invokes the
actual production cache and the same factory on misses. The same production
signposts run in both; a cache hit avoids a creation signpost along with the
creation itself.

Adapters are separate dynamic modules compiled with `-O`,
`-whole-module-optimization`, and Swift 6. The driver is compiled separately,
without cross-module optimization. Each process validates 240 native output
descriptions against fresh CoreMedia descriptions, then warms up and measures.
Sample workloads additionally check image identity, readiness, sample count,
and exact timestamps/durations.

Ten workloads cover stable BGRA, NV12 SDR, and P010 HDR; rotating equal-format
buffers; dimension changes every 60 frames; matrix changes on a reused buffer;
and an every-frame metadata-change control. Three workloads include actual
sample-buffer construction. Each call processes 120 frames, so per-frame
figures divide call time by 120.

Ten fresh-process pairs alternate AB/BA order. Baseline calibration determines
one shared iteration count. Raw observations, source/binary/compiler hashes,
commands, and test logs are retained. The cache tests run in debug and release;
the second CI job builds the complete app graph with pinned native dependencies
and runs the cache plus existing geometry and color-sampling regressions.

These are metadata and sample-construction measurements. They do not measure
decoder throughput, display FPS, dropped frames, playback battery use, or live
HDR presentation. The every-frame-change control quantifies matcher overhead
when reuse is impossible.

## Native contract

Apple documents [the matcher](https://developer.apple.com/documentation/coremedia/cmvideoformatdescriptionmatchesimagebuffer%28_%3Aimagebuffer%3A%29)
and [image-buffer format creation](https://developer.apple.com/documentation/coremedia/cmvideoformatdescriptioncreateforimagebuffer%28allocator%3Aimagebuffer%3Aformatdescriptionout%3A%29)
as using the common image-buffer extension keys and applicable bytes-per-row
information. Tests compare cached descriptions to fresh native descriptions
through changes in format, size, stride, color metadata, clean aperture, aspect
ratio, HDR payloads, and attachment removal. They also cover creation failures,
reset, sample timing, and concurrent requests/resets.

## Results

Pending native execution. This branch is an isolated experiment; the measured
outcome determines whether a PR is opened.
