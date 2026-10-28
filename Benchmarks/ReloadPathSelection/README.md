# Sidebar reload-path selection

This study measures the complete production
`SourceTreeDirectoryState.reloadPaths(for:activeRoots:expandedFolderIDs:)`
method against main at `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`.
The production change is in [SourceTreeDirectoryState.swift](../../Sources/IlliquidApp/UI/SourceTreeDirectoryState.swift).

## Why this operation matters

[SourcesSidebar.applyFilesystemEvents](../../Sources/IlliquidApp/UI/SourcesSidebar.swift) calls reload selection synchronously on
the main actor after the sidebar's 150 ms filesystem-event debounce. It chooses
which active roots and expanded directories should be loaded again. A single
batch can include many directories: the upstream event buffer accepts up to
4,096 notifications before switching to full-root recovery.

The original method already constructs a set of normalized active-root paths,
but then calls SourceTreeIdentity.isFolderID(_:inside:) for every candidate
directory and root. That helper normalizes the root URL again. It also performs
containment checks before rejecting collapsed directories.

Empty plans and an empty active-root list return immediately. For other calls,
the change reuses the prepared normalized paths:

1. An exact active root is eligible immediately, including a collapsed root.
2. A non-root path must be expanded before any containment scan is useful.
3. An expanded path uses the existing component-boundary containment predicate
   against the prepared root strings.

folderID(for:) and isFolderID(_:inside:) use the same lexical normalization.
The existing filesystem-root special case remains in the shared containment
predicate. The optimization introduces no persistent cache or new invalidation
policy.

## Reproduction

Requires Python 3.10+, Swift 6.1+ with bundled Swift Testing, and a checkout
containing the pinned baseline commit. No package dependencies are downloaded.
Use a new or empty output directory for every invocation.

On hosts without the shared Kyoto build queue:

~~~sh
python3 Benchmarks/ReloadPathSelection/run.py \
  --output /tmp/illiquid-reload-selection --pairs 6 --target-ms 100

# Correctness and differential verification only:
python3 Benchmarks/ReloadPathSelection/run.py \
  --tests-only --output /tmp/illiquid-reload-selection-tests
~~~

When Kyoto is available, submit the entire experiment through it so its builds
remain serialized, preserving the intended command and environment:

~~~sh
python3 /Volumes/seed1/Projects/kyoto/kyoto.py submit -- \
  python3 Benchmarks/ReloadPathSelection/run.py --via-kyoto \
  --output /tmp/illiquid-reload-selection --pairs 6 --target-ms 100
~~~

Inspect show JOB_ID, logs JOB_ID, and wait JOB_ID before interpreting results.
The runner refuses direct invocation when Kyoto is available; --via-kyoto
confirms that the entire command is executing as a submitted job.
The hosted CI machines do not have Kyoto; the runner reports this before direct
builds. All builds use at most two jobs and each package's builds execute
sequentially. The --swift option selects a toolchain, and --baseline-ref
explicitly changes the comparison revision.

The workflow uses `ubuntu-24.04` and `macos-26-intel`; its Intel macOS job
selects Xcode 26.6. Intel macOS measurements do not establish Apple Silicon
performance.

## Correctness

The benchmark packages include the **complete production** directory consumer
and filesystem planner, copied verbatim for each variant. The existing guarded browser-support extractor copies
production core files and verbatim portable declarations from AppModel and
SourcesSidebar. Both variants use identical support sources, tests, benchmark
driver, and a mechanically renamed complete baseline consumer as the oracle.
A source-hash gate requires the production directory consumer to be the only
difference between the measured packages.

The repository's browser-search and directory-consumer tests run against both
variants in debug and release, with warnings treated as errors. Each binary
also compares full output sets with the pinned oracle for 1,293 deterministic
cases: 1,280 seeded combinations and all 13 measurement fixtures. Coverage
includes empty and duplicate roots, overlapping roots, lexical dot segments,
relative URLs, filesystem root, canonical Unicode spellings, similar-name
siblings, inactive roots, collapsed descendants, and the union of root rescans
and directory reloads. Tree invalidation alone must not add a reload candidate.

## Measurement

Thirteen workloads cover empty input and no-root controls; one and 32 root
rescans; one, 32, and 256 expanded paths under one root; mixed batches under
eight and 32 roots; collapsed and out-of-root paths; filesystem root; and
overlapping roots. The largest synthetic batch contains 1,024 paths. Fixture
construction uses explicit directory hints and does not create media files.

Each timed iteration calls the entire production method, including creation
of the normalized-root set and the final result set. Fixture construction,
five warmup calls, the baseline oracle, result sorting, and full equality
checks are outside the timed interval. The result count is consumed each
iteration, and the final complete set is checked after timing.

The driver calibrates a shared iteration count for each baseline/candidate
pair (targeting 100 ms for the slower variant and at least 20 ms for the faster
variant, capped at 500,000 iterations), then launches six pairs of fresh processes in alternating AB/BA order.
Single-call calibration includes clock overhead, so observed windows can be
shorter than the target, especially for nanosecond controls. Actual durations
are preserved. The driver keeps all samples and records both monotonic wall time and process CPU
time. Linux measurement subprocesses inherit a single allowed CPU affinity;
macOS has no affinity override. Set hash randomization remains enabled, so
the observed ranges include variation in root-set iteration order.

The summary records absolute medians and ranges and the median percentage
reduction within paired observations. Every raw observation is retained.
Other receipts include source and executable hashes, compiler and platform
details, full test/command logs, verification traces, calibration samples, and
completion status. The workflow uploads these without build products or module
caches. No wall-time threshold is imposed on shared CI.

## Scope

These are component measurements of reload selection on hosted machines.
They do not time FSEvents delivery, the debounce delay, directory enumeration,
filesystem/network latency, SwiftUI rendering, media decoding, or playback.
The complete app and live macOS UI are outside the isolated test package.
No claim is made about physical-Mac energy, memory footprint, or end-to-end
refresh latency.

## Results

The final Linux experiment passed at commit
1fd26266aa17736d4be6366a1e315a7d82afa4c5 on an AMD EPYC 7763 hosted runner,
using Swift 6.4 and Ubuntu 24.04. The complete operation was faster in all six
pairs for all 13 workloads. CPU-time reductions tracked wall-time reductions.

Times below are median microseconds per complete call. Percent reductions are
medians of the ratios within each AB/BA pair, so they need not exactly equal
the ratio of the displayed absolute medians.

| Workload | Baseline µs | Candidate µs | Paired reduction | Faster pairs |
|---|---:|---:|---:|---:|
| empty-plan | 5.00 | 0.0100 | 99.8% | 6/6 |
| no-active-roots | 0.0989 | 0.0067 | 93.3% | 6/6 |
| root-rescan-1 | 5.65 | 3.14 | 44.3% | 6/6 |
| root-rescan-32 | 1,519 | 89.80 | 94.1% | 6/6 |
| expanded-1x1 | 5.70 | 3.20 | 43.6% | 6/6 |
| expanded-1x32 | 95.64 | 12.75 | 86.7% | 6/6 |
| expanded-1x256 | 746.35 | 84.63 | 88.7% | 6/6 |
| mixed-8x256 | 4,031.8 | 212.53 | 94.7% | 6/6 |
| mixed-32x1024 | 58,227.3 | 2,290.3 | 96.1% | 6/6 |
| collapsed-32x1024 | 46,508.9 | 196.96 | 99.6% | 6/6 |
| outside-8x256 | 5,494.4 | 354.79 | 93.6% | 6/6 |
| filesystem-root-256 | 415.55 | 58.74 | 85.9% | 6/6 |
| overlapping-8x256 | 521.06 | 132.04 | 74.7% | 6/6 |

The two empty-input controls execute in nanoseconds after the early guard.
Their short sampling windows are retained in the receipts; their percentages
are not an estimate of user-visible latency. For nontrivial workloads, the
shortest candidate observation was about 18 ms in this run.

All 21 existing and new tests passed for baseline and candidate in debug and
release. Each of the four binaries also passed all 1,293 full-set comparisons.
The run retained 156 timing observations, with no outlier removal.

- [Qualified Linux job](https://github.com/Jagalite/illiquid/actions/runs/40635086109/job/122640091230)
- [Complete Linux artifact](https://github.com/Jagalite/illiquid/actions/runs/40635086109/artifacts/12793057050)
- [Committed Linux receipts](evidence/linux.json)

An initial exploratory run identified a 22 ns empty-root overhead before the
early guard was added. That run used a different CPU and compiler; only
within-run comparisons are used above. The final comparison includes the
guard, the explicit root-normalization tests, and longer timing cohorts.

### Native macOS qualification

The macOS 26 jobs have not obtained a hosted runner, so no native macOS
performance or test result is claimed here. The first ARM job was canceled
when the final empty-input guard and tests were pushed; the final ARM job
was canceled when a dedicated Intel macOS 26 probe was submitted. Those
cancellations do not affect the completed Linux job linked above.

[The Intel macOS probe](https://github.com/Jagalite/illiquid/actions/runs/40636029156)
was still queued when this report was prepared. The pull request remains a
draft pending native component qualification. Its regular PR workflow also
includes Intel macOS 26 with Xcode 26.6. Darwin Foundation may have different
normalization costs, so Linux timings must not be treated as macOS estimates.
The full app, live sidebar interaction, and Apple Silicon performance remain
outside this experiment.

