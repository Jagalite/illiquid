# File identity path research

This experiment avoids URL reconstruction for ordinary ASCII persistence keys.
NormalizedFileURL.persistenceKey(for:) retains local-authority validation and
lexical standardization. Non-ASCII names and unusual paths keep the original
URL construction to preserve Foundation's exact persisted byte spelling.
The URL-returning normalize and filesystem-resolving preparation APIs are unchanged.

The frozen baseline helper is the exact Git blob from main at
ea2ff568237e2667f7b1aeee67b11a44ebe95b72. Its manifest is checked before any
compilation. All other production files are identical between variants and
copied from the current checkout; their hashes and exact staged sources are
retained in each run.

## Reproduce

Use Python 3.10+ and Swift 6.1+; no package dependencies or media SDK are needed.
Follow the repository's Kyoto coordination rule when that queue is available.
The runner keeps builds serial and gives every test configuration its own package.

~~~sh
python3 Benchmarks/FileIdentity/run.py --mode all --pairs 12 --target-ms 250 \
  --output /tmp/illiquid-file-identity
# A specific workload, or correctness only:
python3 Benchmarks/FileIdentity/run.py --mode benchmark --pairs 2 \
  --case lookup-1000 --output /tmp/illiquid-file-identity-smoke
python3 Benchmarks/FileIdentity/run.py --mode tests \
  --output /tmp/illiquid-file-identity-tests
~~~

Output must be a new or empty directory. Tests run on both implementations in
debug and release, including local-source validation and the existing playlist,
deduplication, natural-ordering, and selection regressions.

## Measurement

The actual production sources compile into a separate optimized dynamic library.
The common driver imports that module without cross-module optimization, keeping
the public calls observable. It checks results before and after timing, compares
key UTF-8 bytes with the unchanged normalize(url)?.path, verifies complete
deduplicated items, and requires matching receipts and sinks across variants.

Fourteen workloads cover ASCII, decomposed Unicode, relative, escaped, long ASCII, long Unicode and
rejected URLs; same-file comparisons; actual FolderPlaylist.index(of:) lookups
with 100, 1,000 and 10,000 entries; and actual playlist deduplication of 1,000 and
10,000 unique entries plus 10% duplicates. The lookup cases equally mix a final
item hit and a miss. The unchanged URL-returning normalizer and rejected inputs
are controls.

Each workload calibrates one shared iteration count until both variants take at
least the requested target time. All calibration trials are retained. Measurement
uses twelve fresh processes per variant in the native workflow with alternating baseline-first and
candidate-first order. Fixture creation, sorting, verification and warmup are
outside the timer. A small result observer remains inside both timings.

Results retain wall and process CPU time, all observations, ranges and paired
reductions, source/compiler/binary identities, command logs and test receipts.
The runner re-reads the persisted observation set and rejects missing rows or
parity mismatches. CI gates correctness and completed measurement, not a noisy
timing threshold.

These are component timings. They do not measure folder I/O, full folder-open
latency, UI responsiveness, decoding, whole-player CPU, or energy use. The native
macOS workflow provides the relevant Foundation implementation; results from a
different operating system must be labeled separately.

## Initial native results

[Run 40635089020](https://github.com/Jagalite/illiquid/actions/runs/40635089020)
completed on 2026-10-28 at commit
[6b0b45aa](https://github.com/Jagalite/illiquid/commit/6b0b45aa1c5d3efece3bed7defa6245a79ac617b).
The host was an Apple M1 virtual machine running macOS 26.6.2 with Apple Swift
6.3.3 and Xcode 26.6. The baseline and candidate each passed 64 tests in both
debug and release. All 208 measurements passed their behavioral checks.

This initial cohort used eight pairs and a 75 ms calibration target. Its short
observations showed noticeable scheduling noise: the unchanged normalizer
appeared 5.61% faster in paired wall time but only 1.39% faster in paired process
CPU time. Escaped keys and 1,000-survivor deduplication were the strongest initial
results. Small lookup differences are not established gains from this cohort.

| Workload | Baseline wall median | Candidate wall median | Paired wall reduction | Paired CPU reduction | Wall wins |
| --- | ---: | ---: | ---: | ---: | ---: |
| ASCII key | 6.163 µs | 5.282 µs | 8.96% | 2.90% | 7/8 |
| Unicode key (fallback) | 9.759 µs | 9.801 µs | -2.71% | -2.77% | 3/8 |
| Relative key | 9.451 µs | 9.129 µs | 6.67% | 6.65% | 7/8 |
| Escaped ASCII key | 7.014 µs | 5.697 µs | 25.27% | 24.67% | 8/8 |
| Long Unicode key (fallback) | 39.535 µs | 38.680 µs | 5.08% | 0.27% | 5/8 |
| Rejected URL (control) | 0.602 µs | 0.589 µs | 2.81% | 2.30% | 4/8 |
| Same-file comparison | 14.481 µs | 14.636 µs | 2.19% | 4.40% | 5/8 |
| Lookup in 100 items | 553.309 µs | 578.898 µs | 1.33% | 0.17% | 5/8 |
| Lookup in 1,000 items | 5.622 ms | 5.489 ms | 1.83% | 3.28% | 5/8 |
| Lookup in 10,000 items | 59.966 ms | 51.457 ms | 15.76% | 13.60% | 6/8 |
| Deduplicate 1,100 → 1,000 items | 6.584 ms | 5.861 ms | 12.95% | 10.82% | 8/8 |
| Deduplicate 11,000 → 10,000 items | 71.325 ms | 63.302 ms | 7.16% | 7.23% | 5/8 |
| Unchanged URL normalizer (control) | 6.318 µs | 5.879 µs | 5.61% | 1.39% | 5/8 |

Positive reductions mean less elapsed time. Percentages are medians of paired
reductions, so they need not equal the ratio of the two separate medians. All
ranges and unrounded observations are retained. Lookup timings average a final
item hit and a miss. Deduplication includes 10% extra duplicate input items and
checks the complete surviving items, including their order and metadata.

A confirmation cohort uses twelve pairs, a 250 ms calibration target, and a
fourteenth workload with long ASCII paths to expose the added scanner cost.
The production helper and regression tests are unchanged for that cohort.
Confirmation results will be added after native execution.

## Why the fast path is restricted

The legacy URL constructor remains significant for exact byte compatibility.
Foundation's framework implementation converts file paths through a filesystem
representation, including decomposed Unicode and C-string handling; see
[the versioned Foundation implementation](https://github.com/swiftlang/swift-foundation/blob/swift-6.3.2-RELEASE/Sources/FoundationEssentials/URL/URL_Swift.swift).
The candidate therefore keeps non-ASCII paths on the legacy construction path.
It also preserves that path for NUL bytes, repeated separators, unusual trailing
separators, non-absolute results, and file-reference prefixes. Authority checks
run before the shortcut. Filesystem identity resolution remains at its existing
preparation boundary.

The tests compare exact UTF-8 arrays rather than relying on Swift String equality,
which would hide canonically equivalent byte spellings. More than 1,000 raw URL
spellings are checked, along with constructed paths, relative bases, existing
authority rejection, symlink-retargeting, and playlist behavior tests.

## Retained evidence

The [initial evidence](evidence/native-initial/) contains the full timed
observations, environment/source/compiler/binary manifest, summary, independent
audit, and GitHub provenance. All 208 rows and every summary were independently
recomputed; all 24 source-hash entries matched 19 files fetched at the measured
commit. Artifact metadata records GitHub's reported ZIP digest; it is not a claim
that the archive bytes or compiled binaries were independently rehashed.

Observations use a lossless column table to avoid repeating field names hundreds
of times. Every original observation field and numeric value is retained:

~~~python
import json
from pathlib import Path
table = json.loads(Path("observations.json").read_text())
observations = [dict(zip(table["columns"], row)) for row in table["rows"]]
~~~

The workflow artifact additionally retains calibration trials, command/build/test
logs, and exact staged source copies for 14 days. The checked-in source hashes,
unrounded timed data, summaries and audit remain available after artifact expiry.
