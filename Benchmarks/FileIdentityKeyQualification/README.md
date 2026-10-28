# Independent qualification of ASCII file identity keys

This study independently qualifies the implementation in
[PR #144](https://github.com/Jagalite/illiquid/pull/144), based on its exact
commit `630530f27be150823d4dd4737b15cec947bfd8c9`. The qualification PR is
stacked on that branch and **does not change production code**.

At the frozen main baseline, `NormalizedFileURL.persistenceKey(for:)` validates
and standardizes the input, normalizes Unicode, constructs another file URL,
then reads its path. #144 returns ordinary ASCII paths directly and retains
Foundation reconstruction for Unicode and unusual representations. This suite
checks exact output bytes and measures actual key, item-ID, comparison and
folder-lookup APIs, including fallback/control costs.

Three alternative PRs appeared while the initial independent prototype was
being studied. The final comparison uses #144's exact helper, not that prototype.
The selected helper's Git blob is `4e6867e927aaef29d9746244570e338f17884182`.
#144's existing workflow, tests, documentation and evidence are preserved.

## Reproduce

```sh
python3 Benchmarks/FileIdentityKeyQualification/run.py --mode all --pairs 10 \
  --output /tmp/illiquid-file-identity-qualification
```

Use a new output directory. Submit the entire command through Kyoto when the
repository's shared queue is available, as required by `AGENTS.md`. Hosted
qualification runners have no Kyoto queue; their builds run serially in isolated
directories. `--mode tests` and `--mode benchmark` select individual phases.

The baseline helper is frozen at main commit
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72` and verified against Git blob
`d90e4fc199eabfa4e554c3c8d01a1ed48277ae20`. Both variants use the same
remaining production files and tests copied from the candidate checkout,
including #144's additions to `LocalMediaSourceValidationTests.swift`.

## Method

- Run local-source, exact-key-byte, folder-playlist and folder-lookup tests on
  both variants in debug and release with warnings treated as errors.
- Compile the real production types into separate optimized libraries. Compile
  the driver separately. Both invocations explicitly use
  `-Xfrontend -disable-cmo`; separate compilation alone is not the guarantee.
- Construct and sort fixtures, verify exact results, compute signatures and
  perform warmup outside the timed region. Timed loops consume returned lengths
  or indices. Their overhead is included, with no subtraction.
- Calibrate both variants to choose one shared iteration count per workload,
  targeting approximately 100 ms or more per process.
- Retain ten fresh-process pairs in alternating AB/BA order, with all calibration
  trials, raw samples, hashes, compiler/environment details and result receipts.
- Include short/root/long ASCII paths, escaped and raw localhost paths, NFC/NFD
  Unicode fallback, unsupported sources, valid/invalid item IDs, and empty,
  singleton, early-hit, last-hit and miss playlist lookups.
- Require byte/behavior parity. The initial portable investigation threshold
  is at least 15% median reduction and 8/10 faster pairs for ordinary ASCII
  keys and the 512-item last-hit/miss cases. Investigate repeatable control
  regressions above 10%; timings are reported, not used as flaky CI assertions.

The new regression suite compares optional UTF-8 arrays against the unchanged
`normalize(url)?.path` oracle and independently specified ASCII keys. Ordinary
Swift String equality can hide differences in Unicode representation.
Foundation's Darwin file-path constructor performs filesystem Unicode conversion;
see its [POSIX path construction](https://github.com/swiftlang/swift-foundation/blob/main/Sources/FoundationEssentials/URL/URL_File.swift)
and [file-reference conversion](https://github.com/swiftlang/swift-foundation/blob/main/Sources/FoundationEssentials/URL/URL_Impl.swift).
Linux parity does not qualify Darwin's bytes. Native qualification remains a
separate gate.

These are warmed component wall times. They do not measure filesystem discovery,
folder-open latency, playback, UI responsiveness, CPU utilization, or energy.

## Results: exact #144 implementation, Linux cohort

**Portable qualification passed. This suite's native macOS qualification is
pending, so the qualification PR remains a draft.**

[Run 40641068341](https://github.com/Jagalite/illiquid/actions/runs/40641068341)
passed on 2026-10-28 at measured commit
`1e0d10bcb234a888c0aae5e4d37316480760ca15`. The candidate helper is exactly
#144's `4e6867e927aaef29d9746244570e338f17884182` blob; no production file
differs from its parent `630530f27be150823d4dd4737b15cec947bfd8c9`.

Environment: Swift 6.4 (`swift-6.4-RELEASE`), x86_64 Linux
6.17.0-1022-azure, glibc 2.39, four reported logical CPUs, and an
AMD EPYC 7763 64-Core Processor model string. Both the library and driver were
compiled with `-O -whole-module-optimization -swift-version 6
-warnings-as-errors -Xfrontend -disable-cmo`.

All **31 tests in four suites** passed separately for baseline-debug,
baseline-release, candidate-debug and candidate-release. The seven new tests
cover **1,293 input configurations**, not 1,293 unique canonical paths.
#144's existing validation tests are included unchanged.

The run retained **400 timed observations** (20 workloads × 10 pairs × 2
implementations) and 81 calibration observations. Timed batches ranged from
93.194 ms to 279.559 ms. All workload signatures and checksums matched. An independent audit recomputed
all 20 summaries, checked every pair and calibration count, and matched 11
reviewed source-hash entries. It found no protocol or statistical discrepancy.

| Workload | Baseline (µs/call) | Candidate (µs/call) | Time reduction | Faster pairs |
| --- | ---: | ---: | ---: | ---: |
| `key-short` | 1.2966 | 0.7993 | 38.36% | 10/10 |
| `key-root` | 1.2374 | 0.7108 | 42.56% | 10/10 |
| `key-ascii64` | 3.9895 | 1.7805 | 55.37% | 10/10 |
| `key-long-ascii64` | 21.9133 | 7.8071 | 64.37% | 10/10 |
| `key-percent64` | 3.2120 | 1.4868 | 53.71% | 10/10 |
| `key-raw-localhost64` | 3.0086 | 1.5185 | 49.53% | 10/10 |
| `key-unicode-nfc64` | 2.3014 | 2.4193 | -5.12% | 1/10 |
| `key-unicode-nfd64` | 2.3297 | 2.4558 | -5.41% | 0/10 |
| `key-invalid-authority64` | 0.1485 | 0.1465 | 1.37% | 7/10 |
| `same-file64` | 5.8349 | 2.8660 | 50.88% | 10/10 |
| `item-id512` | 2.7983 | 1.3143 | 53.03% | 10/10 |
| `item-id-invalid64` | 0.1663 | 0.1638 | 1.50% | 10/10 |
| `folder-last32` | 92.1506 | 43.0302 | 53.30% | 10/10 |
| `folder-miss32` | 92.1545 | 42.7119 | 53.65% | 10/10 |
| `folder-last512` | 1420.8044 | 664.2292 | 53.25% | 10/10 |
| `folder-miss512` | 1427.2637 | 666.6172 | 53.29% | 10/10 |
| `folder-first512` | 5.5870 | 2.6139 | 53.21% | 10/10 |
| `folder-singleton-hit` | 5.5562 | 2.6172 | 52.90% | 10/10 |
| `folder-singleton-miss` | 5.3540 | 2.5635 | 52.12% | 10/10 |
| `folder-empty` | 0.0052 | 0.0046 | 11.74% | 10/10 |

Positive reductions mean less elapsed time; negative reductions are costs.
Ordinary ASCII keys improved by 55.37%, and the 512-item last-hit/miss lookups
improved by 53.25% and 53.29%. Each was faster in all ten pairs, exceeding the
predeclared portable threshold of 15% and 8/10 faster pairs.

### Tradeoffs and interpretation

The Unicode fallback has a measurable cost in this cohort:

- NFC: 2.3014 → 2.4193 µs/call, **5.12% slower**, or 117.88 ns/call;
  candidate faster in 1/10 pairs.
- NFD: 2.3297 → 2.4558 µs/call, **5.41% slower**, or 126.10 ns/call;
  candidate faster in 0/10 pairs.

These effects must not be described as fallback neutrality or "no regressions."
No fallback/control cost exceeded the predeclared 10% investigation threshold.
The unchanged empty-playlist path also shifted from 5.168 to 4.562 ns/call,
a 0.607 ns absolute difference; its relative percentage is not evidence of a
meaningful player improvement. No cause is assigned to that control shift.

The table reports warm component wall time, including loop and result-consumption
overhead. It does not establish macOS timing, folder-open or UI latency, decoding
performance, CPU utilization, or energy savings.

### Retained evidence and native gate

- [Manifest, compiler flags, source and binary hashes](evidence/linux/manifest.json)
- [Every raw observation, including calibration](evidence/linux/measurements.jsonl)
- [Full summaries and test receipts](evidence/linux/summary.json)
- [Qualification provenance, artifact digest and limitations](evidence/linux/receipt.json)

The action artifact additionally contains complete command/test logs and exact
source snapshots. The committed data above remain available after artifact
retention expires.

[Native qualification run 40641068250](https://github.com/Jagalite/illiquid/actions/runs/40641068250)
uses the same measured commit and was queued without a runner when this report
was recorded. Require this suite's native baseline/candidate tests, exact-byte
receipts, and benchmark/control review before marking this PR ready.

#144 separately has an
[initial successful native run](https://github.com/Jagalite/illiquid/actions/runs/40635089020)
against the same production-helper blob. That existing evidence is preserved
and is not relabeled as a result from this independent suite.

### Separation from the exploratory prototype

The earlier [prototype run 40639554616](https://github.com/Jagalite/illiquid/actions/runs/40639554616)
used a different helper and did not explicitly disable cross-module optimization.
Its original boundary wording was therefore insufficient. Its timings are
exploratory only and are not used anywhere in this qualification table. The final
candidate, explicit flags, hashes and receipts above supersede that prototype
for this PR's claims.
