# NFO text-limit performance research

## Result and decision

**The refined candidate meets the predefined research criteria in protocol 3.** Complete parsing of the three intentionally fragmented fields took **93.76–97.91% less time**, with the candidate faster in all twelve measured pairs for each workload. All correctness and exact-output comparisons passed.

The longer ordinary-movie observations measured **+1.33% by independent medians and +0.07% by paired medians**, with six of twelve pairs favoring each variant. The earlier material movie slowdown did not repeat in this fixed longer-batch follow-up on unchanged production source. The episode, short-Unicode, repeated-fallback, and ignored-plot controls had lower medians in this cohort. Small differences and their direction should not be treated as reliable general improvements.

The early DOCTYPE rejection control remained slower: +7.14% by independent medians, +3.66% by paired medians, approximately 0.095 microseconds between independent medians. That input returns in the unchanged declaration preflight before the modified callback can execute. Protocol 2 measured +0.33% / +0.11% for this control. We retain both results; this experiment does not establish a uniformly faster parser on every input.

These are complete warmed, in-memory NFO parse measurements on fixed synthetic fixtures. Whole-library loading, file I/O, playback, and energy were outside the experiment.

The timing results below qualify the recorded historical source cohort only. Current integration is checked separately without timing; these historical numbers do not qualify the current integrated pipeline's performance.

## Final native cohort

[Run 39075451501](https://github.com/Jagalite/illiquid/actions/runs/39075451501), completed October 17, 2026, used protocol `3-longer-ordinary-controls`.

| Identity | Value |
|---|---|
| Pinned baseline commit | `68274d1b09dcc866296321a5a8858efc297c4f19` |
| PR head for this run | `91dab495865210bbaced94ef39a2eb613209c3c7` |
| Actual compiled PR merge checkout | `b1ef60bf443ed4018ef2aa20f9b8d99a375ff25a` |
| Candidate NFO source blob | `051c475fd33bcd16ec33f6b4b93ee98fffdb21d3` |
| Benchmark runner blob | `f77ca6bf077428a964d4bcefc8f51658d8b6c679` |
| Benchmark driver blob | `66b8c7f727538beaab6f80558d894482922c9037` |
| Recorded environment | macOS 26.6.2, arm64, three processors; Apple Swift 6.3.3; Xcode 26.6 selected by workflow |
| Optimized executable flags | `-swift-version 6 -O -parse-as-library` |

Only `MediaLibrary/NFOMetadataHints.swift` differs among the five compiled production sources. The manifest records exact source and test hashes and a clean working tree.

**Correctness:** 52 tests in five suites passed in each of baseline debug, baseline release, candidate debug, and candidate release. These are the same 52 tests exercised in four configurations. All 136 complete differential outputs matched, including 80 accepted and 56 rejected inputs. Complete receipts also matched across all benchmark observations.

**Audit:** the complete archive, per-file hashes and ZIP checksums, 338 timing records, all receipt hashes, and every reported statistic were independently checked. The runner compares both implementations and saves their shared output; auditing that saved output does not independently reexecute the parser.

Times below are milliseconds per complete parse. “Median change” is candidate median / baseline median minus one. “Paired change” is the median of the twelve within-pair candidate / baseline ratios minus one. They are different statistics. Negative values favor the candidate; all samples, including slow observations, are retained.

| Workload | Baseline median, ms | Candidate median, ms | Median change | Paired change | Faster pairs |
|---|---:|---:|---:|---:|---:|
| `movie-small` | 0.017869 | 0.018107 | +1.33% | +0.07% | 6/12 |
| `episode-small` | 0.017677 | 0.016415 | -7.14% | -5.13% | 9/12 |
| `unicode-small` | 0.021988 | 0.021065 | -4.20% | -4.27% | 9/12 |
| `ascii-boundary-4096` | 0.124896 | 0.066493 | -46.76% | -48.92% | 11/12 |
| `ascii-fragmented-4096` | 18.815955 | 1.174999 | -93.76% | -93.96% | 12/12 |
| `unicode-fragmented-4095-bytes` | 36.886857 | 1.369906 | -96.29% | -96.17% | 12/12 |
| `unicode-fallback-2500` | 1.031416 | 0.822989 | -20.21% | -20.52% | 12/12 |
| `unicode-fallback-fragmented` | 28.017279 | 27.143854 | -3.12% | -7.29% | 7/12 |
| `combining-cdata` | 35.292989 | 0.737606 | -97.91% | -97.93% | 12/12 |
| `ignored-long-plot` | 1.303481 | 1.279010 | -1.88% | -4.15% | 9/12 |
| `ascii-over-limit-4097` | 0.116034 | 0.113054 | -2.57% | -0.07% | 6/12 |
| `malformed-xml` | 0.012703 | 0.012456 | -1.95% | -6.30% | 8/12 |
| `doctype-rejected` | 0.001326 | 0.001421 | +7.14% | +3.66% | 3/12 |

The [manifest](evidence/long-ordinary-controls/manifest.json), [raw timings](evidence/long-ordinary-controls/measurements.jsonl), [full summaries including ranges](evidence/long-ordinary-controls/summary.json), [complete evidence ZIP](evidence/long-ordinary-controls/native-evidence.zip), and [provenance](evidence/long-ordinary-controls/provenance.json) preserve this cohort.

## Production change

[`NFOMetadataHints.swift`](../../Sources/IlliquidCore/MediaLibrary/NFOMetadataHints.swift) previously counted the accumulated Swift `Character` values again on every captured XML text callback:

```swift
text.count + string.count <= 4096
```

Repeated entities and CDATA can produce many callbacks, making the repeated scans expensive. The candidate tries a sufficient UTF-8 byte bound while the field remains eligible:

```swift
if checksUTF8Bound {
    checksUTF8Bound = text.utf8.count + string.utf8.count <= 4096
}
guard checksUTF8Bound || text.count + string.count <= 4096 else {
    valid = false
    parser.abortParsing()
    return
}
```

A failed shortcut disables further byte probes until the next text reset. Thereafter every callback uses the exact old character expression. This conservative policy preserves acceptance regardless of whether subsequent appends could change byte-count eligibility.

Each Swift `Character` occupies at least one UTF-8 byte. A byte sum at or below 4,096 therefore proves that the original expression accepts the chunk. Larger byte sums still evaluate the original expression unchanged. A 4,096-character multibyte field remains eligible through that fallback.

Keeping the exact expression matters when a combining mark, regional indicator, newline, or joiner merges with preceding text after appending. Summing callback character counts permanently, or counting only the concatenated result, could change the original acceptance boundary. The regression tests cover both permitted grapheme joins and a split grapheme that the old parser rejects at the limit.

The change preserves the document-size and nesting limits, captured-field selection, XML validation, declaration rejection, and metadata interpretation.

## Current qualification (no timing)

Run on macOS with Python 3.10+ and Swift 6.1+. The runner uses the actual five MediaLibrary sources, including the Darwin-based sidecar reader.

```sh
git fetch --no-tags --depth=1 origin 68274d1b09dcc866296321a5a8858efc297c4f19
python3 Benchmarks/NFOTextLimits/run.py \
  --mode qualify --jobs 2 \
  --output .build/nfo-current-qualification
```

`qualify` is the default and the [automatic workflow](../../.github/workflows/nfo-text-limits.yml) uses it explicitly. Both variants receive a snapshot of the **current** four shared production dependencies, the same five current test files, and the current driver. Only the baseline NFO parser comes from `68274d1b09dcc866296321a5a8858efc297c4f19`; this is a composite input, not a claim to test that entire old tree. In particular, both versions retain the current filesystem-root reader repair and its regressions.

Before compiling, the runner requires byte-identical shared dependencies and exactly one differing source, `NFOMetadataHints.swift`. It also requires the reviewed baseline/candidate parser blobs `55e84590829c678f6ac5cb1328e64dead63651b6` / `051c475fd33bcd16ec33f6b4b93ee98fffdb21d3`. Any new parser change requires a separately reviewed comparison. The manifest records both source sets' Git blob and SHA-256 hashes, test/driver/runner identities, checkout state, toolchain, commands, and test counts.

Qualification runs all current regressions in debug and release with each parser, then compares all **136 complete** release differential outputs, preserving explicit nulls, strings, and array order. Missing cases, duplicate cases, missing receipt fields, differing test counts, or any output difference fail the run. It never invokes the driver's timing path, and it rejects `--skip-tests` and `--rounds`. Passing results set `completed: true` in `manifest.json`; four test logs, two compiler logs, and `differential.json` supply the evidence. Use a fresh output directory. Swift builds are sequential with at most two compiler jobs.

The fast Python controls exercise the original old-sidecar staging error, unexpected parser changes, incomplete corpora, exact output mismatches, and the no-timing path. They also verify historical source/test/driver hashes against the archived manifest without executing historical timings:

```sh
git fetch --no-tags --depth=1 origin 91dab495865210bbaced94ef39a2eb613209c3c7
python3 -m unittest discover -s Benchmarks/NFOTextLimits -p test_harness.py -v
```

## Reproduce historical protocol 3 (explicit timing)

Historical reproduction loads **all** baseline production sources from `68274d1b09dcc866296321a5a8858efc297c4f19` and candidate sources, tests, and driver from `91dab495865210bbaced94ef39a2eb613209c3c7`. Those blobs match the recorded merge checkout in the final native cohort. Current shared code and root regressions are qualified by the separate path above.

```sh
git fetch --no-tags --depth=1 origin 68274d1b09dcc866296321a5a8858efc297c4f19
git fetch --no-tags --depth=1 origin 91dab495865210bbaced94ef39a2eb613209c3c7
python3 Benchmarks/NFOTextLimits/run.py \
  --mode historical-timing --jobs 2 \
  --output .build/nfo-historical-protocol-3 \
  --rounds 12
```

Use a fresh output directory and a quiet host. This opt-in mode preserves protocol 3's workload counts, warmups, AB/BA order, receipts, and statistics; automatic CI does not run it. The current runner adds isolation checks and records its own hash. For the exact original runner, use `Benchmarks/NFOTextLimits/run.py` at the pinned candidate commit (blob `f77ca6bf077428a964d4bcefc8f51658d8b6c679`) in an isolated checkout of that commit. Archived evidence remains unchanged. New executions are separate cohorts and must not be pooled with the historical results.

`--skip-tests` is available only with `--mode historical-timing` for an explicitly limited follow-up measurement; such a run alone does not satisfy the correctness criterion.

## Method and acceptance criteria

The historical protocol reads source bytes directly from pinned Git objects and builds separate baseline/candidate executables with `-swift-version 6 -O -parse-as-library`. It applies the same five regression-test files from that cohort to both implementations in debug and release. Those tests include the real sidecar reader, NFO field selection and episode scope, media-name recognition, and the text-limit suite.

Each timing observation uses a fresh process. [`Driver.swift`](Driver.swift) constructs fixed XML `Data` before timing and performs three untimed warmup parses. One additional pair per workload is retained as round -1 and excluded. Twelve measured pairs alternate AB/BA order. The complete production parser runs once per timed iteration, and the driver consumes cheap result scalars and collection counts. Parser/result release occurs inside the timed call.

Input construction and full output serialization are outside the timer. After timing, the driver serializes every metadata field, including explicit nulls, into a complete receipt. The runner compares these receipts across implementations and observations. It also compares a separate full differential corpus before timing. Every timing observation is retained.

The runner records these criteria before testing:

1. All four debug/release test runs and exact differential/receipt comparisons must pass.
2. Fragmented fields within the UTF-8 bound should show at least 25% lower median complete-parse time.
3. Any consistent ordinary or fallback regression of 5% or greater requires investigation.
4. Existing real sidecar-reader regressions must run with both parser versions.

Correctness failures stop the runner. Performance acceptance requires reviewing the saved measurements, ranges, paired statistics, and controls.

## Current workload definitions

The same fixed parse count is used for each implementation within a workload.

| Workload | Parses per observation | Input and purpose |
|---|---:|---|
| `movie-small` | 100,000 | Ordinary movie title, year, IMDb ID, and ignored plot. |
| `episode-small` | 50,000 | Ordinary episode/show titles, season, episode, and episode-level ID. |
| `unicode-small` | 50,000 | Short Japanese and accented episode/show titles. |
| `ascii-boundary-4096` | 400 | A contiguous ASCII title at the character limit. |
| `ascii-fragmented-4096` | 20 | 2,048 repetitions of `A&amp;`: 4,096 decoded characters and bytes. |
| `unicode-fragmented-4095-bytes` | 8 | 1,365 repetitions of `é&amp;`: 2,730 characters and 4,095 UTF-8 bytes. |
| `unicode-fallback-2500` | 300 | A contiguous 2,500-character title made from `界`, occupying 7,500 bytes. |
| `unicode-fallback-fragmented` | 64 | 1,500 `界` characters followed by 1,500 `&amp;` entities: 3,000 characters and 6,000 bytes. |
| `combining-cdata` | 30 | 800 repetitions of `e` followed by a combining acute accent in CDATA. |
| `ignored-long-plot` | 1,000 | A short supported title plus 100,000 ignored ASCII plot characters. |
| `ascii-over-limit-4097` | 400 | An over-limit supported title that must be rejected. |
| `malformed-xml` | 5,000 | Mismatched XML after a usable title, requiring rejection of partial metadata. |
| `doctype-rejected` | 20,000 | Declaration/entity input rejected by the existing preflight checks. |

The fragmented fallback control starts with a 4,500-byte prefix. Subsequent entity callbacks repeatedly exercised both checks in the first candidate. The refined candidate disables the byte probe after a miss and uses the original character check for the rest of that field. The contiguous Unicode case can still benefit from earlier short chunks.

A full expanded campaign has 13 workloads, 312 measured process observations, 26 excluded warmup observations, and 338 retained timing records. The current differential corpus contains 136 fixtures, covering multibyte and split-grapheme boundaries, captured fields, root/field scope, malformed data, file-size and nesting limits, and invalid UTF-8.

## Historical investigations

The source and protocol changed during the research. Each cohort remains separate; medians and observations from different cohorts are not pooled. The final cohort above is evidence for the refined parser in its recorded historical dependency set.

The first three campaigns tested the original byte guard, source blob `a5a698d2d19c721ce1252384993307ceaf4fe67c`. Its fragmented-field gains were approximately 95–98%. The expanded campaign added a repeated Unicode fallback control and increased the differential corpus from 135 to 136 cases. Every campaign passed the four 52-test runs and exact output comparisons.

The original candidate kept testing UTF-8 lengths on every fallback callback. Its repeated-fallback paired change was +3.05% and then +9.01%. The refinement disables those probes after the first byte-bound miss for a field. This removes work that can no longer help that field; the internal cause of the earlier timing cost was not profiled.

Protocol 2 tested the refined source with 64 repeated-fallback parses and 1,000 ignored-plot parses per observation, replacing the previous 8/100 counts. Those controls were within the investigation threshold. However, ordinary movie timing regressed +12.12% by independent medians and +14.81% by paired medians. Its short process batches lasted 78–233 ms, with paired ratios of 0.647–1.902. Variation alone did not resolve the regression.

Protocol 3 retained that exact source and all other protocol-2 counts, fixing movie/episode/short-Unicode observations at 100,000/50,000/50,000 parses before the follow-up. The movie batches then lasted approximately 1.67–2.18 seconds. The material movie slowdown did not repeat; this supports acceptance under the declared control criterion without proving that all smaller differences are noise.

The following table shows **paired median changes**, not changes between independent medians:

| Cohort | Ordinary movie | Repeated Unicode fallback | Ignored long plot |
|---|---:|---:|---:|
| [Initial byte guard; 12 cases](https://github.com/Jagalite/illiquid/actions/runs/39071387820) | -0.62% | Not measured | +0.03% |
| [Expanded byte guard; 13 cases](https://github.com/Jagalite/illiquid/actions/runs/39071828452) | -2.65% | +3.05% | +6.37% |
| [Unchanged byte-guard PR replication](https://github.com/Jagalite/illiquid/actions/runs/39073093655) | -1.89% | +9.01% | -2.80% |
| [Refined flag; protocol 2](https://github.com/Jagalite/illiquid/actions/runs/39074402470) | +14.81% | -0.34% | +1.75% |
| [Same refined flag; protocol 3](https://github.com/Jagalite/illiquid/actions/runs/39075451501) | +0.07% | -7.29% | -4.15% |

The first candidate's near-zero movie measurements are historical context. They are not used to qualify the refined implementation. The final DOCTYPE control and all other unfavorable observations are included in the full summaries.

## Evidence availability and scope

| Cohort | Preserved evidence |
|---|---|
| Initial, run 39071387820 | [Summary](evidence/initial-summary.json); [Actions artifact with raw evidence](https://github.com/Jagalite/illiquid/actions/runs/39071387820/artifacts/12114899396), subject to 14-day retention. |
| Expanded, run 39071828452 | [All thirteen summaries](evidence/expanded-summary.json); [Actions artifact with raw evidence](https://github.com/Jagalite/illiquid/actions/runs/39071828452/artifacts/12115383655), subject to 14-day retention. |
| Original byte-guard PR replication, run 39073093655 | [Committed manifest, observations, summary, provenance, and complete archive](evidence/original-byte-guard/). |
| Refined source with short ordinary controls, run 39074402470 | [Committed manifest, observations, summary, provenance, and complete archive](evidence/refined-short-controls/). |
| Refined source with long ordinary controls, run 39075451501 | [Committed manifest, observations, summary, provenance, and complete archive](evidence/long-ordinary-controls/). |

Each complete archive contains `manifest.json`, `measurements.jsonl`, `summary.json`, `receipts.json`, `differential.json`, four test logs, and two compiler logs. ZIP and Git blob hashes are recorded in its provenance. The complete native logs and shared outputs are compressed; manifests, timings, and summaries are directly readable. Executables, build caches, temporary packages, and duplicate source trees are excluded.

The experiment measures input validation, XML callbacks, text accumulation, metadata construction, and result consumption. Existing sidecar-reader tests check filesystem integration behavior separately. The intentionally fragmented fixtures stress the changed path; their frequency in real NFO collections has not been measured. Hosted runners introduce variation, including slow observations on code paths unchanged by this patch. This evidence supports the bounded parser optimization and does not quantify a whole-player speedup.
