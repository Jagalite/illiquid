# Sidecar ancestor metadata reuse: research and qualification

Date: October 28, 2026. Repository: `Jagalite/illiquid`.

**Outcome:** Candidate C is proposed for a scoped research draft PR. In the final
unchanged-source experiment, a complete new-reader scan of 1,000 files sharing
four metadata-bearing ancestor folders used **12.86% less CPU time**, with all
20 pairs faster. A possible small overhead remains in the primed no-sidecar
control, and native macOS qualification is pending. This is not a general scan
speedup or a ready-to-merge qualification. Candidates A and B were rejected;
their adverse controls remain in the record.

## Scope and acceptance criterion

This study targets repeated ancestor metadata merging in
[`MediaSidecarReader.recognize(_:within:)`](../Sources/IlliquidCore/MediaLibrary/MediaSidecarReader.swift).
The reader combines filename evidence, ancestor `tvshow.nfo` and `.plexmatch`
files, explicit episode mappings, and per-file NFOs. Its existing one-parent path
plan reuses URLs for consecutive siblings, while each sibling still reconstructs
the same ancestor metadata.

[`MediaMetadataHints.overriding`](../Sources/IlliquidCore/MediaLibrary/MediaMetadataHints.swift)
resolves optional fields, replaces catalog IDs by provider, and deduplicates and
sorts source attribution. Avoiding those repeated operations is promising when
many siblings share populated sidecars. The complete recognition pass must
improve without a material penalty for common no-sidecar and NFO-only scans.
Unique parents, alternating parents, and single-file scans also remain explicit
controls. A large gain in the richest fixture does not excuse an adverse common
case.

The frozen baseline is main commit
[`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`](https://github.com/Jagalite/illiquid/commit/ea2ff568237e2667f7b1aeee67b11a44ebe95b72).
It already includes ancestor path planning, compact PlexMatch episode storage,
and separate negative caching. All candidate comparisons use this baseline,
rather than a version lacking those prior optimizations.

## Snapshot validity and behavior boundaries

Positive sidecar entries are immutable within a reader. Missing or unusable
sidecars remain negatively cached. Entries are never removed and the remaining
byte budget never increases, so a budget-blocked ancestor cannot become newly
admissible later in the same reader. Exact UTF-8 root and parent URL keys identify
the existing validated path plan; changing either requires a new ancestor walk.

The reusable value must contain only the completed ancestor merge. It is
published after every ancestor read and before episode mappings or own-file NFOs
are applied. Otherwise, an explicit mapped season, episode range, or per-file
title could leak into the next sibling. Implicit mappings still inherit the
final ancestor season before the directory/default fallbacks.

All three candidates retain sidecar reads, mapping lookups, descendant-mapping
restrictions, and cancellation checkpoints in their existing order. Cache hits
skip only the pure ancestor merge calls. Cancellation before completion cannot
publish a partial merge. Cancellation afterward may retain the completed
ancestor snapshot, without retaining per-file overrides. Filename recognition,
provider precedence, attribution, movie NFO handling, and final result
construction retain their existing paths. The 64-folder, 128 KiB per-file,
16 MiB per-reader, and 50,000-entry limits retain their checks.

## Candidate C: keep the path plan small

C restores the original four-field `AncestorPathPlan` struct and adds a separate
private immutable `AncestorHints` reference. Publishing an exactly empty
`MediaMetadataHints()` stores `nil`, avoiding a new hint-box allocation for an
empty ancestor merge. Populated ancestors retain one merged snapshot until the
plan is replaced or the reader is released. The current implementation is in the
[reader source](../Sources/IlliquidCore/MediaLibrary/MediaSidecarReader.swift);
its source commit is [`0712ea3e420b0e07fd0d1dc3f9a808e9a05c2a6c`](https://github.com/Jagalite/illiquid/commit/0712ea3e420b0e07fd0d1dc3f9a808e9a05c2a6c), and its reader SHA-256 is
`629ea274d9b34e64c8e7702c8963b44df84a5eeee0e4d425401fdf35f4ce635a`.

The matched path plan and hint reference are captured together **before any
cancellation callback**. A callback can reenter recognition for another parent
and replace the reader's current fields. The outer call must continue with its
own matched pair. A newly completed pair is published after the ancestor loop,
with no cancellation callback between the two assignments. This is a semantic
requirement for separating the storage, not a timing result.

C is intended to preserve merge reuse while avoiding A's larger value payload
and B's allocation of an entire reference plan for empty metadata. That is a
hypothesis assessed in C's own measurements. It does not establish C's generated
code or memory cost; the code-generation inspection below covers A and B.

## Measurement design

The [benchmark](../Benchmarks/SidecarAncestorHints/README.md) independently builds
the complete reader and four support sources as optimized Swift 6 modules. An
identical driver calls the public API across a dynamic module boundary, without
cross-module optimization. Frozen Git blobs and SHA-256 hashes are checked; the
runner rejects production differences outside the reader. On Linux, only the
Darwin-to-Glibc import and the NFO parser's FoundationXML import are adapted.
Native macOS uses actual production sources and an explicit SDK.

The unchanged matrix has **26 timed cells**. Rich cases combine 1, 100, or 1,000
siblings with 1, 4, or 12 ancestor folders, counting the root. Every ancestor
contains a populated `.plexmatch`; the root also has a show NFO. Multiple
providers, duplicate-provider IDs, and source attribution exercise the merges.
Twelve ancestors is a depth stress case. The NFO-only case has 1,000 siblings at
depth four and one root show NFO. Missing-sidecar, unique-parent, and
alternating-parent controls expose costs when the intended reuse is absent or
small. These synthetic shapes do not establish their frequency in real libraries.

Cold-reader passes create and destroy a reader around the complete scan,
including first sidecar opens, reads, parsing, and later cache hits. Warm-reader
passes reuse a reader primed outside timing. Both use warmed OS filesystem
caches; neither measures cold storage latency. Timing includes result-array
construction and an identical small consumer. Fixture creation, warmup,
calibration, serialization, and full-output comparisons stay outside the interval.

Each complete campaign uses ten adjacent AB/BA pairs per cell, a fresh process
per sample, reversed case traversal on alternate rounds, and equal calibrated
iteration counts within each pair. Wall and process CPU time are retained.
The initial A matrix targeted 150 ms per sample. Its diagnostic follow-up targeted
one second on CPU 0. B's complete matrix targeted 300 ms on CPU 0. A target is
not a guaranteed minimum duration. C's complete matrix also uses 300 ms targets
and CPU 0, with all 26 cases and 520 observations. Its final diagnostic uses
20 pairs and 1,000 ms targets on CPU 0 for four predeclared cases. Inputs and
compiler flags remain unchanged; the cohorts are retained separately.

Reported changes are median paired `100 × (candidate / baseline − 1)`; negative
values mean less time. Independent variant medians need not produce the same
percentage. Each cohort has its own contemporaneous frozen-main samples.
**Percentages from different candidate cohorts are never subtracted to estimate
a gain**, and an improved-looking percentage in a later cohort cannot erase an
earlier adverse result.

## Correctness evidence

A and B each passed the same **118 reported tests in all four configurations**:
baseline/candidate × debug/release. A's completed test phase is preserved in
[`linux-initial-tests`](../Benchmarks/SidecarAncestorHints/evidence/linux-initial-tests/test-receipt.json).
The interrupted screen that produced it contributes no timing conclusion. B's
separate completed verification is preserved in
[`linux-reference-tests`](../Benchmarks/SidecarAncestorHints/evidence/linux-reference-tests/test-receipt.json).
Linux platform guards remain intact, so these counts do not claim macOS-only
cases executed.

The completed A and B differential runs matched **12,822 full recognized outputs
across 28 scans**, plus **92 cancellation/throw/resume trajectories**. Comparison
includes exact UTF-8 fields, ordered arrays, derived display values, cumulative
`filesRead`, and checkpoint counts. Independent expectations check title, year,
season, episode, range, provider/source arrays, and read totals. Every timed
sample must also match verified outputs, reads, checksums, and operation counts.

The [ancestor regression suite](../Tests/IlliquidCoreTests/MediaSidecarAncestorHintsTests.swift)
covers sibling mapping/own-NFO isolation, deepest-season and provider precedence,
exact decomposed title bytes, returned-array mutation, cached edits/deletion,
and cancellation during a parent change. C adds a reentrant callback regression
with populated/populated, populated/empty, and empty/populated parent pairs. It
checks both nested and outer results against fresh readers, subsequent reads of
both parents, and `filesRead`. Existing sidecar, path-plan, negative-cache,
PlexMatch, NFO, and filename suites remain included.

**C passed 119 reported tests in each of the four configurations.** Its separate
verification invocation and complete timing campaign both matched all 12,822
recognized outputs and 92 cancellation/resume trajectories. Original and compiled
production hashes and every test hash match between those two invocations.
[Completed C test receipts](../Benchmarks/SidecarAncestorHints/evidence/linux-tests/test-receipt.json)
and [timing parity receipts](../Benchmarks/SidecarAncestorHints/evidence/linux/verification.json)
identify C's exact source; A/B results are not substituted for the new regression.

## Candidate A: merged hints inside the value plan — rejected

A's complete 520-observation matrix is retained in
[`linux-initial`](../Benchmarks/SidecarAncestorHints/evidence/linux-initial/summary.json).
A predeclared four-case follow-up used unchanged production and benchmark inputs,
ten pairs, longer samples, and CPU 0. Its selection and receipts remain in
[`linux-initial-followup`](../Benchmarks/SidecarAncestorHints/evidence/linux-initial-followup/research-context.json).
The target gain repeated, but the adverse common controls prevented acceptance.

| A: value-plan case | Full-matrix paired wall change | Longer follow-up paired wall change |
| --- | ---: | ---: |
| Rich depth 4, 1,000 files, cold reader | −13.13% | −18.68% |
| Rich depth 12, 1,000 files, cold reader | −33.69% | Not selected |
| No sidecars, depth 4, 1,000 files, cold reader | −3.25% | +13.17% |
| NFO only, depth 4, 1,000 files, cold reader | +18.32% | +6.77% |
| NFO only, depth 4, 1,000 files, warm reader | +7.93% | −8.89% |

## Candidate B: entire plan as an immutable reference — rejected

B is the implementation published at
[`e34a5beb39ce24317d9b3bec0366db42c021af4d`](https://github.com/Jagalite/illiquid/commit/e34a5beb39ce24317d9b3bec0366db42c021af4d).
Its completed 520-observation matrix is retained in
[`linux-reference-rejected`](../Benchmarks/SidecarAncestorHints/evidence/linux-reference-rejected/summary.json).
The following rows include the target, depth stress, single-file adverse case,
and every common control. All 26 cells and raw pairs remain in that archive.

| B: reference-plan case | Paired wall change | Paired CPU change | Wall wins / 10 |
| --- | ---: | ---: | ---: |
| Rich depth 4, 1,000 files, cold | −23.17% | −23.16% | 10 |
| Rich depth 12, 1,000 files, cold | −28.67% | −28.67% | 8 |
| Rich depth 12, 1 file, cold | +8.78% | +8.78% | 4 |
| No sidecars, depth 4, 1,000 files, cold | +9.36% | +9.36% | 3 |
| No sidecars, depth 4, 1,000 files, warm | +2.79% | +2.79% | 5 |
| NFO only, depth 4, 1,000 files, cold | −3.78% | −3.80% | 6 |
| NFO only, depth 4, 1,000 files, warm | −7.42% | −7.49% | 8 |
| Unique parents, depth 4, 100 files, cold | +3.66% | +3.70% | 3 |
| Unique parents, depth 4, 100 files, warm | +4.76% | +4.75% | 3 |
| Alternating parents, depth 4, 1,000 files, cold | +2.33% | +2.34% | 4 |
| Alternating parents, depth 4, 1,000 files, warm | +1.14% | +1.13% | 4 |

B improved the target and NFO-only cases in its own cohort, but the no-sidecar
penalty and adverse parent-change controls still failed the acceptance criterion.
It is retained as rejected research, not described as the final implementation.

### What the A/B code-generation inspection establishes

The retained [inspection notes](../Benchmarks/SidecarAncestorHints/evidence/codegen/README.md)
and [receipt](../Benchmarks/SidecarAncestorHints/evidence/codegen/receipt.json)
record exact modules, source hashes, tools, commands, and disassembly excerpts.
A adds six 168-byte `memcpy` call sites inside optimized `recognize`. B removes
those plan-copy sites and introduces a plan-publication allocation requesting
184 bytes, including the object header. The sole remaining 168-byte copy in B
also exists in the baseline and handles the recognized result before `applying`.

These are static observations about A and B, not C. They identify plausible
representation costs but do not prove the cause or size of any timing change.
Instruction sites are not dynamic execution counts, allocation requests exclude
allocator overhead, and the study does not measure retained heap, peak memory,
or RSS. The baseline modules have different whole-file hashes across builds;
the receipt separately confirms matching production source hashes and matching
`recognize` instruction disassembly.

## Candidate C: complete matrix

The [complete C matrix](../Benchmarks/SidecarAncestorHints/evidence/linux/summary.json)
contains 520 observations. All rows below were recomputed from raw samples.
Times are each variant's independent median milliseconds per complete scan;
percentage changes are the separate median of paired ratios. Negative changes
mean less time. These Linux x86_64 / Swift 6.3.2 results use synthetic files and
warmed OS filesystem caches, with one CPU selected by `taskset -c 0`.

| C case | Reader | Baseline ms / scan | C ms / scan | Paired wall change | Paired CPU change | Wall wins / 10 |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Rich depth 1, 1 file | Cold | 0.245 | 0.233 | −0.70% | −0.69% | 6 |
| Rich depth 1, 1 file | Warm | 0.105 | 0.091 | −10.60% | −10.52% | 9 |
| Rich depth 1, 100 files | Cold | 11.459 | 10.056 | −13.32% | −13.31% | 9 |
| Rich depth 1, 100 files | Warm | 10.491 | 8.543 | −11.78% | −11.78% | 8 |
| Rich depth 1, 1,000 files | Cold | 98.469 | 97.719 | −3.46% | −3.47% | 8 |
| Rich depth 1, 1,000 files | Warm | 93.318 | 94.778 | −0.86% | −0.99% | 6 |
| Rich depth 4, 1 file | Cold | 0.484 | 0.440 | −2.91% | −2.91% | 7 |
| Rich depth 4, 1 file | Warm | 0.112 | 0.094 | −17.20% | −17.20% | 10 |
| Rich depth 4, 100 files | Cold | 14.419 | 10.845 | −15.73% | −15.73% | 9 |
| Rich depth 4, 100 files | Warm | 13.052 | 10.524 | −15.99% | −15.99% | 9 |
| Rich depth 4, 1,000 files | Cold | 131.636 | 131.956 | −10.65% | −10.65% | 7 |
| Rich depth 4, 1,000 files | Warm | 144.267 | 116.265 | −17.29% | −17.26% | 10 |
| Rich depth 12, 1 file | Cold | 1.037 | 1.114 | +4.56% | +4.55% | 4 |
| Rich depth 12, 1 file | Warm | 0.193 | 0.141 | −22.58% | −22.58% | 9 |
| Rich depth 12, 100 files | Cold | 21.404 | 16.335 | −25.09% | −25.09% | 10 |
| Rich depth 12, 100 files | Warm | 20.904 | 15.208 | −26.85% | −26.84% | 10 |
| Rich depth 12, 1,000 files | Cold | 228.362 | 164.947 | −22.19% | −22.19% | 10 |
| Rich depth 12, 1,000 files | Warm | 188.674 | 148.779 | −22.17% | −22.17% | 10 |
| No sidecars, depth 4, 1,000 files | Cold | 87.947 | 92.928 | +4.10% | +4.10% | 3 |
| No sidecars, depth 4, 1,000 files | Warm | 83.079 | 87.048 | +4.13% | +4.14% | 2 |
| NFO only, depth 4, 1,000 files | Cold | 94.824 | 94.779 | −2.29% | −2.30% | 6 |
| NFO only, depth 4, 1,000 files | Warm | 99.863 | 95.828 | −1.65% | −1.70% | 5 |
| Unique parents, depth 4, 100 files | Cold | 23.056 | 22.017 | −1.16% | −1.16% | 5 |
| Unique parents, depth 4, 100 files | Warm | 15.125 | 14.812 | +0.66% | +0.66% | 5 |
| Alternating parents, depth 4, 1,000 files | Cold | 157.467 | 155.586 | +0.44% | +0.43% | 5 |
| Alternating parents, depth 4, 1,000 files | Warm | 145.700 | 158.973 | −0.22% | −0.23% | 5 |

## Candidate C: final diagnostic

The complete matrix showed a consistent deep-ancestor benefit, but missing-sidecar
medians were about 4% slower and variable. This triggered one predeclared,
unchanged-source follow-up: rich depth 4 cold, missing-sidecar cold and warm, and
NFO-only cold, with 20 balanced pairs and 1,000 ms calibration targets. It completed
all 160 observations with the same source, test, driver, runner, and compiler
inputs. [Follow-up results and protocol](../Benchmarks/SidecarAncestorHints/evidence/linux-followup/summary.json)
remain separate from the original matrix. No further implementation tuning or
local timing campaigns were performed after this diagnostic.

| Final C diagnostic, 1,000 files | Baseline ms / scan | C ms / scan | Paired wall change | Paired CPU change | Wall wins / 20 |
| --- | ---: | ---: | ---: | ---: | ---: |
| Rich depth 4, new reader | 117.913 | 102.952 | −12.85% | −12.86% | 20 |
| No sidecars, new reader | 86.178 | 88.310 | −1.21% | −1.21% | 13 |
| No sidecars, primed reader | 81.067 | 83.487 | +2.93% | +2.95% | 9 |
| NFO only, new reader | 92.390 | 91.082 | −4.24% | −4.23% | 13 |

The target gain reproduced in every pair and in both process orders: paired wall
medians were −12.54% AB and −12.85% BA, with individual changes from −23.23% to
−1.97%. The independent wall medians were 117.913 to 102.952 ms per complete scan.

The earlier new-reader missing-sidecar slowdown did not reproduce in the paired
analysis. This is **not evidence of equivalence or a control speedup**: independent
medians were 86.178 to 88.310 ms while the paired median was −1.21%. These summaries
need not agree, and individual pairs remain variable.

The primed no-sidecar control still leaves a possible modest cost: +2.93% paired
wall time, approximately 2.37 ms additional paired time per 1,000 files. Eleven
of twenty pairs were slower; AB and BA medians disagreed (−2.40% versus +4.97%),
and the interquartile interval spanned −3.30% to +6.30%. This neither establishes
a stable regression nor clears the possibility of one. NFO-only results are
supporting context, not a headline claim.

The targeted Linux research therefore supports **native evaluation in a draft
PR**, while product qualification remains incomplete. The original C controls,
earlier rejected candidates, and final diagnostic are all retained: five complete
cohorts, **1,800 observations**. No cohorts are pooled or selectively discarded.


## Native qualification and remaining limits

The workflow is configured for macOS 26 and Xcode 26.6. C's source-matched
[Actions run 40639455222](https://github.com/Jagalite/illiquid/actions/runs/40639455222)
was pending at the last check, and has supplied no completed native result.
The queued requests establish neither compilation nor test/performance success.
No macOS speedup or full-player qualification is claimed.

C retains at most one current merged hint box, with no box for an exactly empty
merge. Strings and arrays may share storage with cached metadata, while merged
provider/source arrays can retain additional allocations. Parent changes with
populated metadata still allocate a box; their costs must be measured. This is
bounded additional state, not an established memory reduction.

Benefits depend on consecutive sibling reuse and metadata content. Shared-host
scheduling and warmed filesystem caches limit precision; CPU pinning does not
isolate all host activity. Linux Foundation timings do not predict macOS gains.
Component results do not establish whole-player CPU, library-browser latency,
playback, rendering, energy, or user-visible improvements. Reproduction and
receipts are described in the [benchmark README](../Benchmarks/SidecarAncestorHints/README.md).
Use Kyoto where available and serialize builds and measurement campaigns.
