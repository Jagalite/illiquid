# Scalar preference mutation performance

## Outcome and scope

The candidate removes repeated whole-preference sanitation from the synchronous
volume and playback-speed persistence setters. The Linux component campaign
passed behavioral verification and showed a repeatable caller-cost improvement
when audio/subtitle language preferences are populated. A concurrent native macOS
campaign independently corroborates the same executable production change, as
documented below. This PR's own expanded macOS matrix remains pending.

Baseline: `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`.
Only `PlaybackPersistenceStore.swift` and `PlaybackPreferences.swift` differ
between measured production variants. The runner records the exact source and
binary hashes; supporting code is one current snapshot shared by both variants.

## Why this path

`PlaybackController.setVolume` and `setPlaybackSpeed` synchronously call the
persistence store. The original setters change one number, then rebuild and
sanitize the complete `PlaybackPreferences` value. That re-normalizes every
configured audio/subtitle language through Foundation, rebuilds their arrays and
sets, and trims the audio-device identifier on every control update.

The store already owns sanitized preferences. Empty state uses `.standard`;
both legacy history and dedicated preferences decode through the validating
initializer; `savePreferences` sanitizes the externally mutable value;
track-preference and audio-device setters sanitize their respective fields.
Other setters assign typed Boolean/enum fields. Getter results are independent
value copies. The candidate calls the existing scalar validators directly.
Their implementations, invalid-input defaults, and clamp limits are unchanged.

The writer, coalescing delay, equality-based no-op suppression, persistence schema,
and public API retain their existing behavior. The validators become internal
implementation details so both the initializer and store can use them.

## Linux measurements

Environment: Swift 6.3.2, Ubuntu 24.04 x86_64, AMD EPYC 9V74. The container reports
nine logical CPUs and an eight-CPU quota. These are component measurements on a
shared execution host, not whole-player latency measurements.

The formal matrix contains 28 workload cells with six balanced baseline/candidate
pairs each: **336 fresh processes**. Each process uses the same input and verifies
complete preference results, persisted values, reloaded state, history bytes and
write counts. No completed observations were dropped.

The following caller times are medians in microseconds per update. Percentages
are medians of paired ratios, so they need not equal the ratio of the two displayed
medians. `blocked` measures 1,000 changed setters with the first real defaults
callback gated; `burst` is an ordinary 16-update burst with no gate.

| Field | Mode | Languages per list | Baseline µs/update | Candidate µs/update | Paired caller reduction |
| --- | --- | ---: | ---: | ---: | ---: |
| Volume | blocked | 1 | 14.611 | 0.277 | 98.10% |
| Speed | blocked | 1 | 17.458 | 0.249 | 98.47% |
| Volume | burst | 1 | 18.819 | 8.120 | 53.74% |
| Speed | burst | 1 | 15.796 | 7.532 | 49.48% |
| Volume | blocked | 3 | 51.387 | 0.230 | 99.59% |
| Speed | blocked | 3 | 48.014 | 0.257 | 99.45% |
| Volume | blocked | 32 | 520.045 | 0.275 | 99.95% |
| Speed | blocked | 32 | 517.296 | 0.266 | 99.95% |

The 32-code lists are supported-bound stress cases. One or three codes **in each
list** means two or six language normalizations in the baseline. These synthetic
fixtures do not represent the user's actual preferences.

Empty language lists provide a useful control. Their caller costs are much
smaller; short bursts and per-update flushes are correspondingly sensitive to
scheduling and write overhead. Retained results include regressions and outliers:
for example, the empty-list speed control that flushes every update has a +25.1%
median paired complete-operation time, and some short-burst pairs have large timing
outliers. This campaign supports eliminating redundant scalar-setter work; it
does not establish a universal end-to-end latency improvement.

The gated/no-op populated-list cells are much more consistent: every observed
paired caller ratio is below 0.033 for the one-code fixtures, and smaller still
for three-code fixtures. Ordinary one-code bursts also improved in every pair
for both fields. Full values, ranges and complete-operation timings are retained
in [the summary](../Benchmarks/ScalarPreferenceMutation/evidence/linux/summary.json).

## Correctness and integration validation

The same **45 tests** run against baseline and candidate in debug and release:
26 XCTest tests and 19 Swift Testing test functions per configuration, for
180 successful test executions across four builds. Parameterized Swift Testing
cases add legacy/dedicated-key and readable/unreadable-history variants.

Eight new test functions establish the invariant needed by the optimization:
31 exact scalar boundary inputs, nonfinite values, clamped no-ops, all unrelated
fields, dirty externally mutated preferences, language sanitation, legacy loads,
key precedence, unreadable-data fallbacks, copy independence and concurrent
field updates. They check plain decoded scalar JSON as well as complete
preference decoding and store reload.

The first full test attempt found a test-helper precision issue on the unchanged
baseline: Foundation's `JSONSerialization`/`NSNumber` bridge rounded two adjacent
Double values. The helper now uses a plain synthesized `Decodable` struct with
two Double fields and no sanitation. Exact input expectations were retained.
An earlier driver compilation rejected an unavailable inherited Sendable
conformance on the observed defaults subclass; that annotation was removed.
Those failed setup attempts and the exploratory timings are retained separately
from the completed formal cohort in the receipts archive.

Five older persistence harnesses previously combined the current store with a
frozen preferences file whose scalar helpers were private. Their staging now
uses the same current preferences source in both applicable variants and records
that provenance. Frozen fixtures, old store baselines and historical evidence
are unchanged. The current and frozen preferences differ only in the two
helper access modifiers. The adjusted integration harnesses passed 12 and 26 existing tests, respectively.
Their differential check matched 200 reload receipts across 10,000 operations per
variant. Both historical timing harnesses compiled each variant successfully;
their old timing campaigns were not rerun. See the
[integration receipt](../Benchmarks/ScalarPreferenceMutation/evidence/linux/integration.json).

The existing component regression job also
[passed on macOS](https://github.com/Jagalite/illiquid/actions/runs/40634872451/job/122639411392)
with the candidate production sources: macOS 26.6.2 arm64 and Xcode 26.6, PR merge
commit `ad6eafa34a5082b6389db5cc6046c4305238a376`. Its logs confirm the 12- and
26-test persistence suites and 200 matching reload receipts after 10,000 mixed
operations per variant. This integration result is separate from the new
four-configuration test matrix and paired performance campaign, whose macOS
qualification remains pending.

## Independent native corroboration

While this PR's native job was queued, a concurrent branch was found with the
same executable production change:
[`b1ffc3c4d13db5ec7c7f5945aa446c829f6ea2c3`](https://github.com/Jagalite/illiquid/commit/b1ffc3c4d13db5ec7c7f5945aa446c829f6ea2c3).
Its `PlaybackPreferences.swift` is byte-identical to this candidate. Its store
differs only in the invariant comment's wording and placement. The production
edits should be integrated once; the two benchmark campaigns provide complementary
evidence, not two distinct optimizations.

That branch's [native run](https://github.com/Jagalite/illiquid/actions/runs/40634269244)
passed on macOS 26.6.2 arm64, Apple M1 (Virtual), Apple Swift 6.3.3. Its separate
harness completed 41 tests in each of four baseline/candidate debug/release
configurations and 432 observations: 24 cells, nine alternating process pairs
each. The source hashes and four test-log hashes match its manifest, and all 24
summary cells independently recompute from the retained observations.

For ordinary 32-update changing-value bursts with **four language codes in each
list**, that independent campaign reports:

| Field | Baseline median µs/update | Candidate median µs/update | Median paired speedup |
| --- | ---: | ---: | ---: |
| Volume | 30.389 | 1.993 | 18.50x |
| Speed | 21.355 | 1.155 | 16.79x |

All nine pairs improved in these two populated-list cases. Its empty-list normal
bursts include individual regressions. All of its fixtures, including empty-list
controls, use a nondefault output device and other nondefault settings. It uses
a different driver, fixture sizes and calibration from the Linux campaign, so
these numbers must not be treated as a matched cross-platform comparison.
Its writer-gated cases calibrate the iteration count separately for each variant;
their per-update results measure throughput rather than equal-length traces.
Its ordinary bursts use the fixed 32 updates shown above and flush afterward,
outside the timed interval.

The original [artifact ZIP](../Benchmarks/ScalarPreferenceMutation/evidence/independent-macos/run-40634269244.zip)
is retained with [source comparison and provenance](../Benchmarks/ScalarPreferenceMutation/evidence/independent-macos/provenance.json).
Its SHA-256 matches the GitHub artifact digest. This corroborates the production
algorithm on macOS; it does not execute this PR's exact source tree, new tests,
compatibility adapters or `ScalarPreferenceMutation` harness. The accompanying
native workflow qualifies those separately.

## Reproduction and limits

See [the benchmark instructions](../Benchmarks/ScalarPreferenceMutation/README.md)
for the source boundary, write-gate controls, command line and full matrix.
The ordinary burst must finish below 50 ms, before the unchanged 100 ms writer
delay, and record no callback during timing. The gated case must produce exactly
its initial and latest writes. No-op setters must produce none. These checks
prevent different background-write scheduling from masquerading as an algorithm
speedup.

The native workflow repeats the same tests and paired experiment on macOS 26.
Live UI dragging, event-to-audio latency, native playback, frame drops, energy,
whole-process memory and physical disk durability are outside this experiment.
Linux Foundation costs must not be represented as native macOS results.

## Evidence

- [Formal Linux manifest](../Benchmarks/ScalarPreferenceMutation/evidence/linux/manifest.json)
- [Formal Linux test counts](../Benchmarks/ScalarPreferenceMutation/evidence/linux/tests.json)
- [Formal Linux summary](../Benchmarks/ScalarPreferenceMutation/evidence/linux/summary.json)
- [Complete receipts](../Benchmarks/ScalarPreferenceMutation/evidence/linux/receipts.tar.gz):
  source snapshots/hashes, binary hashes, raw observations, parity receipts,
  commands/logs, exploratory results and setup failures.
- [SHA-256 inventory](../Benchmarks/ScalarPreferenceMutation/evidence/linux/SHA256SUMS)
