# Scalar preference validation

Volume and playback-speed changes previously reconstructed all playback preferences.
That repeatedly normalized both track-language lists and recreated their arrays
while holding the persistence-store lock, even for unchanged or already-clamped
scalar values.

The [playback coordinator](../../Sources/IlliquidPlayer/Player/PlaybackController.swift)
calls these setters synchronously before forwarding volume or speed to the playback
runtime. The [volume slider](../../Sources/IlliquidApp/UI/PlaybackControlBar.swift)
reaches this path through AppModel, making the repeated work relevant to control
updates. This study does not assume a particular input-event frequency.

The candidate reuses the existing scalar validators directly. Full validation
remains at every preference ingress: decoding legacy history, loading the separate
preferences record, saving a complete preference value, and setting track
preferences. The store lock, equality/no-op check, failed-write retry, and
coalescing persistence writer are unchanged.

## Reproduce

On macOS 26 with Swift 6.1 or newer and the baseline Git commit available:

~~~sh
python3 Benchmarks/ScalarPreferenceValidation/run.py \
  --pairs 9 --output /tmp/illiquid-scalar-preference-validation
~~~

Use a new output directory. The default baseline is
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`.
The runner reads the baseline core sources from Git and the candidate core sources
from the working tree. It compiles the entire real `IlliquidCore` module in isolated
Swift packages, without frozen support fixtures, substituted validators, or the
native decoder/app dependency graph. Every measured process uses the same driver.

Run the command through the shared Kyoto queue when available, as required by
`AGENTS.md`. The dedicated GitHub Actions workflow checks for Kyoto and explains
when an isolated hosted runner must build directly. Builds, tests, and measurements
are serialized. No installed Illiquid app, real media, or existing user preferences
are used; each process creates and removes its own UserDefaults suite.

## Method

The 24 cases cover volume and speed with 0, 4, or 32 canonical entries **in each**
of the audio and subtitle language lists:

- Unchanged values.
- Alternating valid values.
- Different inputs that clamp to the already-stored value.
- A separate ungated burst of 32 alternating valid updates.

All cases share a synthetic non-default preference record, including a selected
audio-device identifier. The zero-language case is an empty-list control, not a
stock-default profile. Avoided work can therefore also include validating that
unchanged device identifier.

For the first three cases, a test-only UserDefaults subclass blocks one preference
write callback after the real writer has encoded its snapshot. This measures
**setter service cost while a preference write is in flight**. The actual store,
locks, equality checks, snapshot ownership and coalescing writer execute unchanged.
Blocking the callback prevents the 100 ms writer timer from giving the slower
variant additional encoding or persistence work during the timed loop.

Each process warms the exact setter path for 64 calls outside timing. Gated batches
are independently calibrated toward 50 ms, bounded to 128–2,000,000 operations;
the iteration count is retained with each observation. Even-sized batches finish
at the same scalar value. Nine fresh-process pairs alternate baseline/candidate
order, also alternating the first variant across cases. Summaries report median
elapsed nanoseconds per update and the median paired speedup. These are batch means,
not individual-event tail-latency percentiles.

The ungated control uses the unmodified writer and a short 32-update burst. Setup,
warmup, final flush, reload, and JSON serialization are outside the timed interval.
It is a synchronous burst measurement, not a paced UI-input or display benchmark.
Writer counts are recorded; only gated cases require fixed equal write counts.

Every pilot and measured process checks all preference fields, final reload parity,
and the canonical language-list counts. Gated changing cases must produce exactly
two preference writes after setup (the blocked snapshot plus the latest pending
value); unchanged/clamped cases must produce exactly one.

## Correctness and source receipts

The same current regression files run against baseline and candidate modules in
both debug and release configurations:

- ScalarPreferenceValidationTests: legacy history, separate-key precedence and
  raw-value save ingress; non-default unrelated preferences; numeric boundaries,
  non-finite values, signed zero and reload.
- PlaybackPersistenceStoreTests.
- IdempotentPersistenceTests.
- DeferredPersistenceTests.
- HistoryPolicyTests.

The manifest records both Git revisions, working-tree status, compiler and host,
plus SHA-256 hashes for every compiled Swift source, test and driver. Raw
observations, calibration, full-state parity receipts, test logs, and completion
status accompany the summary.

Five older persistence runners also select the current production
`PlaybackPreferences.swift` when compiling the current store. Their frozen baseline
fixtures remain unchanged; measurement manifests include the newly selected input.

## Recorded result

The [macOS qualification run](https://github.com/Jagalite/illiquid/actions/runs/40634269244)
passed on Apple M1 (Virtual), macOS 26.6.2, Apple Swift 6.3.3. It compared baseline
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72` with measured candidate
`b1ffc3c4d13db5ec7c7f5945aa446c829f6ea2c3`. Subsequent changes add these receipts,
documentation, and compatibility updates; the measured production setters are unchanged.

Median elapsed microseconds per alternating-value update with a preference write
in flight (nine pairs per case):

| Setter | Languages per list | Baseline (µs) | Candidate (µs) | Median paired speedup |
| --- | ---: | ---: | ---: | ---: |
| volume | 0 | 0.578 | 0.247 | 2.41× |
| speed | 0 | 0.562 | 0.221 | 2.63× |
| volume | 4 | 24.398 | 0.264 | 92.00× |
| speed | 4 | 20.256 | 0.224 | 90.16× |
| volume | 32 | 208.085 | 0.244 | 852.98× |
| speed | 32 | 199.148 | 0.238 | 942.13× |

The speedup column is the median of pairwise ratios; it need not equal the ratio
of the two independently reported medians. Every gated case improved in all nine
pairs, including unchanged and clamped values. See [the full summary](evidence/macos/summary.json)
for ranges and all 24 cases.

For the **ungated 32-update volume burst with four languages per list**, median
elapsed batch time was **0.972 ms → 0.064 ms** (paired speedup median 18.50×).
The corresponding speed burst was **0.683 ms → 0.037 ms**. Empty-language ungated
bursts were noisy and included losing pairs, so they do not establish a reliable
ordinary-burst improvement in that control.

All four regression runs passed: **26 XCTest tests plus 15 Swift Testing tests
per run**, against both variants in debug and release. All **432 timed observations**
and **36 calibration pilots** passed full-state/reload checks; the gated write
counts matched the expected unchanged coalescing behavior.

[evidence/macos](evidence/macos) retains source/host/compiler manifests, test receipts
and full logs, calibration, full preference parity records, summary, and a compact
CSV of every timed observation. The CSV preserves the original elapsed nanoseconds,
iteration counts, process order, per-update time, and write counts; its case ID
encodes the field, mode, languages per list, and writer mode. The run itself emits
the equivalent expanded `observations.json`.

## Scope

This research measures preference mutation and validates persistence semantics.
It does not establish a change in decoding throughput, frame rate, energy use,
physical disk-write durability, or end-to-end slider rendering latency.
Language-list normalization, array rebuilding, and subsequent equality work are
all part of the avoided cost; the measurements do not isolate ICU calls alone.
