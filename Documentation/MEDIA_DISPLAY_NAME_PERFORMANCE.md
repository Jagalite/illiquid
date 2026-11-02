# Qualification of PR #141's episode display-name formatting

## Result and scope of this follow-up

This study qualifies the exact production implementation in
[PR #141](https://github.com/Jagalite/illiquid/pull/141). The stacked
[follow-up #233](https://github.com/Jagalite/illiquid/pull/233) has **zero changes
under `Sources/` relative to #141**. Its contributions are additional compatibility
tests, fresh independent measurements with complete receipts, surrounding-row
controls, and repair of the historical recognition verifier described below.

On the measured Linux host, #141's implementation reduces median paired time
for four numbered-episode label workloads by **86.49%–91.94%**.
The candidate is faster in all **40 of 40** targeted pairs; even the least
favorable targeted pair reduces time by **81.33%**. The tables report
wall and process CPU measurements separately. The supported conclusion is lower
label-construction cost on this host. It is not a whole-player speedup claim.

**Native macOS qualification remains pending.** The follow-up stays a draft until
the native benchmark, intact historical comparison, and application build/tests
complete. Linux timings do not establish macOS, SwiftUI, playback, or interactive
latency improvements. Complete row results remain exploratory, with all controls
and adverse observations disclosed.

The current [component summary](../Benchmarks/MediaDisplayName/evidence/linux/component-summary.json),
[row summary](../Benchmarks/MediaDisplayName/evidence/linux/projection-summary.json),
and [archive/provenance guide](../Benchmarks/MediaDisplayName/evidence/linux/README.md)
contain this fresh cohort. Independent audits reproduce both summaries from raw observations and verify the retained source and process-log receipts.

## Why the historical verifier needs this follow-up

The historical runner in #141 shares the candidate's `RecognizedMediaName` type
with its frozen parser. It therefore requires that type's entire declaration to
remain byte-identical to the frozen declaration. Changing `displayName` violates
that requirement: the native workflow's existing **Compare exact metadata on pull
requests** step would reject staging with `RecognizedMediaName changed; the
shared-type oracle requires review`, before any comparison executes.

This follow-up preserves the complete frozen source and mechanically renames
both its result type and parser. The harness serializes each version's stored
fields and its own derived `seriesTitle`, `displayName`, and `section` values.
Baseline formatting is therefore evaluated independently. Simply dropping the
old declaration check while sharing today's result type would apply the new
formatter to both sides and could mask a regression.

The frozen historical file, manifest hash, and corpus remain unchanged. Receipts
record identifier-renaming counts and exact compiled inputs. This repairs the
gate's ability to validate #141; it does not declare that the native gate has
already passed. See the [verifier guide](../Benchmarks/MediaNameRecognition/README.md).

## Adopted implementation and application call site

PR #141's [`RecognizedMediaName.displayName`](../Sources/IlliquidCore/MediaLibrary/MediaNameRecognition.swift)
uses direct decimal strings when season, episode, and any range endpoint are
all between zero and **`Int32.max` (2,147,483,647)**. Values below ten receive a
leading zero. If any component is negative or wider, it evaluates the **complete
original Foundation expression**, including the original optional range formatter.
This preserves signed C `%d` conversion rather than changing unusual metadata
hints to unrestricted Swift integer formatting.

Nil numeric fields still become zero. A nonnil air date, including an empty
string, bypasses numeric formatting. Range/title separators, empty titles,
Unicode bytes, and movie/extra/unknown labels retain their behavior. The adopted
implementation adds no cache or mutable shared state.

The real path starts in
[`SourcesSidebar.synchronizeRecursiveMediaScan`](../Sources/IlliquidApp/UI/SourcesSidebar.swift):
`SourceRecursiveMediaLoader` obtains recognized metadata through
[`MediaSidecarReader`](../Sources/IlliquidCore/MediaLibrary/MediaSidecarReader.swift),
then `refreshVisibleRows` invokes the
[`SourceBrowserFilter`](../Sources/IlliquidApp/UI/SourceBrowserFilter.swift) actor.
When its tree input changes,
[`SourceTreeProjectionInput.rows` / `makeFlatFileRows`](../Sources/IlliquidApp/UI/SourceTreeProjectionInput.swift)
constructs each label and stores it in the row.

Normal metadata scans already supply recognition, so formatting remains real
work during the later reconstruction. Search or visibility edits that reuse
`cachedRows` reuse those strings. Filesystem discovery, sidecar I/O, drawing, and
playback are outside the changed operation and the measured intervals.

## Baseline, provenance, and measurement

| Item | Recorded value |
| --- | --- |
| Frozen main baseline | `ea2ff568237e2667f7b1aeee67b11a44ebe95b72` |
| Measured follow-up commit | `c15703fcab7d7ccca3642eac626dad4923fb4fd9` |
| Adopted #141 production commit | `5166cb73475b24dfb29f7115a5fa109e74379ba3` |
| Recognition source SHA-256 | `cc3c1ac628498798384c3e93973ffa0dcd6f21036b1f1de779cd54c82cc944d1` |
| Runtime | Swift 6.3.3 release, Ubuntu 24.04.3 x86_64, Linux 6.18.55 |
| Host/affinity | Reported AMD EPYC 9V74, nine logical CPUs available, inherited CPU affinity `[8]` |

The host is shared; affinity does not create an isolated physical machine.
Kyoto was unavailable. Builds ran serially in isolated output directories, and
the fresh cohort ran outside the sandbox from its first invocation. The component
and row measurements did not overlap. The toolchain archive has verified release
signature and digest provenance in the evidence.

Each variant is an optimized production shared library called by a separately
compiled common driver, using `-O -whole-module-optimization` without cross-module
optimization. This prevents fixture specialization across the module boundary;
the exact application's optimizer context can still differ. Fixtures, warmup,
full JSON encoding, and validation occur outside timing. Label intervals include
small byte-count and bounded result-array handling; no empty loop is subtracted.

Each case uses ten fresh-process pairs, five AB and five BA, with equal iteration
counts for both variants. Calibration targets at least 100 ms for the faster
variant, and label workload order rotates between pairs. Pilots are retained
separately. All **220 label/recognition observations** and **200 row observations**
are included, without outlier removal. Wall time uses `DispatchTime`; process CPU
uses `CLOCK_PROCESS_CPUTIME_ID`.

Positive percentages below mean less time. They are medians of the ten paired
`100 × (1 − candidate / baseline)` reductions. Absolute medians are calculated
independently, so their ratio need not reproduce the paired percentage. These
descriptive medians are not population-level confidence or significance claims.

## Label and recognition results

Times are nanoseconds per operation, with 128 inputs per batch. `cached-*` means
already recognized metadata, not a previously formatted label. `recognize-*`
includes complete filename recognition before display formatting.

| Workload | Baseline ns | Candidate ns | Paired wall reduction | Paired CPU reduction | Faster pairs |
| --- | ---: | ---: | ---: | ---: | ---: |
| `cached-numbered` | 1,958.04 | 270.29 | 86.49% | 86.49% | 10/10 |
| `cached-ranges` | 3,555.98 | 290.36 | 91.94% | 91.93% | 10/10 |
| `cached-wide-numbers` | 1,779.72 | 158.07 | 91.05% | 91.04% | 10/10 |
| `cached-unicode-titles` | 1,970.03 | 263.68 | 86.58% | 86.58% | 10/10 |
| `cached-dated-control` | 132.65 | 131.57 | 0.92% | 0.90% | 7/10 |
| `cached-movie-control` | 156.39 | 160.11 | -1.60% | -1.60% | 4/10 |
| `cached-unknown-control` | 111.81 | 114.46 | -3.74% | -3.75% | 2/10 |
| `cached-unbounded-control` | 3,568.36 | 3,561.88 | 0.62% | 0.62% | 6/10 |
| `recognize-numbered` | 45,239.89 | 43,519.79 | 4.40% | 4.41% | 9/10 |
| `recognize-ranges` | 40,275.18 | 35,479.60 | 11.95% | 11.95% | 10/10 |
| `recognize-mixed` | 44,671.94 | 40,487.38 | 7.00% | 7.00% | 8/10 |

The consistent reduction belongs to the four ordinary numbered-label cases.
Dated, movie, and unknown controls retain their formatting paths; their paired
wall medians range from **-3.74% to 0.92%**.
The `cached-unbounded-control` fixture uses cyclic unusual integer triples.
Every triple contains a negative or above-`Int32.max` component, so the adopted
candidate takes the complete original Foundation expression on every record.
The new bounds guard is still included in its measured cost.

Recognition-inclusive timings are a broader operation and support a less direct
conclusion than isolated label construction. The least favorable recognition-inclusive pair is `recognize-mixed` at **1.50% slower** in the candidate.
Every observation remains in the receipts. The current report confines its
primary performance claim to the targeted label workloads.

## Complete media-row results

The row study compiles twelve real production files or guarded verbatim model
declarations. Only the focal recognition file differs between baseline and
candidate. It measures complete `input.rows()` calls with production default
sorting: creation date descending, name/type sorting off. Timed work includes
path processing, sorting, context labels, display strings, and row allocation.
The previous result stays alive until its replacement returns. Directory
enumeration, sidecar reads, file opening, SwiftUI, and playback are excluded.

Times are milliseconds per reconstruction or cached actor projection for the
stated number of input files.

| Workload | Files | Baseline ms | Candidate ms | Paired wall reduction | Paired CPU reduction | Faster pairs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `precomputed_episodes` | 100 | 2.153 | 1.906 | 13.05% | 13.07% | 9/10 |
| `precomputed_episodes` | 1,000 | 18.142 | 15.955 | 11.37% | 11.38% | 9/10 |
| `unprepared_episodes` | 100 | 6.503 | 6.213 | 5.69% | 5.64% | 9/10 |
| `unprepared_episodes` | 1,000 | 71.623 | 67.967 | 5.33% | 5.36% | 8/10 |
| `mixed_library` | 100 | 1.705 | 1.610 | 7.71% | 7.72% | 8/10 |
| `mixed_library` | 1,000 | 16.216 | 15.834 | 2.90% | 2.94% | 8/10 |
| `movies_control` | 100 | 1.217 | 1.204 | 1.64% | 1.64% | 7/10 |
| `movies_control` | 1,000 | 13.260 | 13.213 | -0.20% | -0.25% | 5/10 |
| `cached_projection_control` | 100 | 0.609 | 0.620 | -1.17% | -1.15% | 4/10 |
| `cached_projection_control` | 1,000 | 7.006 | 7.095 | -1.94% | -1.96% | 5/10 |

The precomputed-episode cases have favorable wall medians: 13.05% at 100 files (9/10 favorable pairs); 11.37% at 1,000 files (9/10 favorable pairs).

The movie and cached-projection control medians span **-1.94% to 1.64%**; their individual pairs vary in both directions. These small control changes do not establish a systematic improvement or regression. The least favorable individual row pair is `unprepared_episodes` at 1,000 files, **55.11% slower**.

The row results support a benefit in these synthetic reconstruction cases, with
variation that limits broader predictions. They do not establish a generally
faster media browser. The cache control uses a real `SourceBrowserFilter` actor; its
tree and visibility build counters remain at one through repeated unchanged-input
projections. That confirms labels are reused on this path. Native and live-app
measurements remain necessary before assigning a user-visible latency benefit.

## Correctness and qualification status

Baseline and candidate each pass **47 tests in five suites in debug and release**,
for four completed invocations. The suites combine the three existing recognition
suites, #141's eight episode-formatting tests, and seven follow-up tests. They
exhaust all values from zero through 9,999 in each numeric role—a subset of the
nonnegative `Int32` fast path—and include 4,096 deterministic positive-`Int32`
samples, signed/overflow boundaries, nils, date precedence, exact title bytes,
non-episode kinds, and public metadata-hint application.

Both variants produce **5,767 byte-identical complete differential records**.
All ten complete row/projection trace pairs match, including metadata, UTF-8
bytes, IDs, order, visibility, and projection outputs. Every timed process checks
its complete final result outside the clock.

The intact historical comparison was rerun for the adopted candidate and
remains **failed on Linux**. Its second input is bare `"."`, which traps in this
Linux Foundation runtime's `NSString.deletingLastPathComponent` before recognition
returns. Focused probes retained with this cohort reproduce the same trap in a
Foundation-only executable, the frozen baseline, and the adopted #141 candidate.
The probes bind the result to the current compiled module and preserve their
commands, hashes, and raw failure logs. This is a recorded runtime limitation,
not a passed equivalence check. No input or frozen source was removed to conceal
it.

| Qualification | Current status |
| --- | --- |
| Focused Linux tests | Passed: four invocations, 47 tests each, five suites |
| Focused label differential | Passed: 5,767 complete records |
| Row/projection differential | Passed: ten cases and all final timed outputs |
| Portable GitHub correctness on the measured commit | Passed |
| Independent receipt audits | Passed for both experiments |
| Historical Linux comparison | Failed on the pre-existing Foundation bare-dot path trap |
| Native macOS measurements and intact historical comparison | Pending |
| Native application graph build and affected tests | Pending |
| Live UI or playback qualification | Not performed |

The [portable correctness job](https://github.com/Jagalite/illiquid/actions/runs/40756021516/job/123055027201)
passed on the measured commit, including the focused tests and complete label/row
comparisons. The [workflow](../.github/workflows/media-display-name.yml) provides pinned Swift
6.3.3 portable correctness, native macOS measurements with the intact historical
corpus, and a separate native application build/test job. Consult the draft PR's
current checks; queued jobs are not completed qualification.

## Earlier candidate and reproduction

An independent formatter was researched before reconciling this work with #141.
Its [report](https://github.com/Jagalite/illiquid/blob/46f5384474e08bd04d6b20b5ab7a13adacdb01bf/Documentation/MEDIA_DISPLAY_NAME_PERFORMANCE.md)
and [complete evidence](https://github.com/Jagalite/illiquid/tree/46f5384474e08bd04d6b20b5ab7a13adacdb01bf/Benchmarks/MediaDisplayName/evidence/linux)
remain available at the immutable earlier commit. That candidate used different
production bytes and a narrower fast path. Adopting #141 therefore required the
fresh tests and measurements reported here; **none of the earlier candidate's
timings enters these tables**.

The earlier investigation's sandbox/libdispatch test failure and successful
retry belong to that earlier cohort, not this clean outside-sandbox rerun. An
even earlier exploratory screen lost its raw receipts during a session reset;
its numbers are used in neither retained result set.

Use fresh output directories and follow `AGENTS.md` to submit builds through
Kyoto when available. Select a Swift toolchain through `PATH` or the runners'
documented overrides:

```sh
python3 Benchmarks/MediaDisplayName/run.py \
  --pairs 10 --target-ms 100 --output /tmp/media-display-name-new
python3 Benchmarks/MediaDisplayNameProjection/run.py \
  --pairs 10 --target-ms 100 --output /tmp/media-display-projection-new
# Native macOS: retain the complete historical filename corpus.
python3 Benchmarks/MediaNameRecognition/run.py \
  --verify-only --output /tmp/media-display-historical-new
```

The [label](../Benchmarks/MediaDisplayName/README.md) and
[row](../Benchmarks/MediaDisplayNameProjection/README.md) guides define measurement
boundaries and outputs. The retained archive contains raw observations, pilots,
commands, source snapshots, full traces, test/build logs, environment/toolchain
provenance, and audits. Compiled products and caches are omitted; binary hashes
and build commands remain. The [evidence receipt](../Benchmarks/MediaDisplayName/evidence/linux/receipt.json)
records the archive digest and source match. Final narrative/evidence edits do
not change the measured production, tests, or benchmark executables' inputs.
