# Thumbnail playlist neighborhood research

The background thumbnail scheduler needs at most four videos on either side of
the first occurrence of its current URL. Previously, each pass first projected
the entire playlist into a temporary URL array, even with no current URL.
The candidate searches the existing playlist and returns only the bounded
neighbor URLs and their distance dictionary.

This removes an O(n) temporary URL projection. It does not introduce an index,
cache, filesystem operation, or change to URL normalization. A middle, last, or
missing selection still requires a linear search. First-duplicate anchoring,
playlist order, duplicate URLs in the output, and the last duplicate's dictionary
distance are preserved.

## Run

On a machine with the shared Kyoto queue, submit the entire runner:

    python3 /Volumes/seed1/Projects/kyoto/kyoto.py submit -- \
      python3 Benchmarks/ThumbnailPlaylistNeighborhood/run.py \
      --output /tmp/thumbnail-neighborhood --pairs 8 --target-ms 30

Inspect Kyoto's job status and logs before reporting results. When Kyoto is
unavailable, explain that limitation and run the Python command directly.
The output directory must be new or empty. The runner requires native macOS,
the macOS 26 SDK, Swift 6, and Python 3. It serializes all builds and tests.

The matching GitHub Actions workflow uses macos-26 and Xcode 26.6, following the
repository's existing native workflows. It also builds the complete app/test
graph with pinned native dependencies and runs the new neighborhood tests plus
the existing thumbnail scheduler and lifecycle suites. Fixture-dependent tests
in those existing suites require their documented environment variables; a
default CI run does not exercise actual video decoding or visible playback.

## Correctness

The runner extracts the original neighbor and distance blocks from
ThumbnailBackgroundScheduler.swift at
ea2ff568237e2667f7b1aeee67b11a44ebe95b72. It changes only the input expression and
the surrounding type/function needed to call those blocks independently. The
candidate is the complete production ThumbnailPlaylistNeighborhood.swift file.

Both variants compile with identical, current production FolderPlaylist,
NormalizedFileURL, and NaturalFilenameOrdering sources. Test packages also include
current ThumbnailPolicy; the timed core/probe sources remain unchanged. The same
eleven repository
test functions execute in debug and release for each variant. These include
an independent integer-label oracle covering 1,093 small playlists and five
selection cases each (5,465 neighborhood comparisons), explicit duplicate
rules, edge clipping, decoded raw URLs, and a 10,000-item playlist.

The separately compiled release probes also compare 40 complete output traces.
Each measured pair must have identical result digests and per-call witnesses.
There are no timing thresholds in the correctness tests.

## Measurement

There are 19 workloads: empty/nil and singleton/first controls; first, middle,
last, missing, and nil selection for 32, 10,000, and 100,000 items; and middle/last
selection for 1,000 items. Each workload has eight alternating baseline-first
and candidate-first pairs, for 304 retained observations. Each observation
starts a fresh process. Input construction and one checked warmup are outside
the timed interval.

The production helper and an identical public probe are compiled into separate
optimized dynamic modules. The driver is compiled separately, without
cross-module optimization or an inlinable probe body, so its unchanged inputs
cannot cause calls to be replaced by a precomputed result. Every return
contributes to a checked witness; the final full result is also verified.

Calibration chooses an iteration count separately for each variant, then holds
it fixed across all measured pairs. This allows the constant-time nil/early-hit
candidate to have a meaningful timing interval without making the baseline run
for thousands of times longer. Each calibration observation is retained.
The target is 30 ms, with a one-million-iteration cap. Summaries flag observations
shorter than 10 ms. No timing sample is discarded.

Wall and process CPU timings include result consumption and autorelease-pool
cleanup. They measure neighbor planning, not the whole scheduler, thumbnail
decoding, UI responsiveness, energy, or video playback. The output reports
MemoryLayout<URL>.stride to describe the eliminated n-element array's nominal
element payload. It does not measure allocation counts, peak RSS, or an
equivalent reduction in total player memory.

## Evidence

The output retains source snapshots and hashes, compiler/host metadata, all
command logs, four test results, complete parity traces, calibration records,
all measured samples, and per-workload summaries. Structured log records also
allow the compact evidence to be preserved in the repository after CI finishes.

The final measured findings and any limitations belong in
Documentation/THUMBNAIL_PLAYLIST_NEIGHBORHOOD_PERFORMANCE.md after successful
execution. Until then, this directory describes an experiment, not a measured
performance result.

## Consolidated regression provenance

The canonical production helper is retained unchanged from PR #132 at
`8637a8d2c6a628699d5a552a55061b4e0bfc6f10`. Its six tests retain the independent
integer-label oracle. Four additional neighborhood tests preserve useful
coverage from these independently developed alternatives:

- PR #159, `21fa115d3b100fc70f60528a3ae82bd7371fda0b`: candidate equality and
  final policy ranking for every priority and limits 0, 1, 4, and 100; the
  original eager projection remains the independent reference.
- PR #227, `e6dce9c1b305cd86d8ce904d02890e8f5e9d63e4`: normalized item identity
  versus exact URL equality, stored absolute-string preservation, and seeded
  mixed-representation differential cases. Its equivalent eager oracle is
  shared with the #159 test; fixtures and expected semantics are retained.
- PR #135, `183ecd86ae1b2be581d732e658ab47cea185237e`: snapshot ownership after
  replacing the source playlist. Integer fixtures use the #227 item factory;
  the explicit expected window remains independent of the helper.
- PR #207, `7d83d898eaf164058b9928451501e4a6b324a3af`: the standalone singleton
  representation test, unchanged, including relative/base URL representations
  and dictionary key representations. Its production fast path is not imported.

API spelling is adapted to `ThumbnailPlaylistNeighborhood(playlist:current:)`.
Existing duplicate, clipping, absent-selection, and large-playlist tests already
cover corresponding alternative cases and are not duplicated. The runner
executes exactly 11 functions per variant/configuration (44 total executions),
and the native app workflow includes both neighborhood suites. Historical
archives, workloads, extraction guards, and timing methodology are unchanged;
original research remains at the source heads above, and at PR #165
`793d11e30b59d852923b6c4de991143465ee19ba` and PR #171
`cc928cca886b5c406dc6c06ebd7d33d5b9484085`. Those archives do not constitute
qualification of this consolidated test revision. Native execution of this
revision is pending; no new runtime or performance result is claimed here.
