# Playback effect settlement experiment

This harness compares the complete production playback reducer at baseline
ea2ff568237e2667f7b1aeee67b11a44ebe95b72 with the current working tree. The
candidate first checks whether all effects have the retiring authority. It maps
the keys directly in that case, preserving the known-size array allocation;
otherwise it collects matching IDs with compactMap. Both paths collect all IDs
before mutating the outstanding-effects dictionary.

Swift 6.3.3's native dictionary filter first records included entries in a
bitset. It returns the original dictionary when every entry matches and an
empty dictionary when none match; only a partial match builds another
dictionary containing matching records. The candidate therefore removes that
extra dictionary for partial matches. The all-match path preserves the original
known-size key copy without the filter's selection bitset. Partial matches pay
an additional authority scan through the first nonmatch; nearly-all-match cases
can make that prefix long. The experiment includes those cases as well as
all-match, sparse-match, and no-match controls.

## Run

Swift 6.1 or later and Python 3 are required. Linux allocation instrumentation
also requires glibc and a C compiler. No media fixtures, FFmpeg, macOS frameworks,
package downloads, or model stubs are used.

When the repository's Kyoto build queue is available, submit the runner through
that queue. Otherwise explain the unavailable queue before a direct build, as
required by the repository's AGENTS.md.

    python3 Benchmarks/EffectSettlement/run.py \
      --output /tmp/effect-settlement --swift "$(command -v swift)" \
      --pairs 6 --target-ms 180

Use a new output directory. Builds and tests sharing a package's build directory
are serialized. The isolated package copies the exact production MediaTrack.swift
and every file in Sources/IlliquidPlaybackCore. Baseline sources come from the
pinned Git commit; candidate sources come from the working tree. The runner
requires identical source inventories and rejects any production difference
outside PlaybackCore.swift. Source and binary hashes, compiler/platform details,
command logs, and generated manifests are retained.

The current playback-core test files are used for both variants. The runner
executes the focused settlement/history/completion/core suites against the
baseline in release and the candidate in debug and release. These isolated tests
use the compiler's bundled Swift Testing, not the full app's package graph.

## Workloads

Every measured operation calls the real public PlaybackCore.update API with
an event envelope. The private settlement helper is never exposed or copied.

| Scenario | Public event and authority being settled |
| --- | --- |
| load | A new load supersedes the pending source's effects |
| stop | Stop retires pending-source effects before stopping the committed source |
| cleanup | Successful cancellation of a retired session settles that session's effects |
| control | A diagnostic event checks the same state without settling effects |

All three settlement paths use 0, 1, 4, 8, 32, 128, and 512 seeded outstanding
records with matching authority. Additional 2/4/8/128-record cases use alternating
matching/foreign authorities; 8/128-record cases also test no matching records.
Foreign authorities differ
in application scope, session, generation, or subtitle revision. The cleanup
path adds one cancellation-trigger record that is completed before the helper
runs; its population label describes the records seen by the helper.

Three load cases add 7-of-8, 127-of-128, and 1-of-128 matching records. Membership
is fixed by insertion index, while hash iteration remains process-dependent.
These expose nearly-full pre-scan and sparse-allocation tradeoffs. The full
inventory contains 47 cases and 94 initial/final semantic traces.

The 0/1/4/8 cases exercise small populations; 32/128/512 are scaling experiments.
They do not establish that these effect counts occur frequently in the player.
These are valid seeded reducer states, not captured user playback traces.

Each ordinary fixture creates its own dictionary. No saved seed state retains
that dictionary during the update. Two separate load cases at 8 and 128 records
intentionally retain a state snapshot, exposing the shared-storage situation
without mixing it into the unique-ownership measurements.

## Correctness

Before measurement, both binaries emit complete initial/final state, UI snapshot,
disposition, canonical emitted effects, and invariant results for every case in
both ascending and descending insertion order. The complete JSON traces must
match. This comparison retains content, not just hashes.

The full-state wrapper uses the production canonical state and explicitly adds
the four stored fields that the existing canonical representation omits:
pending session, last load failure, loop range, and preferred playback rate.
The fixtures' session collections are empty, and the production canonicalizer
sorts effect identities, completion tokens, and resource leases.

Independent expectations verify exact completed and surviving effect IDs, load
replacement, stop generation/phase, emitted effect kind, preservation of the
committed session after retired cleanup, zero invariant violations, and an
unchanged retained snapshot. Regression tests cover additional authority,
lifecycle, failure, duplicate, history-gap, and copy-on-write cases.

## Timing and allocation boundary

Fixtures are constructed in bounded batches outside measurement. Each core is
updated once. The measured window includes the complete public update, invariant
checking performed by production, return-value destruction, and a scalar output
checksum. It excludes fixture construction/destruction, state materialization,
canonical encoding, and printing. Batch sizes range from 8 to 256; larger
populations use smaller batches to bound live fixture memory.

Per-process samples accumulate disjoint batch windows. Their summed process CPU
and monotonic wall durations must each be at least 100 ms. Both variants
calibrate independently to a default target of 180 ms, with a proportional
batch-count estimate and 15% headroom; values are normalized per
event. Six fresh-process pairs alternate baseline/candidate and
candidate/baseline. All pilots, final samples, order, counts, checksums, ranges,
and paired ratios are retained. No sample is selectively dropped. A short sample
rejects the cohort after preserving its observations; rerun the complete cohort
with a larger target if necessary.

On Linux/glibc a separate set of fresh processes loads the existing
Benchmarks/NonDecodePerformance/allocmeter.c interposer. The meter is enabled
only around the same update loop. It counts successful malloc/calloc/realloc
requests and requested sizes. Each instrumented process first proves interception
with a known 12,345-byte allocation through dynamically resolved malloc/free;
that positive self-check is reported in its observation. Fixture construction,
state checks, printing, and
teardown remain outside those windows. Allocation runs are separate from timing
runs because interposition and atomic counting perturb timings. Allocation
observations are collected and saved before the timing cohort. macOS records
timing and correctness only and explicitly marks allocation measurement
unsupported.

These allocation metrics describe traffic, not retained bytes, peak heap, RSS,
or the app's footprint. The complete update also allocates for completion-history
maintenance and new emitted effects; the measurements do not attribute every
request to the changed helper. Hash-table iteration order can alter temporary
history allocation, which is why complete-operation distributions are retained.

## Outputs and interpretation

- manifest.json: environment, exact source/binary provenance, boundaries and gates.
- trace-baseline.json, trace-candidate.json, parity.json: complete semantic comparison.
- observations.json, calibrations.json: raw timed samples and calibration trials.
- allocation-observations.json: raw allocation-traffic runs when supported.
- summary.json: medians, ranges and paired ratios per event.
- commands.jsonl, logs/: build/test/measurement commands and full outputs.

The harness reports measurements; it does not declare that a change is useful
merely because validation passes. Small-population results, controls, variability,
and stress limits must be considered before making a performance claim. This is
a reducer-component experiment, not a frame-rate, seek-latency, battery, or
whole-player memory measurement.

The --cases, --skip-tests, and --skip-allocations flags are exploratory options.
Final qualification uses the full default inventory and tests. --tests-only runs
builds, tests, and semantic parity without repeating performance measurements.
