# Track selection during authority projection

**Date:** October 21, 2026.

**Baseline:** `a2de305c8dbcaa81aac1477df7c9a0017c14eae3`.

**Measured candidate:** `d2b04d8e2fc04b6bb71afc5975f8530d08e60734`.

**Decision:** keep the focused change. Native measurements show a repeatable
reduction in unchanged-selection work, especially for late selections and
subtitles off. This is a small component optimization: the application already
limits ordinary position events to approximately 4 Hz. It does not establish a
noticeable playback or UI improvement. Frequent selection changes have a small
observed cost increase in one native control, documented below.

The measured production code, tests, harness, and runner are byte-identical to
the submitted files. The later evidence/report commit changes documentation and
retains receipts; it does not change measured executable inputs.

## Question and change

Every authority projection resolves the selected audio and subtitle IDs against
their track catalogues. Position changes normally retain those IDs, so the
baseline repeats the same linear searches and selected-track metadata equality
checks. Late or missing selections make the repeated search scale with catalogue
length. An absent subtitle selection also enters the baseline search.

The candidate changes only `PlaybackState.swift` in production. It remembers
the last requested ID for each track kind and whether resolution is needed.
Unchanged requests reuse the existing selected value. A catalogue mutation,
direct selected-value write, or changed requested ID triggers another resolution.
Nil requests resolve directly to nil, and missing nonnil requests are remembered
until invalidated. Resolution retains first-match ordering for duplicate IDs.

The four bookkeeping fields are excluded from Observation. There is no second
track collection or ID-to-track map. Invalidation happens before the existing
mutation callback. Resolution clears its flag before assigning the selected
value, so a synchronous Observation callback that changes a catalogue cannot
have its invalidation erased. An actual selected-value assignment conservatively
causes one more resolution on the next projection.

This follows the late-selection and subtitles-off research question in the
[fifth publication pass](NONDECODING_PERFORMANCE_FIFTH_PASS.md). The earlier
batching and catalogue-partitioning optimizations remain in the baseline.

## Measurement method

The primary cohort ran on GitHub's **Apple M1 (Virtual)** runner, macOS **26.6.2**
(25G83), **Xcode 26.6**, and **Apple Swift 6.3.3**, targeting arm64 macOS 26.
It is a macOS VM measurement, not a physical-Mac measurement. The checkout was
clean and pinned to the candidate above. The host/compiler record is retained.

The [reproducible runner](../Benchmarks/TrackSelectionProjection/README.md)
compiles 17 actual production source files into separate baseline/candidate
`IlliquidCore` static modules. Both use the same client harness, Foundation,
Observation, tests, and compiler options. Source hashes require that only
`PlaybackState.swift` differs among production inputs. Release timing uses
Swift 6 mode, optimization, and whole-module optimization; the client is compiled
separately from the module. Both variants have the same macOS deployment target.

The connected fixture uses the production `PlaybackViewSnapshot` constructor
and `PlaybackViewStore.publish` in the state mutation callback, matching the
application connection. Its playlist has 24 synthetic entries. Construction,
200 warmup calls, result checking, and JSON encoding are outside the timer.
Positions change on every timed call. Each timing observation starts a fresh
process. Eight paired rounds alternate AB then BA, giving equal process order
and 16 observations per workload. All completed observations are retained.
The timer also includes identical fixture workload dispatch, selected-ID
preparation, and projection-value construction on both sides.

The full cohort has 28 workloads and 448 timing observations. Stable first,
last, absent-subtitle, and missing-ID requests run at 1/0, 2/8, 8/32, 16/128,
and 16/1,024 audio/subtitle tracks. Selection-switch and catalogue-refresh
controls run at three sizes. Two disconnected controls isolate the projection
from view publication. Ordinary workloads use 20,000 calls per process;
catalogue refresh uses 5,000. Both wall and process CPU time are recorded.

## Native results

The table gives wall-time medians per complete connected state-to-view update.
The percentage is candidate median divided by baseline median, minus one.
The ordinary and larger catalogues are synthetic fixtures, not a distribution
of tracks observed in users' media libraries.

| Request | Audio / subtitle tracks | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: | ---: |
| First track; no subtitle catalogue | 1 / 0 | 3.324 µs | 2.939 µs | −11.6% |
| First selected tracks | 2 / 8 | 3.586 µs | 2.806 µs | −21.7% |
| Last selected tracks | 2 / 8 | 5.710 µs | 3.105 µs | −45.6% |
| Last audio; subtitles off | 2 / 8 | 4.511 µs | 2.763 µs | −38.8% |
| Last selected tracks | 8 / 32 | 10.341 µs | 3.054 µs | −70.5% |
| Last audio; subtitles off | 8 / 32 | 10.489 µs | 3.095 µs | −70.5% |
| Last selected tracks | 16 / 128 | 26.524 µs | 3.097 µs | −88.3% |
| Last audio; subtitles off | 16 / 128 | 25.719 µs | 2.889 µs | −88.8% |
| Missing audio and subtitle IDs | 16 / 128 | 28.170 µs | 3.186 µs | −88.7% |
| Last selected tracks, scaling stress | 16 / 1,024 | 179.764 µs | 3.072 µs | −98.3% |

For connected last-selection requests at 2/8, 8/32, and 16/128, the candidate
is faster in **all eight paired rounds**. Their median within-pair wall-time
changes are −42.2%, −69.5%, and −88.1%; process-CPU median changes are −45.1%,
−70.4%, and −88.3%. This supports a reduction in computation rather than a
claim based solely on elapsed-time scheduling differences.

All 20 stable-request native wall medians improve, including the first-track
controls. The 1/0 `first`, `last`, and `subtitles_off` cases are intentionally
equivalent selection configurations measured separately; they are not three
different media behaviors. Missing requests show the same scaling benefit.
The two disconnected 16/128 controls fall from 25.912 → 0.338 µs for last
selections and 22.974 → 0.306 µs with subtitles off. The connected results
above are the application-relevant headline because they retain publication.

### Changing-selection and catalogue controls

These workloads intentionally invalidate resolution every call. They provide
no general speedup or no-regression claim. The table includes both ways to
summarize paired measurements because broad ranges can make them disagree.

| Control | Audio / subtitle tracks | Wall median, baseline → candidate | Change of medians | Median paired change | CPU median change |
| --- | ---: | ---: | ---: | ---: | ---: |
| Switch first/last every call | 2 / 8 | 8.288 → 8.765 µs | +5.7% | +7.1% | +8.1% |
| Refresh catalogue every call | 2 / 8 | 17.323 → 14.310 µs | −17.4% | +4.0% | −17.4% |
| Switch first/last every call | 8 / 32 | 11.008 → 10.838 µs | −1.5% | +0.4% | +0.4% |
| Refresh catalogue every call | 8 / 32 | 30.372 → 31.136 µs | +2.5% | +0.3% | +3.3% |
| Switch first/last every call | 16 / 128 | 19.167 → 17.072 µs | −10.9% | −4.9% | −5.4% |
| Refresh catalogue every call | 16 / 128 | 60.815 → 58.308 µs | −4.1% | −2.4% | −5.0% |

The 2/8 switching control adds **0.476 µs** to its native wall median. Baseline
observations range from 7.126–12.045 µs and candidate observations from
7.112–11.646 µs. Those ranges overlap, but the positive paired and CPU changes
mean the result must not be called neutral. The 8/32 catalogue-refresh median
also rises **0.764 µs**. Both are retained as measured tradeoffs.

The apparent −17.4% 2/8 refresh improvement is particularly unstable: only
three of eight pairs favor the candidate, and its median paired change is
+4.0%. No reliable catalogue-refresh improvement is claimed. Raw observations,
all min/max ranges, and within-pair ratios are retained without exclusions.

### Separate Linux corroboration

A complete second 28-workload/448-observation cohort used Linux x86_64 and
official Swift 6.3.2. It independently passed the same four behavior builds
and differential comparisons. It is retained separately and is not combined
with native measurements. The checkout had only evidence/documentation edits;
source, test, harness, and runner hashes match the measured candidate.

Linux connected last-selection medians fall 8.103 → 5.467 µs at 2/8,
25.753 → 7.560 µs at 16/128, and 143.607 → 6.870 µs at 16/1,024. First-track
and mutation controls are mixed. In particular, the 2/8 switch control rises
7.875 → 10.088 µs (**+28.1% wall, +27.4% CPU**, an additional 2.212 µs per
call). This reinforces the need to disclose mutation-path costs rather than
claiming that every update becomes faster.

## Validation

The [native qualification run](https://github.com/Jagalite/illiquid/actions/runs/39666984985)
built and linked the full macOS debug application/test dependency graph,
including `Illiquid` and `IlliquidPackageTests`. All **37 selected native tests**
passed with zero failures and no skips: 15 existing state-publication tests,
10 new track-projection tests, 9 state-transition tests, and 3 coordinator
track/subtitle acknowledgement and restoration tests. This is a targeted native
test run, not the entire repository suite or a real-media GUI playback run.

On each platform, the component harness also passes **25 shared scenarios and
2,388 assertions per build** for baseline and candidate in both debug and
release. These are repeated executions of scenario bodies, not additional
distinct native tests. The 4,000-step mixed-operation traces match exactly in
each configuration, including complete selected-track metadata, catalogue
contents/order, positions, and mutation callback counts. Every process also
asserts that its full published view equals its state. This differential trace
does not serialize every playback field across variants. All eight trace
digests across both platforms are identical.

All 448 timed-process receipts per platform match within their workload,
including expected callback counts: one per connected ordinary update, two
per catalogue-refresh iteration, and zero in disconnected controls. The
source receipts verify that only `PlaybackState.swift` differs between the
baseline and candidate production modules. All measured candidate inputs
match the submitted bytes. Independent review rechecked process ordering,
summary arithmetic, receipt equality, source identity, and the controls.

The ten new scenarios cover stable late selections, nil/ID transitions, missing
tracks appearing or disappearing, same-ID metadata replacement, duplicate-ID
order and in-place catalogue mutation, independent catalogues, metadata resets,
direct selected-value writes, synchronous Observation reentrancy, and immediate
reprojection from a catalogue mutation callback.

## Scope and practical limits

The timed operation is a synchronous model update plus view-store publication.
It does not include decoding, rendering, SwiftUI layout, presentation, or waiting
to enter the main actor. Synthetic quarter-second position advances are processed
in a tight loop, not at real playback speed. The native runtime ordinarily emits
position events approximately four times per second, with other events also
producing projections. A component percentage reduction therefore does not
measure whole-player CPU, frame rate, battery, or visible latency.

For scale, the 2/8 and 16/128 last-selection median savings are 2.605 µs and
23.426 µs per call. At four position events per second, those differences
arithmetically correspond to roughly **10 µs and 94 µs of this synchronous
work per second**, before other events. That is not a whole-player CPU
measurement. The rationale for keeping the patch is its small production
surface, preserved semantics, and removal of catalogue-size-dependent repeated
work; the native numbers do not justify a broader observation rewrite.

The 1,024-subtitle catalogue is a scaling stress case. Its gain is not an estimate
for a typical file. Changing selections and catalogues still need lookup and
comparison work; their measurements must be considered alongside steady-state
results. Absolute costs and variability matter more than large percentages for
very short operations. Physical-Mac performance, live playback, allocations,
resident memory, and energy are unmeasured here.

## Evidence and reproduction

- [Benchmark and reproduction instructions](../Benchmarks/TrackSelectionProjection/README.md)
- [Complete native measurements, source receipts, tests, host, and validation](../Benchmarks/TrackSelectionProjection/Results/2026-10-21-macos/)
- [Separate complete Linux measurements and validation](../Benchmarks/TrackSelectionProjection/Results/2026-10-21-linux/)
- [Baseline projection implementation](https://github.com/Jagalite/illiquid/blob/a2de305c8dbcaa81aac1477df7c9a0017c14eae3/Sources/IlliquidCore/Player/PlaybackState.swift)
- [Candidate projection implementation](https://github.com/Jagalite/illiquid/blob/d2b04d8e2fc04b6bb71afc5975f8530d08e60734/Sources/IlliquidCore/Player/PlaybackState.swift)
- [Application state-to-view connection](https://github.com/Jagalite/illiquid/blob/a2de305c8dbcaa81aac1477df7c9a0017c14eae3/Sources/IlliquidPlayer/Player/PlaybackController.swift)
- [Native position emission cadence](https://github.com/Jagalite/illiquid/blob/a2de305c8dbcaa81aac1477df7c9a0017c14eae3/Sources/IlliquidNativePlayback/Production/NativePlaybackRuntime.swift)
