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

## Measured result

The [Linux component job](https://github.com/Jagalite/illiquid/actions/runs/40638584849/job/122651186682)
passed for production/test/harness commit
`81db035aa2f3161c7c16d1f21a8cfac394b48d6a`.
The measurement host was x86_64 Linux (Azure kernel 6.17.0-1022, glibc 2.39),
using Swift 6.4 release with optimized Swift 6 compilation.
Subsequent reporting commits preserve the measured source and harness.

All 18 workloads were faster in every one of their eight paired observations.
For ordinary two-track rich metadata, the median call fell from **468.79 ns
to 51.05 ns** (89.15% median paired reduction). The eight-track mixed audio
case fell from **887.24 ns to 68.38 ns** (92.28%); eight-track external subtitle
matching fell from **951.34 ns to 123.73 ns** (87.03%).
These are sub-microsecond absolute savings on small catalogues.

Percent reductions are medians of paired ratios; they need not equal the ratio
of the two separately displayed timing medians.

| Workload | Baseline ns/call | Candidate ns/call | Median paired reduction | Paired candidate/baseline range |
| --- | ---: | ---: | ---: | ---: |
| rich-0 | 14.04 | 4.68 | 66.68% | 0.3329–0.3616 |
| rich-1 | 262.29 | 44.39 | 82.96% | 0.1465–0.1742 |
| rich-2 | 468.79 | 51.05 | 89.15% | 0.1075–0.1095 |
| rich-8 | 1296.32 | 106.20 | 91.72% | 0.0811–0.0856 |
| rich-32 | 4272.95 | 319.72 | 92.54% | 0.0731–0.0785 |
| rich-128 | 15487.79 | 1132.86 | 92.70% | 0.0725–0.0776 |
| sparse-2 | 451.49 | 47.56 | 89.46% | 0.1034–0.1066 |
| sparse-8 | 1325.82 | 87.65 | 93.38% | 0.0654–0.0690 |
| sparse-32 | 4576.60 | 229.12 | 94.99% | 0.0498–0.0528 |
| mixed-audio-8 | 887.24 | 68.38 | 92.28% | 0.0765–0.0800 |
| mixed-audio-32 | 2803.68 | 170.31 | 93.90% | 0.0601–0.0631 |
| external-8 | 951.34 | 123.73 | 87.03% | 0.1270–0.1339 |
| external-32 | 3038.06 | 380.39 | 87.49% | 0.1223–0.1273 |
| zero-score-1 | 155.18 | 16.16 | 89.57% | 0.1022–0.1112 |
| zero-score-8 | 768.20 | 89.98 | 88.29% | 0.1140–0.1264 |
| wrong-kind-8 | 224.77 | 9.03 | 96.01% | 0.0389–0.0425 |
| saved-id-tie-8 | 1257.56 | 95.72 | 92.28% | 0.0746–0.0787 |
| legacy-tie-8 | 1291.76 | 89.94 | 93.02% | 0.0671–0.0715 |

The 128-track catalogue is a scaling case. Empty, singleton, zero-score,
wrong-kind, saved-ID and legacy controls are retained above rather than excluded
from the reported cohort.

## Validation and retained evidence

- Full output parity passed for **8,464 semantic cases and 72 timed fixture
  orders**, with zero independent-model mismatches.
- Baseline and candidate verification files have the identical SHA-256
  `c896329e216c289e6dd4be0854f829cfeb89730f4232ccb717e33b88148bbd20`.
- The existing saved-track restoration and parser suites plus the new tests
  passed **13 tests in three suites** against baseline and candidate in both
  debug and release (four successful runs, with warnings treated as errors).
- **288 measured observations** cover 18 workloads, eight balanced pairs,
  and two variants. Calibration observations, commands, complete output
  receipts, build/test logs, source hashes, compiler details and binary hashes
  are retained.
- The timing and test manifests contain identical production source hashes;
  MediaPlaybackSettings.swift is the only differing production file between
  baseline and candidate.
- Independent source review checked the ranking, duplicate-ID behavior,
  signed extremes, byte-exact result comparison, and test staging.
- An [independent evidence audit](evidence/linux/audit.json) verified the
  compressed bundle and all 452 retained files, recomputed every timing summary,
  and checked all 428 measured/calibration checksums and selection counts
  against complete fixture results. All 144 timing pairs favored the candidate.
  The final production source was independently hashed against the measured
  source, and all four test-log hashes were verified.
- Final calibrated intervals met the 100 ms target; actual retained timing
  intervals ranged from 95.91 ms to 2,567.40 ms.

The [native macOS 15 component job](https://github.com/Jagalite/illiquid/actions/runs/40638584849/job/122651186924)
was still queued when this report was prepared. The PR is a draft pending that
native qualification. No macOS timing or full macOS 26 application build is
claimed by the Linux result.

Durable evidence:

- [Complete compressed evidence bundle](evidence/linux/evidence.json.gz)
- [Bundle SHA-256](evidence/linux/evidence.sha256)
- [All timing summaries and paired observations](evidence/linux/summary.json)
- [Complete-result verification receipt](evidence/linux/verification.json)
- [Debug/release test receipt](evidence/linux/tests.json)
- [Compiler, production and harness provenance](evidence/linux/manifest.json)

The gzip contains a JSON mapping from relative evidence filename to exact UTF-8
file contents. To inspect a retained log or raw measurement file:

~~~sh
python3 - <<'PY'
import gzip
import json
from pathlib import Path

bundle = json.loads(gzip.decompress(
    Path("Benchmarks/SavedTrackMatching/evidence/linux/evidence.json.gz").read_bytes()
))
print(bundle["timing/observations.json"])
print(bundle["tests/candidate-release-tests.log"])
PY
~~~

## Scope

Matching remains O(n), with O(1) auxiliary collection storage. The old eager
filter/map/filter pipeline constructed three intermediate arrays; the candidate
retains an index and score. This is a structural storage improvement, not a
measurement of exactly three heap allocations, allocated bytes, peak heap or RSS.

This function runs when restoring saved track choices, not on every decoded
frame. The study does not establish playback FPS, whole-app startup latency,
battery use, or live UI improvement. The positive performance result currently
applies to the recorded Linux toolchain; native compiler/runtime costs remain
for the queued macOS job.
