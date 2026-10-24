# Planar ownership history memory

## Scope and production change

This experiment reduces duplicate storage in
[`PlanarBufferOwnershipLedger`](../Sources/IlliquidNativePlayback/Diagnostics/PlanarBufferOwnershipDiagnostics.swift).
The ledger previously retained each historical pixel-buffer address in both
`seenBufferIdentities: Set<UInt>` and `lastCheckoutByBuffer: [UInt: UInt64]`.
The dictionary already supplies historical membership as well as the latest
checkout ID. The candidate removes the set, uses the dictionary's count for
`distinctBufferIdentitiesSeen`, and uses the prior value returned by
`updateValue` to detect reuse and inspect the preceding checkout.

The production edit is confined to that ledger. It changes storage and lookup
work for diagnostic history; it does not change pixel-buffer allocation,
retention, pool limits, ownership release, or renderer submission. Historical
keys and checkout IDs are integers, not references to `CVPixelBuffer` objects.

The comparison pins baseline commit
`6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635`. Its ledger source has the same Git
blob, `4cf46a69f4037ef6dd8e91f7916509c5decc538b`, as main at `4abf4b44`.
The native qualification target is candidate
`1746be7c105c011ca1f507d8d7e1064dc37843e0`. The benchmark manifest records
the actual checkout and source hashes used by each run.

## Why the representation preserves history

Both historical collections began empty. Every checkout inserted its buffer
identity into the set and assigned its latest checkout ID in the dictionary,
under the same lock. Neither collection removed historical entries. Owner
release removes completed records from the separate `checkouts` dictionary;
flushes and generation changes also leave historical identities intact.
Consequently, the historical set was exactly the key set of
`lastCheckoutByBuffer` throughout the ledger's lifetime.

| Diagnostic | Previous representation | Candidate representation |
| --- | --- | --- |
| Distinct historical identities | Historical set count | Historical dictionary count |
| Reused identity | Set insertion reports an existing member | Dictionary update returns a previous checkout ID |
| Reuse while known owned | The previously recorded latest checkout still exists in `checkouts` | The returned previous checkout ID still exists in `checkouts` |
| History after all owners release | Set and latest-checkout dictionary retain their entries | Latest-checkout dictionary retains its entries |

The overlap rule deliberately concerns the most recent checkout for an
identity. If an older checkout remains alive but a newer checkout has already
released, another reuse does not count as reuse of that most recent checkout
while known owned. Returning the dictionary's previous value preserves this
existing behavior. The change also preserves lock coverage, checkout-ID
generation, live ownership records, phase transitions, peaks, and flush
observations.

This invariant depends on retaining historical dictionary keys after release.
Pruning that dictionary in a future change would alter both historical counts
and reuse detection, even when no frame currently owns the buffer.

## Where the history applies

[`VideoDecoder`](../Sources/IlliquidNativePlayback/Media/VideoDecoder.swift)
creates ownership tokens for qualified software-planar output. Hardware output
and the BGRA fallback do not create these tokens. Normal player policy prefers
planar software output where supported, as selected by
[`PlaybackController`](../Sources/IlliquidPlayer/Player/PlaybackController.swift).

The normal output-pool allocation threshold is 16 buffers. A pool that continues
reusing the same buffer addresses exercises a small history, and its absolute saving should be assessed separately from
larger synthetic cases. The decoder owns one ledger and passes that same ledger
to replacement planar pools, so its history can span pool replacements and
generations. This experiment does not measure how often production playback
creates new addresses or how large that history becomes in actual sessions.

Identity here means the pointer-derived address used by the existing ledger.
Allocator reuse of an address does not create a new historical identity. The
candidate preserves that definition and leaves the remaining history
unbounded for the ledger's lifetime.

## Measurement design

The [runner](../Benchmarks/PlanarHistoryMemory/run.py) compiles the complete
baseline and candidate ledger source with shared harnesses, frameworks,
compiler, and flags. Native builds use actual CoreVideo and CoreMedia types
and the production signpost source. Source, harness, test, runner, compiler,
platform, and executable provenance is recorded in `manifest.json`.

### Retained allocator bytes

The [memory harness](../Benchmarks/PlanarHistoryMemory/Harness.swift)
preallocates distinct tiny CoreVideo pixel buffers and keeps them alive before
taking the initial allocator checkpoint. This stabilizes their addresses and
excludes their initial allocation from the measured delta. Framework and
ledger warmup also precedes that checkpoint.

A fresh ledger checks out and releases one buffer at a time, first visiting
each identity once and then reusing every identity. Both passes end with zero
known owners. After each pass, temporary autorelease pools have drained and
the heap checkpoint is taken while the ledger remains alive. Scalar snapshots
check the expected distinct, reuse, and ownership counts. A final heap
checkpoint follows ledger destruction, while the fixture buffers remain
alive, to distinguish retained history from allocator residue or other
allocation that outlives the ledger.

The [allocator helper](../Benchmarks/PlanarHistoryMemory/Heap.c) reads
`malloc_zone_statistics(NULL).size_in_use` on macOS. The reported quantities
are:

| Quantity | Calculation |
| --- | --- |
| Retained bytes after population | Heap after the first pass minus the fixture-only checkpoint |
| Retained bytes after reuse | Heap after the second pass minus the fixture-only checkpoint |
| Residual bytes after destruction | Heap after ledger destruction minus the fixture-only checkpoint |

The configured history sizes are 16, 128, 1,024, and 8,192 identities. These are
historical-address cardinalities, not simultaneous player-frame occupancy.
The synthetic fixture keeps its buffers alive outside the measured allocation
delta, while the ledger has at most one active checkout during these passes.

### Paired runs and timing

The default experiment uses six pairs, alternating baseline/candidate and
candidate/baseline order. Every individual measurement starts a fresh process.
All raw samples are retained, including unfavorable results. Summaries include
each variant's median and range, paired byte or time differences, and the
median and range of paired percentage changes. Percentage change is calculated
within each pair as `100 * (candidate / baseline - 1)`; a zero baseline has no
defined percentage.

Separate lifecycle timing with trace recording disabled reuses the
[established ownership harness](../Benchmarks/PlanarOwnership/Harness.swift).
It runs `pipeline` and `lifecycle-mixed` at 1, 16, and 32 live owners, with
50,000 measured iterations after 5,000 warmup iterations. These workloads
check whether the representation change introduces a component timing cost;
they do not measure decoding throughput or playback presentation.
The harness's allocation meter is disabled; production diagnostic work and
signposts remain present in both variants.

## Correctness qualification design

The runner compares complete normalized diagnostic traces for baseline and
candidate in debug and release. Its default configuration uses five seeds
with 2,000 operations per seed. Traces cover reuse, overlapping and
renderer-only ownership, phase changes, stale callbacks, generation changes,
flushes, pool timeouts, and destruction. Counters, flags, and the presence of
optional durations must match. Durations must be finite and nonnegative, but
their wall-clock values are not expected to be identical. Equal full traces
are stored in compressed form, with independently recorded hashes of both
command outputs.

Native qualification also compiles the production ledger and signposts into
an isolated Swift package and runs the
[existing transition tests](../Tests/IlliquidNativePlaybackTests/PlanarOwnershipTransitionTests.swift)
and [new history tests](../Tests/IlliquidNativePlaybackTests/PlanarOwnershipHistoryTests.swift)
in debug and release. The suites declare seven test functions, corresponding
to eight cases when the parameterized release-order test is expanded. The
new tests specifically guard history after all owners release and after
flushes and generation changes, keeping buffers alive to prevent address
recycling from weakening their assertions. Actual execution counts and
outcomes must come from `native-tests.json` and its accompanying logs.

## Results

Native qualification and measured outcomes are pending for the candidate
identified above. No performance improvement or successful test execution is
claimed by this draft. This section must be completed from the native evidence
and its completion receipt before publication.

## Reproduction

From a checkout containing the candidate and pinned baseline, use a fresh
output directory:

```sh
python3 Benchmarks/PlanarHistoryMemory/run.py \
  --output /tmp/planar-history-reproduction \
  --pairs 6 --counts 16,128,1024,8192 --steps 2000 --iterations 50000
```

Follow [build coordination](../AGENTS.md): submit that command through Kyoto
when available. If it is unavailable, explain the limitation and use the
runner's isolated output directory. Add `--tests-only` for correctness
qualification without heap or timing measurements.

The [native workflow](../.github/workflows/planar-history-memory.yml) selects
macOS 26 and Xcode 26.6. It runs full measurements on the named research branch
and manual dispatch, and correctness qualification on ordinary pull requests.
Its evidence artifact contains raw samples, paired summaries, complete traces,
native test logs, compilation logs, source provenance, and completion status.
See the [benchmark README](../Benchmarks/PlanarHistoryMemory/README.md) for
runner and evidence details.

## Interpretation and limits

- Allocator bytes above the fixture checkpoint measure this component's
  retained storage. They do not establish whole-player RAM, resident memory,
  memory pressure, or a change in retained pixel-buffer storage. Peak RSS also
  includes fixtures and is only auxiliary evidence.
- The destruction checkpoint matters: a difference that persists after the
  ledger is gone may reflect allocator behavior rather than live history.
  Both first-population and repeated-reuse measurements should be reported.
- Larger history sizes expose the storage scaling of the representation.
  They do not establish the expected benefit for a normal 16-buffer pool or
  the historical cardinality reached by a real playback session.
- Linux exploration uses framework identity/sample stubs and glibc
  `mallinfo2`, whose totals can include thread-cache residue. It cannot replace
  native CoreVideo/CoreMedia and allocator qualification, particularly for
  small deltas.
- Component timing and a small balanced set of fresh-process samples do not
  establish statistical significance, frame-rate changes, end-to-end latency,
  or behavior during long-running playback. This change removes redundant
  history storage; it does not bound the remaining historical map.
