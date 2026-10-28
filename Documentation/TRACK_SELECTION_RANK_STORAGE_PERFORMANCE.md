# Track selection rank storage research

Date: October 28, 2026.

## Result and qualification status

Retain the candidate as a **draft pending native macOS qualification**.
On the Linux x86_64/Swift 6.2.1 component run, eight-track audio selection
without language preferences fell from **1.2495 to 1.0559 µs** per selection
(**15.49% less elapsed time**). The 32-track case improved **19.52%**, and
eight-track subtitle Always selection improved **14.32%**. Every one of the
ten pairs improved for these workloads and for the two-track no-language case.

The absolute savings are small: about **0.194 µs** for eight-track audio and
**0.820 µs** for 32-track audio. These are warmed component measurements, not
an established improvement in media-open latency or visible playback.

The native [macOS qualification run](https://github.com/Jagalite/illiquid/actions/runs/40636409015)
was still queued when this report was prepared. No macOS timing, application
build, native release-suite result, or live playback qualification is claimed.

## Portable measurements

The successful [Linux run](https://github.com/Jagalite/illiquid/actions/runs/40639259602)
measured commit `4272fc9ce7188e4eeddff46ac8c1de317eed8ad3` against
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`. The portable research branch differs
from the native candidate only in its additional container workflow. Reviewed
production, driver, runner, and test source hashes match the execution receipts.

Each value below is a median elapsed time per selection. Negative change means
less time; percentages use the ratio of candidate and baseline medians.

| Workload | Baseline (µs) | Candidate (µs) | Elapsed-time change | Faster pairs |
| --- | ---: | ---: | ---: | ---: |
| `audio-0-none` | 0.1411 | 0.1407 | -0.29% | 6/10 |
| `audio-0-languages` | 21.5213 | 21.5560 | +0.16% | 3/10 |
| `audio-1-none` | 0.2192 | 0.2219 | +1.24% | 3/10 |
| `audio-1-languages` | 21.6039 | 21.6535 | +0.23% | 5/10 |
| `audio-2-none` | 0.4435 | 0.4121 | -7.08% | 10/10 |
| `audio-2-languages` | 38.7589 | 38.6365 | -0.32% | 5/10 |
| `audio-8-none` | 1.2495 | 1.0559 | -15.49% | 10/10 |
| `audio-8-languages` | 84.1577 | 82.2820 | -2.23% | 7/10 |
| `audio-32-none` | 4.1990 | 3.3794 | -19.52% | 10/10 |
| `audio-32-languages` | 260.0866 | 261.0982 | +0.39% | 6/10 |
| `subtitle-automatic` | 0.6899 | 0.7099 | +2.90% | 0/10 |
| `subtitle-off` | 6.2506 | 6.2282 | -0.36% | 6/10 |
| `subtitle-always` | 1.3051 | 1.1182 | -14.32% | 10/10 |
| `subtitle-forced-languages` | 94.6933 | 94.0273 | -0.70% | 8/10 |
| `subtitle-forced-audio-fallback` | 60.6752 | 59.9426 | -1.21% | 7/10 |
| `mutable-preferences` | 110.6167 | 109.8859 | -0.66% | 7/10 |

### Controls and limits

Automatic subtitle selection is a consistent small regression in this run:
**0.6899 to 0.7099 µs**, **+2.90% / +19.99 ns**, with all ten candidate pairs
slower. Its source-level policy path is unchanged, but that does not make the
measured regression disappear; this study does not isolate its cause.

The other zero/one-track and subtitles-off controls have median changes
between -0.36% and +1.24%. Language-policy workloads are dominated by
normalization and show mixed paired results. In particular, 32-track audio
with languages has a +0.39% median change even though six of ten pairs improve.
Do not treat the small language-bearing changes as an established broad win,
or claim that every selection path becomes faster.

## Executed validation

- All **13 semantic tests** passed for baseline and candidate in both debug
  and release: **52 successful test-function executions**.
- Complete selected-ID receipts agreed for **55,296 selections** before timing.
- All **320 final rows** were audited: sixteen workloads, ten pairs each,
  exactly five AB/five BA pairs per workload, matching work/result receipts.
- Source hashes matched the reviewed candidate and exact pre-change baseline.
- Every summary median, range, percentage, and paired ratio recomputed from
  the raw observations; every final calibration met the 50 ms pilot target.
- A second reviewer independently reproduced the summary and checked individual
  test completions, source identity, measurement order, and the reported regression.

The [retained evidence](../Benchmarks/TrackSelectionRanking/evidence/scalar-rank-linux/README.md)
contains the raw compact receipt, full summary, and audit. The original CI
artifact also contains staged source inputs and complete verification receipts.
The initial portable attempt failed at Git's container ownership check before
compilation or timing; it contributes no measurements to this report.

## Why this area

Automatic audio/subtitle selection calls `TrackSelectionPreferences.select`
through `FFmpegMediaInfo.preferredTrackIndex` during media opening. After the
earlier normalization optimization, ranking still creates one seven-element
integer array for each eligible track whenever there are at least two.

This follow-up targets those temporary rank arrays and their lexicographic
comparisons. It does not change candidate filtering, preference sanitization,
language normalization, subtitle policies, or the existing zero/singleton paths.

## Ordering argument

Language rank is followed by six Boolean priorities, ordered from most to least
important: commentary policy, accessibility policy, dedicated forced subtitles,
default flag, forced-subtitle flag, and fallback ID.

The scalar puts language rank above six bits and assigns those priorities bits
5 through 0. All lower flags combined are at most 63, so they cannot outweigh
a one-step language advantage. Each Boolean bit also outweighs every lower bit.
Sanitization bounds language rank to 0...32; the maximum scalar is 2,111.

Exact-rank ties continue to compare signed track IDs directly. IDs are not
encoded into the rank or subtracted, preserving the Int64 boundary behavior.

## Method and scope

The comparison baseline is pre-change main
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`, not the older frozen baseline from
the first track-selection study. The runner's new `--baseline-ref` option
resolves the ref once, stages exact baseline source, verifies the shared
`MediaTrack.swift`, and records Git blob IDs, SHA-256 hashes, and Git commands.
The historical default baseline and evidence are preserved.

The unchanged timing driver links separately optimized production modules
against real Foundation. Fixture creation, initial preference construction,
and warm-up are outside timing; selection's sanitization, filtering, language
normalization, ranking, and transient storage remain inside. Every output is
consumed and each pair's checksums, selected counts, iterations, and operations
must match.

Each of the sixteen workloads has ten serial fresh-process pairs, equally
split between AB and BA order. Separate pilot processes calibrate both
variants to the same per-workload iteration count, targeting at least 50 ms
for the faster variant. Timings describe warmed component selection cost,
not cold media-open latency, decoder throughput, playback frame rate, memory
footprint of the whole application, or tail latency.

## Correctness

The same semantic suite runs against both baseline and candidate in debug and
release. The added full-language test supplies 32 distinct valid language
preferences plus an ignored 33rd input; it checks both track kinds, conflicts
with lower priorities, permutations, public preference mutation, and signed-ID
extremes. The prior suite already checks every ranking priority and subtitle
policy, aliases, invalid values, duplicate IDs, and empty/singleton catalogs.

The benchmark compares complete selected-ID receipts for 55,296 deterministic
selections before timing, rather than treating checksum equality as a substitute
for behavioral parity.

## Reproduce

Use the commands in the
[benchmark guide](../Benchmarks/TrackSelectionRanking/README.md#comparing-a-later-optimization).

