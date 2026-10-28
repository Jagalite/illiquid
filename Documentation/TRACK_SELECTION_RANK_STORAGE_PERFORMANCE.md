# Track selection rank storage research

## Hypothesis

`TrackSelectionPreferences.select` currently creates a seven-element integer
array for every eligible track that needs ranking. The six priorities below
language preference are Boolean. A scalar rank can preserve the same ordering
while avoiding temporary rank-array storage and lexicographic iteration.

The candidate stores language rank above six priority bits. Sanitization limits
language rank to 0...32, so the largest rank is 2,111. Each priority outweighs
all lower priorities combined. The existing signed-ID comparison breaks exact
ties. Filtering, normalization, subtitle policies, and early returns are unchanged.

## Comparison

The baseline is pre-change main commit
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`. This deliberately excludes gains
from the earlier track-selection optimization, whose frozen source and evidence
remain in `Benchmarks/TrackSelectionRanking`.

The existing harness compiles real production sources as separate optimized
modules, compares all 55,296 selected-ID outputs, and runs sixteen workloads
using fresh-process, calibrated, balanced AB/BA measurement pairs. This study
uses ten pairs per workload and a 50 ms minimum calibration target for the
faster variant. Empty/singleton and subtitle automatic/off cases are controls.
Both variants run the semantic test suite in debug and release, including a
new full 32-language boundary test with extreme signed IDs.

## Status

Native qualification is pending. No timing improvement or playback improvement
is claimed until the matching macOS run has completed successfully. This is a
component study of track selection, not an end-to-end media-open or playback
frame-rate benchmark.

Reproduction commands are in the
[benchmark README](../Benchmarks/TrackSelectionRanking/README.md#comparing-a-later-optimization).
