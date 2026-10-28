> Requalification in progress: this follow-up now uses the exact implementation
> from [PR #141](https://github.com/Jagalite/illiquid/pull/141). The retained results
> below describe the earlier independent candidate at `99bb8f9`; fresh tests and
> measurements for the adopted implementation are being collected before handoff.

# Episode display-name formatting research

## Result and qualification

Replacing Foundation format-string calls for ordinary numbered episode labels
reduces their median paired construction time by **86.96–91.97% on the measured
Linux host**. The candidate is faster in all ten pairs for each of the four
targeted label workloads. Process CPU measurements closely agree with wall time.
This supports the small formatting change as a component optimization.

**Native macOS qualification is pending.** The native benchmark and application
build/test jobs were queued without an assigned runner at publication. This work
is proposed as a draft PR until those checks complete. Linux measurements do not
establish macOS, SwiftUI, playback, or whole-player latency improvements.

The surrounding media-row experiment has favorable episode-heavy medians, but
also adverse unchanged-path controls and large individual deviations. Treat those
numbers as exploratory observations, not a reliable whole-row speedup claim.
All completed observations, including slowdowns, are retained.

The primary evidence is the [component summary](../Benchmarks/MediaDisplayName/evidence/linux/component-summary.json),
[row summary](../Benchmarks/MediaDisplayName/evidence/linux/projection-summary.json),
and [complete evidence archive and provenance](../Benchmarks/MediaDisplayName/evidence/linux/README.md).
Independent audits reproduce both summaries from the raw observations.

## Production change and actual call site

[`RecognizedMediaName.displayName`](../Sources/IlliquidCore/MediaLibrary/MediaNameRecognition.swift)
previously constructed the numeric label with `String(format: "S%02dE%02d", ...)`
and an optional second formatter for the final episode. It now constructs decimal
strings directly for values from 0 through 9,999, adding a leading zero below ten.
It retains the original combined Foundation formatter when either season or
episode is outside that range, and an equivalent Foundation fallback for a range
endpoint outside it. This preserves signed C-integer conversion of arbitrary
metadata-hint values, including values beyond `Int32`.

The public property and returned bytes are unchanged. Nil numeric fields still
become zero; air dates (including an empty nonnil date) still bypass numeric
formatting; range and title separators, Unicode, empty titles, and non-episode
labels retain their existing behavior. The change introduces no cache or mutable
shared state.

The real application path is
[`SourcesSidebar.synchronizeRecursiveMediaScan`](../Sources/IlliquidApp/UI/SourcesSidebar.swift)
→ `SourceRecursiveMediaLoader` →
[`MediaSidecarReader.recognize`](../Sources/IlliquidCore/MediaLibrary/MediaSidecarReader.swift)
→ `refreshVisibleRows` →
[`SourceBrowserFilter.project`](../Sources/IlliquidApp/UI/SourceBrowserFilter.swift)
→ [`SourceTreeProjectionInput.rows` / `makeFlatFileRows`](../Sources/IlliquidApp/UI/SourceTreeProjectionInput.swift).
Normal media scans provide already recognized metadata, but the row builder still
computes each episode's display string. Rows store the resulting string.

The expected benefit therefore applies when media-view rows are rebuilt after a
scan or relevant source/sort/view changes. Search and visibility edits that reuse
`cachedRows` already reuse those strings; they should not gain from this formatter.
Filesystem discovery, sidecar I/O, UI presentation, and playback are outside the
changed work and outside these measurements.

## Baseline, environment, and method

- Frozen baseline: `ea2ff568237e2667f7b1aeee67b11a44ebe95b72` (integrated main).
- Measured candidate: `99bb8f974e5bfd5ac553f72cab748cd579b691b4`.
- Candidate production SHA-256: `23f7087e073215e7fd1d803cf25a2aeb96fc702a4707adf13ac4f6d21b4261ef`.
- Environment: shared Ubuntu 24.04.3 x86_64 host, Linux 6.18.55, Swift 6.3.3 release.
  The host reports an AMD EPYC 9V74 processor; nine logical CPUs were available.
  Every final process inherited affinity to CPU 8. This is not an isolated physical
  machine, and that affinity does not eliminate shared-host noise.
- Kyoto was unavailable, so builds ran serially in isolated output directories.
  Final runs executed outside the sandbox after the baseline runtime failure
  described below. Neither benchmark overlaps the other in time.
- Separate optimized production libraries and independently compiled drivers use
  `-O -whole-module-optimization`, without cross-module optimization. Static `nm`
  and disassembly receipts confirm the timed label loop calls the external
  production getter/recognizer rather than a folded fixture result.
- Each workload uses ten fresh-process pairs, five AB and five BA, with identical
  iteration counts per variant. Calibration targets at least 100 ms for the faster
  variant. Pilots remain separate from final measurements. Label workload order
  rotates between pairs. No observations or outliers were removed.
- Fixture setup, warmup, complete JSON serialization, and validation are outside
  the timers. Wall time uses `DispatchTime`; CPU time uses
  `CLOCK_PROCESS_CPUTIME_ID`. No empty-loop timing is subtracted.

There are **220 final label/recognition observations** and **200 final row
observations**. Positive paired reductions mean less time. The primary statistic
is the median of each pair's `100 × (1 − candidate / baseline)`; absolute medians
are calculated independently and therefore need not produce the same percentage.
This report does not attach statistical-significance or population-wide claims
to those medians.

## Label and recognition observations

Times below are nanoseconds per operation. Each batch has 128 inputs. `cached-*`
means already recognized metadata, not a cached formatted string. `recognize-*`
includes full filename recognition before constructing the label.

| Workload | Baseline ns | Candidate ns | Paired wall reduction | Paired CPU reduction | Faster pairs |
| --- | ---: | ---: | ---: | ---: | ---: |
| `cached-numbered` | 1,943.37 | 258.03 | 87.02% | 87.02% | 10/10 |
| `cached-ranges` | 3,443.05 | 278.17 | 91.97% | 91.96% | 10/10 |
| `cached-wide-numbers` | 1,760.70 | 148.55 | 91.54% | 91.54% | 10/10 |
| `cached-unicode-titles` | 2,031.50 | 250.80 | 86.96% | 86.96% | 10/10 |
| `cached-dated-control` | 127.94 | 132.95 | -1.79% | -1.79% | 5/10 |
| `cached-movie-control` | 166.32 | 158.15 | 4.79% | 4.81% | 7/10 |
| `cached-unknown-control` | 118.74 | 117.65 | 2.15% | 2.14% | 6/10 |
| `cached-unbounded-control` | 3,513.58 | 3,106.79 | 10.80% | 10.80% | 7/10 |
| `recognize-numbered` | 45,615.84 | 43,763.97 | 5.64% | 5.66% | 6/10 |
| `recognize-ranges` | 37,322.84 | 35,935.45 | 9.08% | 9.08% | 8/10 |
| `recognize-mixed` | 38,830.04 | 37,780.37 | 3.92% | 3.93% | 7/10 |

The four bounded-number label cases are the defensible result: all 40 paired
comparisons favor the candidate, and even their least favorable pair reduces time
by 82.54%. Dated, movie, and unknown labels are unchanged-path controls; their
paired medians range from −1.79% to +4.79%, with individual deviations in both
directions. The unbounded case is a compatibility workload, not an unchanged
control, because range-prefix construction changes even when numeric formatting
falls back to Foundation.

The recognition-inclusive results are not a firm broader speedup claim. For
example, `recognize-ranges` contains a pair that is **64.09% slower** in the
candidate. That observation remains in the summary and raw data. The large,
consistent targeted reduction is much clearer than these surrounding differences.

## Complete media-row observations

The row experiment compiles twelve real production files or guarded verbatim
model declarations; only the focal recognition file differs. It uses production
default sorting (creation date descending, name and type sorting off). It measures
complete `input.rows()` calls, including path handling, date sorting, context
labels, display strings, and row allocation. The previous result remains alive
until its replacement returns. It excludes directory enumeration, sidecar reads,
file opening, SwiftUI work, and playback.

Times are milliseconds per complete reconstruction or cached actor projection
for the stated number of input files.

| Workload | Files | Baseline ms | Candidate ms | Paired wall reduction | Faster pairs |
| --- | ---: | ---: | ---: | ---: | ---: |
| `precomputed_episodes` | 100 | 1.928 | 1.634 | 12.54% | 9/10 |
| `precomputed_episodes` | 1,000 | 18.245 | 17.388 | 8.34% | 8/10 |
| `unprepared_episodes` | 100 | 5.976 | 5.740 | 4.74% | 9/10 |
| `unprepared_episodes` | 1,000 | 63.032 | 58.801 | 10.16% | 10/10 |
| `mixed_library` | 100 | 1.664 | 1.558 | 6.34% | 8/10 |
| `mixed_library` | 1,000 | 17.400 | 15.919 | 4.43% | 7/10 |
| `movies_control` | 100 | 1.295 | 1.262 | 1.97% | 8/10 |
| `movies_control` | 1,000 | 13.597 | 15.062 | -9.72% | 2/10 |
| `cached_projection_control` | 100 | 0.705 | 0.669 | 1.19% | 5/10 |
| `cached_projection_control` | 1,000 | 6.717 | 7.246 | -3.62% | 2/10 |

CPU paired medians closely track these wall-time results. Episode reconstruction
has favorable medians, but the 1,000-file movie control is **9.72% slower**, and
the cached-projection control is **3.62% slower**. The precomputed 1,000-episode
case also has a single pair that is **61.27% slower**. These observations limit the
strength of a surrounding-row claim; they are not discarded or explained away.

The cache control uses the real `SourceBrowserFilter` actor. Its tree and
visibility build counters stay at one throughout repeated unchanged-input
projections, confirming that the optimized formatter is not re-executed there.
Native or live-app measurements are needed before assigning a user-visible
latency benefit.

## Correctness, failures, and pending checks

The focused baseline and candidate each pass **28 tests in three suites in debug
and release**, for four completed invocations. The seven new tests exhaust all
10,000 fast-path numbers in each numeric role and cover nils, signed/overflow
boundaries, public metadata hints, date precedence, non-episode kinds, and exact
Unicode/title bytes. See
[`MediaDisplayNameTests.swift`](../Tests/IlliquidCoreTests/MediaDisplayNameTests.swift).

Both variants produce **5,767 byte-identical complete differential records**.
All ten complete row/projection trace pairs match, including every field,
recognized metadata, UTF-8 bytes, IDs, ordering, visibility, and cache outputs.
Every timed process checks its complete final output outside the clock.

The initial baseline release test attempt crashed in libdispatch's worker-pool
monitor after failure to open `/proc/<thread-id>/stat`, before the relevant test
body. The identical already-built binary passed all 28 tests outside the sandbox,
and a fresh complete four-invocation qualification then passed there. Static
symbol/disassembly analysis identifies the failing runtime operation; whether
sandbox process visibility or a thread-lifecycle race caused the missing entry
is not established. The failed log, successful retry, and analysis are retained.
No timing observations came from that failed attempt.

The older historical recognition verifier remains **failed on Linux**. Its
unchanged corpus includes bare `"."`, which traps in Linux Foundation's
`NSString.deletingLastPathComponent` before recognition returns. A Foundation-only
probe with no application module, the frozen baseline, and the candidate all
reproduce the same failure. Empty string, `/`, and `..` succeed in all three.
The oracle and corpus were not weakened or patched. The complete historical
comparison remains a native macOS gate; the new portable CI job checks the
focused label and complete-row comparisons.

| Qualification | Status at publication |
| --- | --- |
| Focused Linux debug/release baseline and candidate tests | Passed: 28 tests per invocation |
| Focused complete label differential | Passed: 5,767 records |
| Complete row/projection differential | Passed: 10 cases and all final timed outputs |
| Raw measurement/source/log audits | Passed for both experiments |
| Historical recognition oracle on Linux | Failed on pre-existing Foundation bare-dot path trap |
| Native macOS benchmark and intact historical oracle | Pending runner/execution |
| Native application graph build and affected tests | Pending runner/execution |
| Live UI or playback qualification | Not performed |

The [workflow](../.github/workflows/media-display-name.yml) provides a pinned
Swift 6.3.3 portable correctness job, native macOS measurements and the intact
historical verifier, plus a separate native application graph build and affected
media/browser tests. The initial native
[qualification run](https://github.com/Jagalite/illiquid/actions/runs/40751950302)
was queued; the PR workflow supersedes that preliminary run. Check the PR's
current checks for native status rather than treating queued work as a pass.

An earlier exploratory Linux screen lost its raw receipts during a session reset.
Its numbers are excluded from this report. All reported values come from the
fresh retained cohort above. The final evidence/documentation/workflow commit
leaves the measured production, test, and benchmark source bytes unchanged.

## Reproduction and evidence

Use a fresh output directory for each command and follow `AGENTS.md` to submit
builds through Kyoto when available. Select the desired Swift toolchain through
`PATH` (or the runners' documented overrides).

```sh
python3 Benchmarks/MediaDisplayName/run.py \
  --pairs 10 --target-ms 100 --output /tmp/media-display-name-new
python3 Benchmarks/MediaDisplayNameProjection/run.py \
  --pairs 10 --target-ms 100 --output /tmp/media-display-projection-new
# Native macOS: preserve the complete historical filename corpus.
python3 Benchmarks/MediaNameRecognition/run.py \
  --verify-only --output /tmp/media-display-historical-new
```

The [label runner](../Benchmarks/MediaDisplayName/README.md) and
[row runner](../Benchmarks/MediaDisplayNameProjection/README.md) document exact
boundaries and output formats. The retained archive contains raw observations,
pilots, commands, source snapshots, full output traces, test/build logs, source and
binary hashes, environment/toolchain provenance, failure diagnostics, and both
independent audits. Compiled products and caches are omitted; their hashes and
build commands remain. The [evidence receipt](../Benchmarks/MediaDisplayName/evidence/linux/receipt.json)
records the archive digest and verifies measured input bytes against the final
source tree.
