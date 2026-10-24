# Native audit of auxiliary embedded-font ownership

The measured prototype removes roughly one font payload from live allocator
ownership for each auxiliary input and reduces repeated input open/close work.
It does **not** demonstrate lower resident process memory: immediate current RSS
is about 15.7–15.9 MiB **higher** in every large-font scenario. These are separate
results and both belong in the decision about the optimization.

This report and its independent audit complement
[PR #101](https://github.com/Jagalite/illiquid/pull/101). They preserve evidence
from a different, explicitly pinned prototype. They do not qualify that PR's
head or change player behavior. The implementation belongs in the existing PR;
this contribution makes the native evidence, adverse results, and limits
reviewable after the original Actions artifact expires.

## Evidence identity and qualification

| Item | Recorded value |
| --- | --- |
| Native run | [40101084730](https://github.com/Jagalite/illiquid/actions/runs/40101084730), job `120893187699` |
| Baseline | [`6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635`](https://github.com/Jagalite/illiquid/commit/6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635) |
| Measured candidate | [`4e64b3d2b6098536c61710dca2354442c718961c`](https://github.com/Jagalite/illiquid/commit/4e64b3d2b6098536c61710dca2354442c718961c), clean checkout |
| Host | macOS 26.6.2, Apple M1 virtual machine, 3 cores, 7 GB RAM |
| Compiler and SDK | Apple Swift 6.3.3; Xcode 26.6; macOS SDK 26.5; optimized Swift 6 with whole-module optimization |
| Native dependency | FFmpeg 8.1.2; exact library/header hashes retained in the manifest |
| Component benchmark | Compiled and executed successfully; memory, timing, metadata, and packet comparisons completed |
| Application test graph | Compilation failed in two new test assertions; the selected runtime tests did not execute |
| Live playback/UI qualification | Not performed |

The complete 1,221,430-byte Actions ZIP is retained unchanged in
[the evidence directory](PerformanceEvidence/AuxiliaryFontNativeAudit/README.md).
Its SHA-256 is
`1b1ebc11ec33c6f9b57d28d86d811c0e0d4c5e6b7a952364ababfec0ff070583`, matching the
GitHub artifact API's recorded digest. It includes all raw observations, full
verification traces, build inputs and outputs, compiler commands, and the failed
application-test log. The audit recomputes the results from those records.

## Why this area matters

`FFmpegDemuxer` projects admitted embedded font attachments into owned Swift
`Data`. The primary media input supplies these fonts to subtitle rendering.
Independent inputs also exist for auxiliary audio/subtitles, frame stepping,
thumbnail work, and an external bitmap-subtitle probe. A reader that never
consumes fonts can still retain its own payload copies for its entire lifetime.

The measured prototype adds `loadFontAttachments`, with the original behavior
as the default, and selects `false` for auxiliary inputs. The gate only omits
Swift font-payload construction. Stream records and FFmpeg's original attachment
extradata remain present. Removing this copy therefore has a bounded ownership
benefit; it does not remove all native memory associated with an attachment.

The experiment compiles the complete production demuxer, serialized executor,
and their component dependencies from the two pinned revisions. Its manifest
records the unchanged declaration extraction used to isolate this component.
The component comparison is narrower than compiling and exercising the player.

## Protocol

Four deterministic Matroska fixtures contain video, audio, ASS subtitles, and
chapters, with 0, 2, 16, or 64 MiB of admitted font-labelled payloads. These
payloads are synthetic copying/admission workloads, not valid fonts. The 64 MiB
fixture contains four 16 MiB entries at the existing total admission limit and
is a stress case. A separate real-font fixture was generated for the application
tests that subsequently failed to compile.

Each memory process opens one primary input with fonts enabled, then keeps
1, 2, or 3 additional inputs alive. A control opens one additional input with
the default font policy in both variants. Native checkpoints occur before and
after the primary, after all additional inputs, after their release, and after
the primary's release. Each input is opened inside an autorelease pool that
drains before the returned handle is measured. Release checkpoints are sampled
immediately after dropping the handles. Payload hashing, packet tracing, and
JSON encoding occur outside the memory checkpoints.

Timing uses separate fresh processes. With the primary held alive, each process
warms one batch, then repeatedly opens and closes its additional inputs. A
paired calibration chooses a common iteration count for the two variants,
targeting 100 ms and capped at 1,000 batches. The timing boundary includes open,
probe, metadata construction, small inventory checks, and teardown. It excludes
primary setup, media decoding, rendering, and UI work.

There are **384 measured processes**: 192 for memory and 192 for timing, plus
32 calibration and 8 verification processes. Each of 16 fixture/policy/count
scenarios has six balanced AB/BA pairs for each measurement type. All samples,
including adverse results, are retained. Percentage reductions are medians of
within-pair reductions; they are not ratios of independently computed medians.

## Memory results

The live allocation metric is `malloc_zone_statistics(NULL).size_in_use` after
the additional inputs minus its value with only the primary alive. It includes
both Swift and native live allocations. RSS is the absolute
`task_info(MACH_TASK_BASIC_INFO).resident_size` with all inputs alive. Peak RSS
is `getrusage(RUSAGE_SELF).ru_maxrss` at that same checkpoint.

The first two numeric columns below are medians in bytes. Savings and RSS
changes are median paired differences. A positive RSS change means the
candidate uses more resident memory. MiB means 1,048,576 bytes.

| Font payload per input | Auxiliary inputs | Baseline incremental live bytes | Candidate incremental live bytes | Live bytes saved | Current RSS change, MiB | Peak RSS change, MiB |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| None | 2 | 388,816 | 388,816 | 0 | -0.094 | -0.094 |
| 2 MiB | 1 | 8,634,976 | 6,537,568 | 2,097,408 | -0.133 | -0.133 |
| 2 MiB | 2 | 17,269,776 | 13,074,992 | 4,194,784 | -0.211 | -0.211 |
| 2 MiB | 3 | 25,904,592 | 19,612,432 | 6,292,160 | -0.117 | -0.117 |
| 16 MiB | 1 | 67,371,664 | 50,577,808 | 16,793,856 | +15.922 | -0.062 |
| 16 MiB | 2 | 134,743,152 | 101,155,472 | 33,587,680 | +15.820 | -0.172 |
| 16 MiB | 3 | 202,114,656 | 151,733,152 | 50,381,504 | +15.828 | -0.172 |
| 64 MiB stress case | 1 | 268,854,560 | 201,728,512 | 67,126,048 | +15.844 | -0.086 |
| 64 MiB stress case | 2 | 537,708,976 | 403,456,880 | 134,252,096 | +15.773 | -0.164 |
| 64 MiB stress case | 3 | 806,563,408 | 605,185,264 | 201,378,144 | +15.703 | -0.250 |

All **54 font-bearing auxiliary pairs** reduce incremental live allocated
bytes. The reduction is approximately the font inventory times the number of
auxiliary inputs, with small allocator/metadata overhead differences. All
no-font pairs tie on live bytes. Across the 42 no-font/default-policy control
pairs, 41 tie exactly and one 16 MiB default-policy sample is 352 bytes higher
in the candidate. The audit retains that exception.

All **36 large-font auxiliary pairs** increase current RSS, in both AB and BA
orders. This is not an artefact of subtracting different initial baselines:
the metric is absolute current RSS, and independently subtracting the
after-primary checkpoints still leaves an increase in every large-font pair.
Peak RSS differs by only 0.06–0.25 MiB in those scenarios, despite much larger
live-allocation savings.

The immediately sampled release checkpoints do not establish sustained residency.
Live allocator bytes fall sharply when the handles are released, while current
RSS barely moves. In the large cases, the baseline's peak exceeds its current
RSS by roughly 16 MiB; the candidate's peak and current RSS coincide. Allocation
caching, mapping/copy behavior, and VM accounting are possible explanations,
but this experiment does not identify the cause. It does not measure physical
footprint, memory-pressure behavior, steady-state playback, or Activity Monitor
memory. A claim of reduced whole-player RAM is unsupported.

## Setup-work results

Positive values below indicate less time in the candidate. The percentages
describe repeated **open/close batches**, not player startup or playback speed.

| Font payload | Auxiliary inputs | Wall-time reduction | Favorable pairs | CPU-time reduction | Favorable pairs |
| --- | ---: | ---: | ---: | ---: | ---: |
| None | 1 | -0.20% | 3/6 | -2.23% | 2/6 |
| None | 2 | 4.09% | 4/6 | 6.77% | 4/6 |
| None | 3 | -3.40% | 3/6 | 0.94% | 3/6 |
| 2 MiB | 1 | 43.48% | 6/6 | 43.04% | 6/6 |
| 2 MiB | 2 | 33.56% | 6/6 | 28.80% | 6/6 |
| 2 MiB | 3 | 39.41% | 6/6 | 37.51% | 6/6 |
| 16 MiB | 1 | 38.39% | 5/6 | 41.88% | 6/6 |
| 16 MiB | 2 | 36.07% | 5/6 | 36.74% | 6/6 |
| 16 MiB | 3 | 48.32% | 6/6 | 46.74% | 6/6 |
| 64 MiB stress case | 1 | 37.67% | 6/6 | 37.62% | 6/6 |
| 64 MiB stress case | 2 | 45.78% | 6/6 | 45.71% | 6/6 |
| 64 MiB stress case | 3 | 48.37% | 6/6 | 46.87% | 6/6 |

CPU time improves in 54/54 font-bearing auxiliary pairs; wall time improves in
52/54. Controls fluctuate, including a roughly 5.8% median regression for the
64 MiB default-policy control. Six pairs on one virtual host support this
component-level observation, not a universal speedup or a statistical guarantee
for other machines and media.

## Correctness and remaining qualification

The retained verification traces cover direct demuxers and serialized executors
with default, explicit-enabled, and auxiliary policies. They compare metadata,
chapters, font names/MIME/content hashes, native codec parameters/extradata,
complete packet streams through EOF, seek results, and active subtitle packets.
The expected difference is an empty Swift font array for the candidate's
auxiliary policy. The independent trace audit checks the saved traces and the
generator's font-hash oracle; the independent metrics audit recalculates all
112 scenario/metric summaries and checks ordering, inventory, and provenance.

The native application test step failed because two new assertions called the
throwing `copyCodecParameters` inside `#require` without the inner `try`, in
`AuxiliaryFontAttachmentTests.swift` and `AuxiliaryFontPlaybackTests.swift`.
Consequently, the run does not prove real-font main/PiP rendering, application
runtime ownership, or end-to-end playback. The failed log is part of the retained
artifact. A source change or a separate successful run cannot retroactively
turn this run into a pass.

The next implementation decision should use the exact PR head's native tests
and real-font playback qualification. If the objective is less process RAM,
also measure physical footprint and residency over time with realistic media
and concurrent readers before making that claim. If the objective is avoiding
unconsumed payload ownership and copy work, this experiment supports that
narrower benefit while exposing its RSS limitation.

## Reproduce the independent audit

See [the audit runner](../Benchmarks/AuxiliaryFontNativeAudit/README.md) for the
single-command replay. It reads the retained artifact, verifies its digest,
recomputes statistics and full trace comparisons, and checks the compiled
artifacts against their recorded hashes. It does not execute the saved native
binaries. The pinned original source and reproduction commands are linked there
for a separate native rerun.
