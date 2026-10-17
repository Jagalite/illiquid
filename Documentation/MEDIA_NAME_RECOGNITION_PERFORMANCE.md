# Media filename recognition performance

This investigation targets repeated filename-cleaning and date-validation work in
`MediaNameRecognition.recognize(relativePath:)`. The candidate preserves the
recognizer's naming rules while reducing work in two existing paths. On the native
macOS component benchmark, seven of eight workloads have lower median paired wall
and CPU costs. Episode names have about **19% lower paired wall time**; ambiguous
names are slightly slower (**0.52% wall, 1.15% CPU**). The selected native consumer
tests and complete output comparison pass. These are warm component measurements,
not measured whole-player or library-scan gains.

## Why this area

[`MediaSidecarReader.recognize`](../Sources/IlliquidCore/MediaLibrary/MediaSidecarReader.swift)
starts with filename recognition before reading or applying sidecar metadata. It
can invoke recognition again for a title-derived candidate or synthesized episode
name. This makes the recognizer part of normal media discovery, including files
that have no sidecar metadata.

[`SourceTreeProjectionInput.makeFlatFileRows`](../Sources/IlliquidApp/UI/SourceTreeProjectionInput.swift)
also calls it in media view when an entry has no cached `recognizedMedia`. The
investigation therefore covers a component shared by discovery and a projection
fallback. It does not measure either complete caller.

The original implementation repeatedly performs tag-regex replacement during
title/year extraction and cleanup, including strings without tag delimiters.
Date-shaped names additionally create a Gregorian calendar and date components,
construct a date, and extract components again solely to reject invalid dates.
Both operations have narrower alternatives that can preserve their existing
results.

## Candidate behavior

### Avoid impossible tag replacements

The new `removingTags(from:)` helper scans UTF-8 for ASCII `[` or `{`. When neither
exists, the tag regex cannot match, so the helper returns the input. When either
exists, it runs the original Foundation replacement with the same regex, range,
and empty replacement template.

The byte scan matters: an opener followed by a combining mark or variation
selector may be part of a larger Swift `Character`. Scanning for the opener byte
still sends that string through the original regex. Unmatched, crossed, and
nested-looking delimiters retain the regex's existing first-closing-delimiter
behavior. Full-width brackets remain ordinary title text. This change does not
introduce a new tag parser or normalize Unicode.

### Validate date components directly

`isValidAirDate` checks positive days, supported months, and each month's maximum
day. February uses the Gregorian divisible-by-4, century, and divisible-by-400
rules. The date regex's year token covers 1900 through 2099, including the
different leap-year behavior of 1900 and 2000.

The existing regexes, guarded `Int` conversions, forward/reverse orientation
heuristic, and invalid-date early return remain in place. Unicode digits that
the regex matches but `Int` cannot parse still preserve the unknown filename.
Reverse names with a first component above 31 still reject: the existing
orientation heuristic passes that component as the year and the four-digit year
as the day, which exceeds every month length. No year-domain precondition was
added. Classification, catalog IDs, edition, variant, and display formatting are
unchanged by the proposed rules.

## Baseline and provenance

The reference is the complete production source at commit
`68274d1b09dcc866296321a5a8858efc297c4f19`. Its frozen copy and identity are recorded
in the benchmark's
[`baseline/manifest.json`](../Benchmarks/MediaNameRecognition/baseline/manifest.json).
Independent review verified that the copy matches the Git source byte for byte,
including the manifest's SHA-256 and Git blob identifier.

[`run.py`](../Benchmarks/MediaNameRecognition/run.py) snapshots the baseline,
candidate, harness, actual recognition tests, generated package manifest, and
runner before building. Evidence includes source hashes, compiler and host
details, command logs, build-product hash receipts, differential records, and raw
timing records. Archived evidence may omit binaries; verification distinguishes
retained hash receipts from build-product bytes that remain available to check.
The final production, test, harness, and runner sources match both completed
platforms' measured snapshots. Documentation, evidence packaging, and removal of
the temporary branch-push workflow trigger happened afterward.

| Measured source | SHA-256 |
| --- | --- |
| Baseline | `b9e75457eccae3c30e09817ce3520750429935b2af646532ac290b18e4aee8fb` |
| Candidate | `47b01794217ab979973e045a8d03e14f21d6d4eeeaf43bcd7e90bbd5a82d4295` |
| Harness | `fd5abac9b0c734a92706efa8669397d330e677399301497675414ea4c3fab118` |
| Runner | `b37b1865e2ffc150e36005a4808a5a89d1dd30fcb8b04ba4adc491b529831bc9` |
| Recognition tests | `6850282f759af9c10c2a41db95d2450a49a56c4b453b82b18defce512d254acf` |

## Correctness qualification

The new
[`dateBoundariesMatchGregorianCalendar`](../Tests/IlliquidCoreTests/MediaNameRecognitionTests.swift)
test uses the original Gregorian UTC Calendar round trip as an independent
oracle. It exercises every year from 1900 through 2099, months 0 through 13, and
days 0, 1, 28, 29, 30, 31, 32, and 99 in both field orders: **44,800 public-parser
cases**. Invalid cases must keep the raw title and have no air date or movie year.
Additional regressions cover combining marks after tag openers, variation
selectors, malformed tags, and byte-preserving Unicode titles.

The differential harness serializes all twelve stored properties and all three
public computed properties of every result. Baseline and candidate JSONL records
are compared byte for byte, so canonically equivalent Swift strings cannot hide
normalization changes. The corpus covers movies, episodes, extras, folder
evidence, multiple date tokens, Unicode digits and whitespace, NFC/NFD titles,
emoji, and malformed delimiters.

With `--exhaustive-dates`, the corpus additionally covers all supported valid
dates and nearby invalid month/day boundaries in both orders: 200 years × 14
months × 33 days × 2 orders, or **184,800 additional records**. This is not every
invalid two-digit month/day spelling through 99. The ordinary corpus also checks
reverse first components 32 through 99. In each completed platform run,
**188,534 baseline/candidate records match byte for byte**.

## Measurement method and workloads

The runner compiles each exact recognizer source as a separate `IlliquidCore`
module and dynamic library. An importing harness is compiled separately, using
`-O -whole-module-optimization -swift-version 6 -warnings-as-errors`. This preserves
the client/module boundary and prevents whole-module optimization from
specializing recognition to harness fixtures.

Each process creates 64 input paths and performs 128 warmup calls. The timed loop
retains results in a pre-reserved array. Both wall and process CPU clocks stop
before complete-result serialization and checksumming. Thus the measured scope
is recognition plus result retention; output verification remains observable
without adding serialization to the timed interval.

The default cohort uses six baseline/candidate pairs and 4,000 calls per process.
Variant order alternates AB/BA and workload order rotates, producing 96 fresh
timing processes. Reports preserve individual paired ratios and per-variant
medians, minima, and maxima. Results should be presented per workload.

| Workload | Its 64 synthetic fixtures exercise |
| --- | --- |
| `dated-forward` | Valid year-month-day episodes, varying years, months, days, and bulletin suffixes. |
| `dated-reverse` | Valid day-month-year episodes with dotted separators and episode titles. |
| `dated-invalid` | Invalid leap days, month lengths, zero or oversized fields, and both orientations. |
| `dated-unicode` | Unicode titles with two valid-date forms and six Unicode-digit rejection forms. |
| `movies` | Eight ASCII/Unicode titles, year-bearing folders, release markers, and varying years. |
| `episodes` | Season-folder inference and explicit multi-episode filenames with release markers. |
| `ambiguous` | Unclassified recordings, numeric fragments, isolated episode markers, and Unicode names. |
| `tags` | Tagged movies and episodes, editions and IDs, malformed delimiters, and one dated form. |

The Unicode and tags groups are mixed workloads; their aggregate timings do not
isolate one optimization.

## Results and validation

### Native macOS cohort

[GitHub Actions run 39069883928](https://github.com/Jagalite/illiquid/actions/runs/39069883928)
completed successfully on the clean research commit
`8df44b9630dc1814c44031cad6ba3c2925db7a93`. The host was an Apple M1 virtual machine
running macOS 26.6.2 with Apple Swift 6.3.3 and Xcode 26.6. The component job used
six pairs, 4,000 calls per process, and the expanded date corpus. All 96 timing
observations are retained in the
[raw measurements](../Benchmarks/MediaNameRecognition/evidence/results/macos/measurements.jsonl);
the [summary](../Benchmarks/MediaNameRecognition/evidence/results/macos/summary.json)
contains the full ranges and individual ratios.

The two time columns below are separate per-variant medians. Each percentage is
`100 × (1 − median(candidate / baseline within each pair))`, so it need not equal
the percentage obtained by dividing the two separate medians. Positive reductions
mean less time; a negative reduction is a slowdown.

| Workload | Baseline median µs/call | Candidate median µs/call | Median paired wall reduction | Median paired CPU reduction | Faster wall pairs |
| --- | ---: | ---: | ---: | ---: | ---: |
| Forward dates | 35.433 | 31.886 | 13.19% | 13.21% | 5/6 |
| Reverse dates | 38.508 | 31.496 | 14.01% | 14.96% | 5/6 |
| Invalid dates | 21.961 | 18.524 | 15.38% | 16.50% | 5/6 |
| Unicode dates | 23.646 | 23.547 | 7.42% | 7.63% | 5/6 |
| Episodes | 35.473 | 28.903 | 18.98% | 18.62% | 6/6 |
| Movies | 28.015 | 26.275 | 4.97% | 4.99% | 5/6 |
| Tags | 31.328 | 29.132 | 9.70% | 9.60% | 6/6 |
| Ambiguous names | 28.390 | 28.500 | **−0.52%** | **−1.15%** | 2/6 |

Overall, 39 of 48 wall comparisons and 42 of 48 CPU comparisons are faster. The
ambiguous-name result is a small observed regression, with four of six pairs
slower. No observations were discarded. The virtual host shows some scheduling
variation: episode pair 0 has a wall ratio of 0.556 but a CPU ratio of 0.808;
forward-date pair 2 has wall 1.147 but CPU 0.915. The CPU medians corroborate the
seven improving workloads. These six-pair results are descriptive measurements,
not confidence bounds or a promise of the same gain on every machine.

The native component job passed the same **12 recognition tests** for the
baseline and candidate in **both debug and release**. The separate native job
built and linked the debug application graph and passed **71 selected tests in
seven suites**, covering naming, sidecars, NFO fields and episode scope,
PlexMatch mappings, and source media organization. The
[native integration log](../Benchmarks/MediaNameRecognition/evidence/results/macos-integration/tests.log)
preserves the actual selection and results. This was not the entire repository
test suite.

### Linux corroboration and exploratory variants

The completed Linux cohort used Swift 6.3.2 on Ubuntu 24.04, x86-64, glibc 2.39,
with the process pinned to CPU 0. It used the same final sources and six-pair
settings. Its checkout receipt includes working-tree changes; the exact source
snapshots and hashes above identify what was measured. The
[raw measurements](../Benchmarks/MediaNameRecognition/evidence/results/linux/measurements.jsonl)
and [summary](../Benchmarks/MediaNameRecognition/evidence/results/linux/summary.json)
are kept separately from the native cohort.

| Workload | Baseline median µs/call | Candidate median µs/call | Median paired wall reduction | Faster wall pairs |
| --- | ---: | ---: | ---: | ---: |
| Forward dates | 37.011 | 34.231 | 7.36% | 6/6 |
| Reverse dates | 37.965 | 35.467 | 7.15% | 6/6 |
| Invalid dates | 23.572 | 21.320 | 9.53% | 6/6 |
| Unicode dates | 30.186 | 29.220 | 3.14% | 6/6 |
| Episodes | 41.707 | 38.817 | 6.86% | 6/6 |
| Movies | 33.447 | 32.048 | 4.18% | 5/6 |
| Tags | 35.524 | 34.995 | 1.39% | 5/6 |
| Ambiguous names | 32.604 | 30.902 | 4.98% | 6/6 |

All eight Linux paired medians improved, and 46 of 48 pairs were faster in both
wall and CPU time. The two slower wall observations were movies (+0.15%) and tags
(+1.92%). Separately retained logs establish all four Linux baseline/candidate
debug/release test configurations passing the same 12 tests.

Short two-pair Linux explorations isolated each production change. The tag-only
variant suggested broader benefit, including 9.2% lower paired wall time for
episodes and 6.2% for movies. The date-only variant showed 5.6% lower forward-date
time, with smaller or mixed results elsewhere. These exploratory cohorts are
too small to attribute the combined native gain precisely. Their complete raw
observations, alternate sources, and 3,734-record comparisons are archived;
they are not pooled into either final cohort.

### Interrupted experiments and independent review

An early Linux corpus included the directory-only string `.` and trapped in
Foundation. Independent probes reproduced the same trap with the frozen
baseline, candidate, and `NSString.deletingLastPathComponent` alone; both
recognizers passed the `.mkv` control. The final corpus excludes only that
directory-only input, outside the actual media-file caller contract. Empty paths,
`/`, and `.mkv` remain. This PR does not fix that pre-existing Linux edge case.
The four successful Linux test configurations preceded this corpus correction;
their production and test sources already match the final source hashes.

An initial toolchain attempt failed before qualification. A later Linux timing
cohort stopped at 86 of 96 observations when the shared filesystem filled. Its
observations are retained as incomplete and were neither selected nor combined
with the fresh, complete final cohort. Reproducible build/cache products were
removed before archival; their original hash receipts remain.

Independent review checked the production semantics, source identities, complete
corpus bytes, recorded commands, and wall/CPU summaries recomputed from the raw
measurements. No blocking correctness or methodology finding remains. The
[evidence index](../Benchmarks/MediaNameRecognition/evidence/README.md) provides
inspectable results and a complete compressed archive, including incomplete
experiments and diagnostic sources.

## Reproduction and limits

From the repository root with an appropriate Swift toolchain:

```sh
python3 Benchmarks/MediaNameRecognition/run.py \
  --mode all --pairs 6 --iterations 4000 --exhaustive-dates \
  --output /tmp/illiquid-media-name-recognition
```

Use a new or empty output directory. `--mode verify --output PATH` rechecks the
saved evidence. The native workflow also builds the application dependency graph
and runs recognition-consumer tests separately from the component experiment.
For archived runs, first extract the evidence as documented in its index; the
archive preserves the original paths and source snapshots required by the
verifier. Compiler products are omitted, and verification explicitly reports
zero present binaries rather than claiming to have revalidated their bytes.

These fixtures measure warm calls on reused filenames. They do not establish
cold regex-initialization cost, filesystem scan throughput, sidecar-reading
latency, UI responsiveness, allocation counts, or whole-app gains. Platform and
compiler results must remain separately identified. Native execution is needed
to qualify the macOS application; the native build and selected consumer tests
provide that qualification for this change. They do not establish end-to-end
performance.
