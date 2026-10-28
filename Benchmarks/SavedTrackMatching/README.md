# Saved track matching

This study evaluates saved per-file audio/subtitle restoration in
MediaTrackPreference.bestMatch(in:). The baseline constructs three temporary
arrays through filter/map/filter before choosing one result. The candidate
scores candidates in one pass and retains only the winning index and score.

The production change preserves kind filtering, the positive-score requirement,
the additive 2/16/8/4/2 score, saved-ID precedence on equal scores, lowest signed
ID fallback, and first-occurrence behavior for duplicate-ID ties. It does not
change automatic track-selection preferences or the saved settings format.

## Reproduction

When Kyoto is available, submit each whole command through the shared queue:

~~~sh
python3 /Volumes/seed1/Projects/kyoto/kyoto.py submit -- \
  python3 Benchmarks/SavedTrackMatching/run.py --output /tmp/saved-track-timing
python3 /Volumes/seed1/Projects/kyoto/kyoto.py submit -- \
  python3 Benchmarks/SavedTrackMatching/run.py --test --output /tmp/saved-track-tests
~~~

When Kyoto is unavailable, explain that limitation and run the Python commands
directly. Output directories must be new; builds are serialized and isolated
from the application's build directory. The two production files use no native
playback frameworks and need only Swift 6.1 or later.

The workflow uses the hosted Ubuntu 24.04 Swift toolchain and Xcode 16.4 on
macOS 15, recording the actual compiler and host. The macOS 15 component target
allows these portable files to be qualified independently; the application's
macOS 26 requirement is unchanged.

## Method and correctness

The exact frozen production baseline is commit
ea2ff568237e2667f7b1aeee67b11a44ebe95b72. Its Git blob is checked before every run.
Both variants compile complete MediaTrack.swift and MediaPlaybackSettings.swift
files into separate optimized libraries. The identical driver compiles
separately without cross-module optimization.

Preflight compares the complete selected track, serialized with deterministic
JSON, for 8,464 deterministic cases and 72 timed fixture orders. A separate
ordered-rank model checks score, saved-ID membership, signed ID and input
offset. The corpus covers every pair of score-predicate combinations, both
kinds and external states, optional metadata, legacy missing IDs, duplicate and
extreme IDs, decoded empty metadata, and canonically equivalent Unicode.
Wrong-kind and zero-score candidates remain ineligible. Any mismatch stops
measurement.

The 18 timed workloads cover 0/1/2/8/32/128 rich-metadata tracks, 2/8/32 sparse
catalogues, mixed audio and external subtitles, zero-score and wrong-kind
controls, saved-ID ties, and legacy ties. Four prebuilt input orders rotate
equally during each timed sample. Fixture construction, JSON operations and
warmup are outside the measured interval. Timing includes the call and selected
result consumption. A wrapping ID checksum and a separate selected-result count
make every call observable without treating a negative ID as a missing result.

Calibration targets at least 100 ms for the faster variant. Eight fresh-process
pairs alternate AB/BA order with identical operation counts and matched
checksums. All calibration and measured observations are retained; summaries
report median paired ratios and their full observed range. Platform cohorts are
kept separate.

The existing saved-track restoration and parser tests, together with new
regressions, run against baseline and candidate in debug and release. No
external package dependencies or media fixtures are required.

## Results and scope

Native and portable results will be recorded after validation. This function
runs when restoring track choices, not on every decoded frame. Component
improvements do not establish playback FPS, startup latency, battery use or
whole-player memory savings. The eliminated temporary arrays are a structural
storage improvement; this study does not instrument allocator bytes or RSS.
