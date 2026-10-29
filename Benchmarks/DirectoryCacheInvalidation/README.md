# Directory-cache invalidation

## Question and change

Can cached-tree invalidation avoid building a temporary set of every cached
directory path while preserving cache values, expansion policy, cancellation
behavior, and observable updates?

The frozen baseline is the complete production
`SourceTreeDirectoryState.swift` at commit
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72` (Git blob
`c41afc25e48a5983aa85304cce8651af5ff19fe2`). The runner checks that blob identity.

The baseline builds a union of the contents and error dictionaries' keys,
filters that set to the affected subtree, then writes to both dictionaries for
every selected key. The candidate collects each dictionary's matching keys in
detached arrays, then removes those keys from their own dictionaries. Both
arrays are materialized before mutation; neither retains dictionary storage.
Cancellation, root normalization, expansion handling, and path containment use
the existing production code.

Both algorithms still scan the cached keys. The proposed benefit is avoiding
the temporary union and absent-key mutations. This is not an asymptotic claim.

## Reproduce

Requires Python 3.10+ and Swift 6.1+ with its bundled Testing module.

~~~sh
python3 Benchmarks/DirectoryCacheInvalidation/run.py \
  --mode all --pairs 8 --target-ms 80 \
  --output /tmp/illiquid-directory-cache-new
~~~

The output directory must not already exist. `--mode tests` or
`--mode benchmark` selects one phase. `--log-evidence` additionally prints
machine-readable evidence to CI logs.

When the shared Kyoto queue is available, submit the entire runner through it:

~~~sh
python3 /Volumes/seed1/Projects/kyoto/kyoto.py submit -- \
  python3 Benchmarks/DirectoryCacheInvalidation/run.py \
  --mode all --pairs 8 --target-ms 80 \
  --output /tmp/illiquid-directory-cache-new
~~~

Inspect `show JOB_ID`, `logs JOB_ID`, and `wait JOB_ID` before reporting success.
On hosts without Kyoto the runner announces that limitation and builds directly,
serially, with isolated temporary build and module-cache directories. It does not
use the repository's `.build` directory.

The `Directory cache invalidation performance` workflow runs this same command
on Ubuntu 24.04 and macOS 26 with Xcode 26.6. Each platform is a separate cohort.

## Measurement boundary and source fidelity

Each observation times complete production `invalidateCachedTree` calls:
its empty running-load check, lexical root normalization, cache-key selection,
expansion policy, and removals. Fixtures have no active load tasks.

The Core module contains the complete `NormalizedFileURL` and
`MediaNameRecognition` sources. The App module contains the complete
`SourceTreeDirectoryState` and `SourceFilesystemInvalidation` sources plus the
verbatim `SourceTreeEntry`, `SourceDirectoryListing`, and `SourceTreeIdentity`
declarations from `SourcesSidebar.swift`. The existing guarded declaration
extractor fails if declaration boundaries drift. Source and slice hashes are
recorded.

A separately compiled driver imports the App module. Both libraries use
`-O -whole-module-optimization -swift-version 6`; cross-module optimization is
not enabled.

Only the benchmark build appends `FixtureSupport.swift` to the staged complete
directory-state file. This same-file extension seeds the real observed cache
properties. The production prefix and appended adapter have separate hashes.
The actual-loader tests include no adapter.

Each timed call receives a fresh state with independently constructed dictionary
tables. The factory receives arrays of key/value pairs and creates new tables;
it does not copy a retained template dictionary. Entry payload arrays can share
fixture values. Setup, validation, output serialization, and state destruction
are outside the measured interval. The explicitly labelled retained-snapshot
case holds both original dictionaries alive through invalidation and checks
their values afterward.

## Workloads

| Case | Cached directories | Matching contents | Errors | Special condition |
|---|---:|---:|---|---|
| empty | 0 | 0 | None | Fixed overhead control |
| singleton | 1 | 1 | None | Small cache control |
| small-mixed-32 | 32 | 16 | Every seventh entry | Prune expansion |
| narrow-256 | 256 | 16 | Every eleventh entry | Preserve expansion |
| narrow-4096 | 4,096 | 64 | Every eleventh entry | Preserve expansion |
| missing-4096 | 4,096 | 0 | Every eleventh entry | Unmatched tree |
| all-4096 | 4,096 | 4,096 | None | Invalidate filesystem root `/` |
| all-errors-1024 | 1,024 | 1,024 | Every entry | Fully overlapping key sets |
| missing-all-errors-1024 | 1,024 | 0 | Every entry | Unmatched tree with full overlap |
| unicode-long-256 | 256 | 64 | Every fifth entry | Long Unicode paths; prune expansion |
| retained-snapshot-4096 | 4,096 | 64 | Every eleventh entry | Retain both original dictionaries |
| prune-expansion-4096 | 4,096 | 64 | Every eleventh entry | Prune expansion |
| error-only-32 | 0 | 0 | 32 standalone error keys | Robustness control; 16 errors match |

Ordinary error keys overlap contents, matching the real loader's behavior.
Error-only keys are a robustness control, not the basis for a performance claim.
All-error cases matter because separate filtering performs containment checks
twice for overlapping keys, whereas the baseline filters each union member once.

## Correctness and sampling

Both variants run the actual directory-state and source-browser regression
tests in debug and release, including retained snapshots, Observation delivery,
cancelled and stale loads, sibling-prefix boundaries, and expansion policy.

Before timing, full result receipts must match between baseline and candidate.
They include exact UTF-8 keys, URL spellings, entry values, errors, expansion,
loading IDs, and task keys. Every measured call additionally checks all surviving
cache values and expansion against its independent removal contract. The
retained-snapshot case checks the complete original dictionaries.

Each child process performs three untimed warmups. Calibration uses the faster
variant's process CPU duration to choose a shared iteration count targeting
80 ms per process, capped at 100,000 calls. Calibration observations and any
target shortfall are retained. Eight fresh-process AB/BA pairs run serially per
workload. Each call has its own CPU/wall interval because it mutates fresh state.

Process CPU time uses `CLOCK_PROCESS_CPUTIME_ID`; elapsed time uses
`DispatchTime`. CPU intervals include the two wall-clock reads. Timing overhead
matters most for empty/singleton controls. The report retains absolute medians,
ranges, paired geometric-mean speedups, and a paired bootstrap interval from
4,000 deterministic resamples. Intervals describe this cohort, not all hardware.
There is no noisy timing threshold in CI.

The artifact includes source receipts, commands, compiler/test logs, parity
receipts, calibration, raw observations, and summaries. Build products are
temporary and excluded.

## Results and limits

### Linux component cohort

[GitHub Actions run 40639635162](https://github.com/Jagalite/illiquid/actions/runs/40639635162),
job `122654504613`, completed successfully on 2026-10-28 using Swift 6.4,
Ubuntu 24.04.5, and an x86_64 AMD EPYC 7763 hosted runner (4 logical CPUs).
The measured source commit is
`9318c0726c88288b4fb6ce345e150cf817394f02`.

All four test executions passed: 20 focused tests in debug and release for
both baseline and candidate. Full output receipts matched for all 13 workloads.
All calibration targets were reached. The final cohort contains 208 measured
observations, eight fresh-process AB/BA pairs per workload.

The table reports median CPU microseconds per complete invalidation and the
geometric mean of paired baseline/candidate ratios. The speedup interval is the
paired bootstrap interval described above.

| Workload | Baseline µs | Candidate µs | Paired speedup | 95% interval |
|---|---:|---:|---:|---:|
| empty | 4.35 | 4.32 | 0.993× | 0.960–1.014× |
| singleton | 5.07 | 4.87 | 1.040× | 1.033–1.046× |
| small-mixed-32 | 19.14 | 15.94 | 1.195× | 1.163–1.226× |
| narrow-256 | 48.38 | 30.67 | 1.574× | 1.552–1.597× |
| narrow-4096 | 793.68 | 372.07 | 2.139× | 2.114–2.163× |
| missing-4096 | 766.99 | 343.99 | 2.223× | 2.186–2.261× |
| all-4096 | 1805.4 | 1194.9 | 1.510× | 1.502–1.520× |
| all-errors-1024 | 587.27 | 597.37 | 0.985× | 0.971–0.999× |
| missing-all-errors-1024 | 237.44 | 158.45 | 1.482× | 1.454–1.506× |
| unicode-long-256 | 4148.0 | 2260.5 | 1.848× | 1.753–1.952× |
| retained-snapshot-4096 | 879.06 | 502.97 | 1.740× | 1.715–1.764× |
| prune-expansion-4096 | 1322.0 | 951.28 | 1.376× | 1.337–1.408× |
| error-only-32 | 17.56 | 10.74 | 1.629× | 1.583–1.674× |

The narrow 4,096-directory case improved from about 794 µs to 372 µs; the
candidate was faster in all eight pairs. Empty-cache results overlap.
The full all-error case is a small regression: about 587 µs to 597 µs, with a
paired speedup of 0.985×. This is consistent with the extra containment scan
when both dictionaries have the same keys, and is retained as a tradeoff rather
than omitted. The other error-heavy control (an unmatched subtree) improved.

`evidence/linux.json` retains the source/host manifest, all calibration and
measurement rows, test counts, and summaries recovered from the CI log.
The [uploaded artifact](https://github.com/Jagalite/illiquid/actions/runs/40639635162/artifacts/12794254567)
also contains full test logs, command records, and exact byte receipts
(14-day retention; archive SHA-256
`93256f56a23cb5a4a14d6c991b48dca18135a361a2ae13792f74f1621baef241`).
The committed evidence remains available after artifact expiry.

### Native qualification

The macOS 26 job is queued. The Linux results establish a portable component
improvement; no macOS timing result is claimed yet.

The measurement covers cached-tree invalidation. It does not measure filesystem
enumeration, FSEvents delivery, debounce latency, SwiftUI rendering, decoding,
playback, or energy. Active-load cancellation is covered by regression tests,
not by the timing fixtures.

Observation continues to report both changed cache properties. The candidate
avoids incidental writes to absent entries, so per-key notification count and
interleaving are intentionally not treated as an application contract.
