# Native output regression gate

This gate captures deterministic output artifacts from the same generated media
fixtures in two isolated source worktrees. It does not update a golden baseline
automatically. A baseline and candidate must use the same harness revision,
fixture hashes, Mac model, and macOS version.

The artifact test covers:

- normalized luma images and perceptual hashes from H.264, HDR10/P010,
  HLG/P010, and AV1 decode output;
- embedded SRT, embedded ASS with an attached font, external ASS, subtitle-off,
  and animated ASS raster output;
- one second of stereo 48 kHz float PCM produced by the AAC and multichannel
  FLAC demux/decode/resample paths.

Run one source tree with a dedicated scratch and artifact directory:

```sh
ILLIQUID_NATIVE_FIXTURE_DIR="$PWD/TestFixtures/Generated" \
ILLIQUID_OUTPUT_ARTIFACT_DIR=/absolute/path/to/artifacts \
ILLIQUID_OUTPUT_REQUIRE=1 \
ILLIQUID_OUTPUT_SOURCE_REVISION="$(git rev-parse HEAD)" \
ILLIQUID_OUTPUT_HARNESS_REVISION=<test-commit> \
swift test --scratch-path /absolute/path/to/build --no-parallel \
  --filter OutputRegressionArtifactTests
```

Compare isolated results:

```sh
python3 Benchmarks/OutputRegression/compare.py \
  --baseline /absolute/path/to/baseline/manifest.json \
  --candidate /absolute/path/to/candidate/manifest.json \
  --output /absolute/path/to/comparison.json
```

Or create two detached worktrees, copy the selected fixtures into each, use
independent SwiftPM scratch directories, apply only the committed test file to
both product revisions, and compare in one command:

```sh
Benchmarks/OutputRegression/run-isolated-comparison.sh \
  <baseline-product-commit> <candidate-product-commit> \
  /private/tmp/illiquid-output-comparison <harness-commit>
```

Exact hashes are the primary same-machine gate. Video luma additionally carries
an 8x8 average hash: an exact mismatch with Hamming distance at most two is
reported as a perceptual warning rather than a regression. Subtitle RGBA and
audio PCM are exact because both runs are required to use the same machine,
operating system, fixture bytes, embedded/system fonts, FFmpeg, and libass.

This is a pipeline-output gate, not a camera measurement of the physical
display or speakers. HDR display mapping, EDR activation, final
`AVSampleBufferDisplayLayer` composition, and acoustic device output remain
separate physical-device checks.
