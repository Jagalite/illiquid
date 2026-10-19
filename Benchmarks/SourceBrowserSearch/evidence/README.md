# Source-browser search qualification evidence

The performance measurements in the [research report](../../../Documentation/SOURCE_BROWSER_SEARCH_PERFORMANCE.md)
come from [qualification run 39320261280](https://github.com/Jagalite/illiquid/actions/runs/39320261280).
The production change, tests, and harness were published at PR revision
`6cd039e9a24310e4ab42e50298131d7dbfb56203`.

The Actions checkout is the PR merge revision, recorded in each environment
receipt. Both variants compile identical support sources from that checkout;
only `SourceBrowserFilter.swift` differs. The baseline Filter is extracted from
`68274d1b09dcc866296321a5a8858efc297c4f19`. The candidate Filter and harness are
identical to the published PR source. Main's newer media-recognition helper is
common to both variants and is used outside timing during fixture construction.

## Contents

Each cohort directory contains readable copies of its four test logs and
receipts, host information, and timing results. Linux also contains a separate
allocation cohort. Both native runs are retained separately:

| Directory | Job | Artifact | Test configurations | Timing observations |
|---|---:|---:|---:|---:|
| [linux](linux) | 118292442069 | 12220531524 | 4 × 9 passed | 216 |
| [macos](macos) | 118292441750 | 12220902097 | 4 × 9 passed | 216 |
| [macos-repeat](macos-repeat) | 118305093598 | 12221344849 | 4 × 9 passed | 216 |

The first two jobs are attempt 1; the native repeat is attempt 2. The completed
Linux job shown in attempt 2 is reused from attempt 1 and contributes no new
Linux observations. Within each cohort:

| File | Purpose |
|---|---|
| `measurements.jsonl` | Every recorded observation, including unfavorable pairs |
| `summary.json` | Per-variant medians/ranges and all within-pair reductions |
| `environment.json` | Compiler, host, checkout revision, affinity, locale, and source hashes |
| `baseline-build.json`, `candidate-build.json` | Compiled-source, final-manifest, harness, oracle, and executable hashes |
| `completion.json` | Successful completion count for the intended matrix |

The independent [Linux audit](linux/audit.json),
[first native audit](macos/audit.json), and [repeat audit](macos-repeat/audit.json)
verify the archives, source provenance,
test logs, command outputs, paired results, and summary arithmetic. Their case
statistics also retain variability and unfavorable observations. The
[replication plan](replication-plan.json) records the decision to collect exactly
one additional native cohort with unchanged settings and to retain both runs.
The [combined native record](combined-native.json) keeps the two cohorts
separate and adds a secondary descriptive summary of their 12 within-run pairs
per case; it does not pair observations across runs or override disagreements.

`qualification.zip` is the exact downloaded GitHub Actions artifact. In addition
to the readable copies, it contains every command and output, calibration
records, the staged production/source declarations, and runner snapshots. The
workflow excludes compiler caches and `.build` directories. Executable hashes
are recorded; compiled binaries are not archived.

The uninstrumented timing cohorts each contain 18 cases × 6 pairs × 2 variants =
216 observations, for 648 timing observations across the three cohorts. Linux
allocation instrumentation is a separate
18 × 2 × 2 = 72-observation cohort. Its elapsed times are not used for timing
claims. Four test configurations report nine passed test functions per cohort,
for 108 reported test executions across 12 configurations. These are repeated
executions of the same nine functions; the first is parameterized over three
whitespace queries.

The separate [native application validation receipt](native-validation/receipt.json)
and [compressed complete job log](native-validation/native-lifecycle.log.gz)
record the full app build and root-package release test run, including the new
search tests. This is additional evidence from the existing restoration
workflow, beyond the isolated component harness. The receipt reports the
passing aggregates and distinguishes optional skipped or unconfigured native
fixture and long-playback checks.

The archive hashes are verified against GitHub's artifact digests before
extraction. To inspect the full Linux record locally:

```sh
python3 -m zipfile -e \
  Benchmarks/SourceBrowserSearch/evidence/linux/qualification.zip \
  /tmp/source-search-linux-evidence
```

The allocation meter counts successful intercepted glibc `malloc`, `calloc`,
and `realloc` requests and requested bytes. It does not measure live or peak
memory, RSS, GPU memory, every allocator API, or macOS allocation behavior.

Initial local results lost during a transient workspace reset and superseded
CI runs canceled while workflow/receipt fixes were published are excluded.
The report's results are computed exclusively from the retained completed
cohorts. No timing observations were removed as outliers.
