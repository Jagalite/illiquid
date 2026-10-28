# Libass position-only mask reuse

Libass distinguishes changed positions (1) from changed content (2). The
production renderer already skips bitmap copies for unchanged output (0), but
previously copied every admitted mask for both kinds of changed output. This
experiment reuses Swift-owned masks for position-only changes while rebuilding
their current geometry.

The contract is documented in [libass 0.17.5 ass.h](https://github.com/libass/libass/blob/0.17.5/libass/ass.h).
Its [change detector](https://github.com/libass/libass/blob/0.17.5/libass/ass_render.c)
compares the ordered image list, bitmap pointers, dimensions, stride and color;
position-only changes preserve those properties.

## Ownership and invalidation

An opaque immutable snapshot belongs to the caller. It carries its owned regions,
a per-context identity, a render sequence, and the admission limits. Reuse
requires the immediately preceding render, matching limits and every admitted
region's layout and color. A stale, missing, foreign or incompatible snapshot
uses the existing full-copy path. Source replacement, reset, actual geometry
changes and invalid render requests retire the previous token.

The context stores only token metadata. A snapshot does not retain the context,
native ASS_Image pointers, or libass caches. SubtitlePipeline shares its existing
region-array storage with the cached snapshot and clears both together.
Unchanged native renders retag a valid snapshot; viewport translation preserves
mask identity and always uses the new native frame coordinates on a later move.

Image-count and bitmap-byte admission remain deterministic. The full native
list is validated before any copies or mask sharing. The byte accounting still
describes the complete admitted output; bitmapCopies counts actual copies.

## Reproduce

Requires macOS, Swift 6.1+, Python 3.10+, and libass. The CI workflow installs the
repository's checksum-verified native SDK, including libass 0.17.5. On a local
host, supply a compatible installation with --libass-prefix if needed, and
follow the root AGENTS.md Kyoto build-coordination instructions.

    python3 Benchmarks/LibassPositionReuse/run.py --mode all \
      --pairs 8 --target-ms 100 --max-sample-ms 1500 \
      --output /tmp/illiquid-libass-position-reuse

Use a new empty output directory for every attempt. --mode tests runs regression
tests only; --mode measure runs the paired experiment only.

The baseline is the exact complete production sources at main commit
ea2ff568237e2667f7b1aeee67b11a44ebe95b72. Both variants compile LibassContext,
ASSBitmapCopy, SubtitleMemoryBudget and FontAttachmentStore without changes.
The exact PresentationError declaration is extracted with checked boundaries;
only its Foundation import is supplied. Real CoreGraphics, CryptoKit, Data,
locks and libass are used. There are no behavioral substitutes.

Production code is built as a separate optimized module with -O and
-whole-module-optimization. The driver accesses its existing internal API through
@testable import. The same driver source is compiled for both variants;
POSITION_REUSE only supplies and retains the candidate's snapshot.

## Workloads and verification

Six 64-frame workloads cover a short moving caption at 1080p, fourteen moving
lines at 4K, the same dense scene with an eight-image admission limit, static
dense text, changing text, and fractional motion. The integer-motion fixtures
deliberately isolate position-only updates. The fractional control records the
actual mixture of native change classifications.

Before timing, every complete output is compared with a separate full-copy
libass context: all mask bytes, colors, frames, strides and layout metadata.
Verification includes repeated timestamps, backward queries and expired events.
Paired runs must also match input hashes, complete verification digests,
warmup and timed checksums, final full-output digests, native change counts and
admitted byte counts. Copy counts are expected to differ.

Each timed process warms one full sweep, then renders repeated sweeps. Eight
fresh-process pairs alternate baseline/candidate order with identical iteration
counts and fixture seeds. Calibration targets 100 ms for the faster variant,
capping estimated slow-variant samples at 1.5 seconds; actual durations are
retained. No samples are discarded or control times subtracted.

Primary timing covers the full production render call and identical driver
output consumption, including candidate validation and ownership overhead.
Process CPU time is also recorded. The internal copyNanoseconds diagnostic
excludes the preceding admission/validation pass and must not be treated as
the complete speedup.

Existing compact-copy regressions run against both implementations in debug
and release. Candidate tests cover position/content/empty output, unchanged
retagging, stale/foreign/missing tokens, admission changes, reset/reload/geometry,
viewport offsets and caller-owned payload lifetime. A separate native job builds
the app graph and runs subtitle lifetime, staging and seek integration tests.

## Interpretation

Results are pending native execution. The hypothesis is reduced allocations and
mask copies during position-only animation. These are warm component workloads;
they do not measure live playback occupancy, GPU work, compositing, frame rate,
whole-player CPU, resident memory or energy. Static subtitles already avoid
copies and may show overhead. Retain controls and adverse timings alongside
favorable results before deciding whether to open a PR.
