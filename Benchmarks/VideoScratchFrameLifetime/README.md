# Video decoder scratch-frame lifetime

This experiment compares the actual native `VideoDecoder` from baseline
`6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635` with the candidate. The candidate
unreferences its reusable FFmpeg `AVFrame` whenever `receiveFrames` exits.

## Question

Does cancellation or an output error leave the last decoded source allocation
retained by the decoder after its caller releases the input packet? Can that
reference be released immediately while preserving emitted output, intentional
thumbnail fallback references, and future decoder operation?

This is a bounded retention issue: one scratch frame per affected decoder.
Continuous successful decoding already clears that reference on its next
receive iteration.

## Reproduce on macOS

Use the repository's pinned native SDK and Xcode setup. The dedicated workflow
prepares these on an ephemeral `macos-26` runner using Xcode 26.6. It then runs:

```sh
python3 Benchmarks/FrameStepTimestamps/generate-fixtures.py \
  --output /tmp/video-scratch-fixtures

python3 Benchmarks/VideoScratchFrameLifetime/run.py \
  --fixtures /tmp/video-scratch-fixtures \
  --output /tmp/video-scratch-results \
  --pairs 4
```

Use a new results directory. The runner creates a detached baseline worktree
and separate release build directories there. It does not modify the source
checkout's production code. Fetch the pinned baseline commit if the checkout
is shallow. Building both complete application/test graphs requires the
macOS frameworks and native dependencies used by the player.

## What is measured

The test fixture allocates a padded raw BGRA packet using `av_mallocz` and
`av_buffer_create`. The real FFmpeg rawvideo decoder references that allocation
in the `AVFrame` returned to `VideoDecoder`. Its free callback records actual
deallocation; the probe retains no pointer or native buffer reference.

The identical test harness is compiled against both revisions. Four interrupted
paths are exercised at 64×48, 1920×1080, and 3840×2160:

- A full-frame output consumer throws.
- Cancellation is requested immediately after one output.
- Software-output admission refuses a buffer permit.
- A timestamp-only consumer throws.

The two successful-decode controls use 64×48 and 1920×1080, with 100 decodes
per process. Four alternating AB/BA pairs for fourteen cases produce 112
fresh-process observations, excluding the initial build probes.

At each interrupted boundary, the original input packet is destroyed while the
decoder and any emitted output remain alive. The harness records packet-buffer
reference counts, the source free callback, retained requested payload/storage
bytes, and release after `flush` and decoder destruction. It compares complete
active-pixel SHA-256 digests before flush, after flush, and after destruction,
along with timestamps, generation, dimensions, pixel format, and output counts.

`payload_bytes` is width × height × 4. `storage_bytes` is the number of bytes
requested from `av_mallocz`, including FFmpeg's required zero padding. These
are not measurements of allocator overhead, RSS, physical footprint, codec
reference pictures, output pools, filter history, renderer queues, or total
player memory. The destructor proves release of the specifically tracked native
allocation. Other owners can legitimately retain backing data in real codecs.

Decode timing excludes fixture construction, hashing, and flush/destruction.
It includes the output callback and the measured decoder's first output-pool
creation, amortized over 100 calls in the normal controls. A separate decoder
warms framework/conversion code before each observation. No timing threshold
is enforced; these controls check for an apparent component cost, not a
whole-player speed improvement.

## Correctness gates

The runner rejects missing or incorrect observations, mismatched output,
unexpected reference counts, missing/double destruction, changed selected
source files or test binaries, and comparisons with other production-source
changes. It runs the focused scratch-lifetime regression suite and the
required timestamp/deinterlacing fixtures using the candidate release build.

Regression coverage includes output kept across error/reuse/flush/destruction,
repeated cancellation, retained thumbnail fallback clones, delayed H.264 output,
throwing EOF drain, B-frame timing, BWDIF interlacing, and decoder reuse.

Initial qualification runs on the research branch
`perf/video-scratch-frame-lifetime-20261023`. Once the dedicated workflow is on
the default branch, subsequent reproductions use its manual `workflow_dispatch`
trigger and required
`candidate_ref` input, which checks out the explicitly selected candidate commit
(currently `40b8cae2651e643491f82af34f1c4b608e1cbc62`). This frozen differential
rejects unrelated production-source changes; it does not rerun automatically
for documentation updates or PR merge commits containing newer main changes.
The frame-step timestamp workflow provides automatic native regression coverage
on relevant PRs, including the scratch-lifetime suite and real timestamp and
deinterlacing fixtures. A selected candidate commit is not qualified until the
native evidence satisfies the success requirements below.

## Evidence

The runner produces `environment.json`, `sources.json`, `binaries.json`,
`fixtures.json`, `observations.jsonl`, `summary.json`, `regressions.json`,
`commands.json`, and `completion.json`, plus command logs and source receipts.
The workflow uploads these and emits a SHA-256-identified compressed evidence
bundle in its logs. A result is qualified only when `completion.json` reports
success and both native regression suites ran with nonzero test counts.

The [native run](https://github.com/Jagalite/illiquid/actions/runs/40101088087)
qualified commit `40b8cae2651e643491f82af34f1c4b608e1cbc62`: 112 observations,
56 paired output comparisons, and both regression suites passed. The four
interrupted paths released the tracked allocation promptly in the candidate;
both normal controls retained zero tracked source bytes in both revisions.

See the [research report](../../Documentation/VIDEO_SCRATCH_FRAME_LIFETIME.md)
for the exact byte counts, timing results, limits, and overlap with PR #100.
[Committed native receipts](evidence/native/) include the raw observations,
source and environment hashes, regression logs, and the unchanged full evidence
bundle. `full-evidence.json.gz` is a gzip-compressed JSON object mapping relative
paths to their original text; `provenance.json` records its SHA-256 and workflow.
The checked-in evidence remains available after the temporary CI artifact expires.
