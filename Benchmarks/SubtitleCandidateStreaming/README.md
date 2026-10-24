# Streaming external-subtitle match candidates

This component experiment compares two temporary arrays in the original
`ExternalSubtitleMatcher` with a streaming candidate visitor and direct indexed
mutation of existing dictionary values during final subtitle sorting. The
candidate removes both the collected candidate IDs and `Array(result.keys)`.
Both variants
compile the **complete, unmodified production matcher**, `MediaFileSupport`
and `NaturalFilenameOrdering` into a separate optimized `IlliquidCore` module.
There are no private-access edits, allocator hooks in production, or model
implementations of the matching algorithm.

## Reproduction

Requirements: Swift 6.1+, Python 3, and either macOS or Linux with glibc 2.33+.
No package dependencies are fetched. Follow repository build coordination
instructions, and avoid concurrent builds/tests during formal timing.

```sh
python3 Benchmarks/SubtitleCandidateStreaming/run.py \
  --output /tmp/illiquid-subtitle-candidate-streaming \
  --sizes 64,512,4096,32768 --pairs 6 --target-ms 100
```

Short build and parity smoke, with insufficient timing samples for performance
conclusions:

```sh
python3 Benchmarks/SubtitleCandidateStreaming/run.py \
  --output /tmp/illiquid-subtitle-candidate-smoke \
  --sizes 64,512 --pairs 2 --iterations 1
```

`--swift` selects the toolchain; preserve the `swift` executable symlink name.
`--cpu` optionally selects one available Linux CPU. `--prepare-only` only
stages/builds, and `--verify-only` adds full association verification without
measurement. `--memory-only` verifies outputs and samples memory without timing
or calibration processes. `--baseline-dir` accepts preserved baseline files from an earlier
run when Git history is shallow; every file must match its pinned SHA-256.

## Workloads and correctness

The baseline is main at `4abf4b44f13386ccd04f1ce4ad0e756255ca4d14`. The two support
files must remain byte-identical between variants. Every compiled production
file and common harness source is preserved with its SHA-256 and Git blob hash.
The runner records host/compiler details, build commands, binary hashes and
all raw observations.

Each size contains uniquely numbered `Shared.Series.Episode…` media filenames:

- **Broad:** one `Shared.Series.en.srt` subtitle visits the broad matching
  subtree. All scores tie, so no subtitle is associated.
- **Dense:** distinct `Shared.Series.00000000p.x265.mkv` media names lose their
  resolution/codec qualifiers and share one terminal node. The generic subtitle
  ties again; this controls for the different pending-stack and terminal-array
  behavior compared with a wide descendant subtree.
- **Exact:** three language subtitles match the middle media file. Reversed
  inputs must produce the expected ordered subtitle array.
- **Unrelated:** one subtitle has no matching token prefix.
- **Empty:** no subtitles; the established empty-inventory path remains active.

A fixture oracle verifies every original media key, subtitle URL and subtitle
ordering without using the production scoring or normalization functions.
Separate fresh verification processes serialize the full associations; their
canonical records must be byte-identical across variants and are retained as
compressed JSON. Each measurement also validates the complete result and emits
a deterministic digest. Memory pairs require identical cancellation-poll
counts, while dedicated regression tests qualify cancellation outcomes.

## Memory measurement

Memory and timing are independent experiments. Every observation starts a new
process. A tiny real association warms runtime paths and the sampling callback.
Input URL arrays are constructed before the initial reading and held alive
through the experiment. A callback passed through the public `isCancelled`
parameter samples allocator-accounted live storage at **every cancellation
poll** and always returns false. A final reading occurs after `associate`
returns, with its output still alive. Result verification and JSON construction
occur only after all readings.

The primary metric is the largest sampled live-byte reading minus the initial
reading. The post-return growth, cancellation-poll count and index of the
largest callback sample are reported too.
The maximum includes the post-return reading; `maximumSamplePoll` identifies
the largest **callback** sample specifically, even if the post-return reading
is larger.

- Linux: `mallinfo2().uordblks + mallinfo2().hblkhd`, including mmap allocations.
- macOS: `malloc_zone_statistics(NULL, …).size_in_use`.

**This is a sampled allocator high watermark, not the true every-allocation
peak.** Short allocations wholly between cancellation polls can be missed.
Allocator rounding, caches and runtime activity can affect readings. The
measurement covers the complete association call, including its index and
output dictionary; it is not an exact object-size calculation, process RSS,
whole-player footprint, or accumulating-leak claim.

The removed arrays are transient. Large broad-prefix inputs exercise candidate
collection; exact and no-match inputs still exercise final result sorting.
Empty-subtitle inputs bypass both affected stages and serve as an unchanged
control. Do not infer a uniform reduction across ordinary directories from
stress-query results.

## Independent timings

Timing processes do not sample heap statistics. They use a constant-false
cancellation callback in both variants and perform two warmup associations.
The measured loop includes complete association, result-count consumption and
result destruction. Input setup, full validation and JSON encoding are outside
the bracket. Monotonic wall and process CPU clocks are recorded.

Fresh calibration processes choose one equal iteration count per workload,
targeting the requested **process CPU** duration for the faster pilot, so both
variants aim to perform at least that much CPU work. Subsequent fresh-process
observations run in sequential balanced AB/BA pairs. Results retain medians,
minima, maxima and paired percentage changes; no timing threshold is hidden in
the runner. Report regressions or noisy controls explicitly. These timings do
not establish whole-player playback, UI or filesystem responsiveness.
