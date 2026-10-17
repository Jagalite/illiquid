# NFO text-limit performance research

## Result and status

The first native qualification met the predefined performance target with exact output equality and passing baseline/candidate regressions. Complete parsing of the three intentionally fragmented fields took **95–98% less time**. The ordinary movie control was approximately unchanged. These measurements describe the parser and the fixtures below; they do not measure whole-library loading or playback.

The expanded campaign and unchanged-source PR replication both passed correctness checks and retained large fragmented-field gains. They identified a repeated Unicode fallback cost worth removing: the paired median change was +3.05% and then +9.01%. The ignored-plot control was +6.37% in one cohort and -2.80% in the next. Every result remains in the evidence record.

The current candidate stops trying the UTF-8 shortcut for a field after its first miss and resets that decision at the same two locations as the accumulated text. Its first native campaign passed all correctness checks and kept 95–98% fragmented-field improvements. With longer fallback and ignored-plot batches, their paired median changes were -0.34% and +1.75%. However, the small-movie control was +12.12% by independent medians and +14.81% by paired medians. That ordinary control still requires investigation before final acceptance.

Protocol 3 retains the exact production source and all other protocol-2 counts, but fixes movie, episode, and short-Unicode observations at 100,000, 50,000, and 50,000 parses. Twelve balanced AB/BA pairs remain fixed before measurement. This follow-up lengthens the short ordinary batches rather than treating their variation as proof that the regression is noise. Earlier cohorts and unfavorable results are preserved separately; their samples are not pooled.

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

## Completed first native campaign

- Baseline: `68274d1b09dcc866296321a5a8858efc297c4f19`.
- Measured candidate: `971d0b22e19b567dee0adaeca19a86d6be41224d`.
- [macOS run 39071387820](https://github.com/Jagalite/illiquid/actions/runs/39071387820), completed October 17, 2026.
- Hosted macOS 26.6.2, arm64; workflow selected Xcode 26.6.
- **52 tests passed in each of four runs:** baseline debug/release and candidate debug/release.
- **135 complete differential outputs matched exactly.** All benchmark receipts matched across variants and observations.
- Twelve measured pairs per workload, with six baseline-first and six candidate-first pairs. An additional warmup pair was retained but excluded from statistics.

Times are milliseconds per complete parse. Change is candidate/baseline minus one, calculated from independent medians. The paired ratio is the median of the twelve within-pair candidate/baseline ratios; these are different statistics. Negative changes and ratios below one favor the candidate.

| Workload | Baseline median, ms | Candidate median, ms | Median change | Paired ratio | Faster pairs |
|---|---:|---:|---:|---:|---:|
| `movie-small` | 0.014365 | 0.014228 | -0.95% | 0.9938 | 8/12 |
| `episode-small` | 0.017458 | 0.016230 | -7.04% | 0.9626 | 11/12 |
| `unicode-small` | 0.018314 | 0.016648 | -9.10% | 0.9052 | 12/12 |
| `ascii-boundary-4096` | 0.093331 | 0.051003 | -45.35% | 0.5482 | 12/12 |
| `ascii-fragmented-4096` | 12.788893 | 0.632953 | -95.05% | 0.0493 | 12/12 |
| `unicode-fragmented-4095-bytes` | 30.438984 | 1.074328 | -96.47% | 0.0352 | 12/12 |
| `unicode-fallback-2500` | 0.896670 | 0.687897 | -23.28% | 0.7803 | 12/12 |
| `combining-cdata` | 30.597912 | 0.624842 | -97.96% | 0.0209 | 12/12 |
| `ignored-long-plot` | 1.070860 | 1.085250 | 1.34% | 1.0003 | 6/12 |
| `ascii-over-limit-4097` | 0.088382 | 0.088406 | 0.03% | 1.0020 | 5/12 |
| `malformed-xml` | 0.008889 | 0.008764 | -1.41% | 0.9919 | 9/12 |
| `doctype-rejected` | 0.001060 | 0.001067 | 0.59% | 1.0005 | 5/12 |

All three targeted fragmented workloads exceeded the predefined 25% improvement target and favored the candidate in every measured pair. No ordinary or fallback control in this first campaign showed a 5% median regression. Small differences near zero should not be interpreted as reliable improvements.

The [initial artifact](https://github.com/Jagalite/illiquid/actions/runs/39071387820/artifacts/12114899396) contains all timing records, manifests, complete outputs, and test/compiler logs. Its ZIP SHA-256 is `d0dffbd981455d5521aa14c1e82c1450316a92fe914b6fad4db0282a72352214`. Actions artifact retention is 14 days. [The expanded branch summary](evidence/expanded-summary.json) preserves all thirteen workloads from run 39071828452. [The original byte-guard PR cohort](evidence/original-byte-guard/manifest.json), [raw timings](evidence/original-byte-guard/measurements.jsonl), [summary](evidence/original-byte-guard/summary.json), and [complete evidence ZIP](evidence/original-byte-guard/native-evidence.zip) preserve run 39073093655, including the slower controls. These cohorts precede the per-field refinement and longer control batches.

## Refined candidate, first campaign

[Run 39074402470](https://github.com/Jagalite/illiquid/actions/runs/39074402470) tested source blob `051c475fd33bcd16ec33f6b4b93ee98fffdb21d3` using protocol `2-longer-fallback-controls`. All four 52-test runs passed, all 136 differential outputs matched, and every benchmark receipt matched. An independent audit verified all 338 timing records, exact summary recomputation, all archive/hash checks, and the complete saved outputs.

| Workload | Median change | Paired median change | Faster pairs |
|---|---:|---:|---:|
| Movie, small | **+12.12%** | **+14.81%** | 4/12 |
| ASCII fragmented | -95.43% | -95.13% | 12/12 |
| Unicode fragmented | -96.02% | -96.17% | 12/12 |
| Combining CDATA | -98.02% | -97.97% | 12/12 |
| Repeated Unicode fallback | -1.19% | -0.34% | 6/12 |
| Ignored long plot | +2.05% | +1.75% | 3/12 |

The small-movie paired ratios range from 0.647 to 1.902, with measured process batches of 78–233 ms. This variation alone does not resolve the regression. Protocol 3 investigates it using longer ordinary control batches and unchanged production code.

The [manifest](evidence/refined-short-controls/manifest.json), [all thirteen summaries](evidence/refined-short-controls/summary.json), [raw observations](evidence/refined-short-controls/measurements.jsonl), [complete evidence ZIP](evidence/refined-short-controls/native-evidence.zip), and [provenance](evidence/refined-short-controls/provenance.json) retain this cohort permanently.

## Reproduce

Run on macOS with Python 3.10+ and Swift 6.1+. The runner uses the actual five MediaLibrary sources, including the Darwin-based sidecar reader.

```sh
git fetch --no-tags --depth=1 origin 68274d1b09dcc866296321a5a8858efc297c4f19
python3 Benchmarks/NFOTextLimits/run.py \
  --output /tmp/illiquid-nfo-text-limits \
  --rounds 12
```

Use a fresh output directory and a quiet host. The [workflow](../../.github/workflows/nfo-text-limits.yml) pins its macOS toolchain and executes this command. The manifest records the candidate commit and working-tree state, source/test/driver/runner Git blob hashes, environment, compiler flags, test counts, and acceptance criteria.

`--skip-tests` is available for an explicitly limited follow-up measurement; such a run alone does not satisfy the correctness criterion.

## Method and acceptance criteria

[`run.py`](run.py) reads baseline source bytes directly from pinned Git objects and builds separate baseline/candidate executables with `-swift-version 6 -O -parse-as-library`. It applies the same current five regression-test files to both implementations in debug and release. Those tests include the existing real sidecar reader, NFO field selection and episode scope, media-name recognition, and the new text-limit suite.

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

## Scope and evidence

The experiment measures complete warmed in-memory NFO parsing, including input validation, XML callbacks, text accumulation, metadata construction, and result consumption. It excludes file I/O, directory scanning, app startup, playback, rendering, GPU work, storage latency, and energy. The sidecar-reader tests check filesystem integration behavior separately.

The fragmented workloads intentionally stress the changed path. This research does not establish their frequency in actual NFO collections. Shared hosted runners also introduce variation; retain slower observations and control results alongside gains.

Each campaign produces `manifest.json`, `measurements.jsonl`, `summary.json`, `receipts.json`, `differential.json`, four test logs, and two compiler logs. Permanent evidence should retain the readable manifest/summary and raw measurements, with the repetitive complete receipts and logs in an archive. Executables, temporary test packages, dependency caches, and duplicate source trees are excluded.
