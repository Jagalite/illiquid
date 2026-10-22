# Media section grouping

This study compares complete cached source-browser projections against main
`a2de305c8dbcaa81aac1477df7c9a0017c14eae3`. The proposed change caches section-title
case folding within one `organizeMedia` call. It retains the first encountered
spelling as the canonical title and all existing section/member ordering.

The cache is local to one projection. It cannot retain a title chosen by an
earlier search or visibility state, and its extra storage grows with distinct
section spellings rather than reserving space for every media row.

A cache hit requires identical UTF-8 bytes, in addition to the dictionary lookup.
Swift `String` equality treats canonical Unicode spellings as equal, while
Foundation case folding can distinguish their original combining-mark order.
The new regression suite exercises a three-title Greek example against the
original grouping algorithm. Removing only the UTF-8 guard makes that test fail
on the qualified Linux toolchain. Canonically equivalent but byte-distinct titles
may replace the same cache slot and be folded again; that preserves existing
behavior rather than promising one fold per Unicode-equivalent title.

## Reproduce

With Swift 6.1 or newer and Python 3:

```sh
python3 Benchmarks/MediaSectionGrouping/run.py --output /tmp/media-sections-study
```

The default runs baseline/candidate contract tests in debug and release, verifies
complete projection outputs, and measures six balanced fresh-process AB/BA pairs
for every workload at 100, 1,000 and 10,000 files. Each output directory must be
new or empty. `--swift /path/to/swift` selects a toolchain; `--mode tests`,
`--mode verify` and `--mode benchmark` select individual stages. For a short
exploratory run use `--cases movies seasons --sizes 100 --pairs 2 --target-ms 10`.

This is a historical research harness. For the recorded comparison, use candidate
checkout `cf27b1e73cd2b1ecd5bfd8b9e5bb0fd273b42536`; the manual Actions workflow also
checks out that revision explicitly. It intentionally rejects unrelated changes
to production dependencies and requires baseline-equivalent output. Studying a
future implementation requires deliberate baseline/dependency review and new
evidence. The normal app test target includes the grouping regressions and is
covered by the repository's existing native release test workflow on pull requests.

## Sources and correctness

The staging helper in `Benchmarks/SourceTreeVisibility/run.py` supplies complete
production Filter/Projection and core source files, together with guarded,
verbatim model and loader declarations from AppModel/SourcesSidebar. There is no
replacement actor, grouping algorithm, row model, metadata model, or comparator.
The runner reads baseline files from the exact Git revision above, requires all
staged production dependencies other than `SourceBrowserFilter.swift` to match,
and records original and compiled source hashes.

Both variants run the complete existing `SourceBrowserFilterTests`,
`SourceBrowserSearchTests`, `SourceMediaOrganizationTests`, and new
`SourceMediaGroupingTests` files. Native macOS sources and tests are unchanged.
Linux records three portability adaptations: Darwin to Glibc for the sidecar
reader, the FoundationXML import, and an explicit directory hint for one existing
sidecar-test fixture root. These match the existing visibility harness.

Before timing, the runner compares complete serialized projections: every row
and metadata field, ordering, visibility, hidden count, regex counts, thumbnail
order, and media-path membership. Every timed process also checks its initial,
warmed, and final projection against that complete baseline trace outside the
measured interval. It verifies one tree build and one visibility build, expected
file counts, and unique row identities.

## Workloads

| Case | Purpose |
| --- | --- |
| `movies` | Many files sharing the Movies section. |
| `seasons` | Repeated episode sections, up to 50 distinct show/season groups. |
| `unicode_groups` | Repeated Unicode titles with case variants. |
| `unique_sections` | One episode per distinct show; a cache-entry overhead control. |
| `broad_search` | Search retains all episode files before grouping. |
| `narrow_search` | Search retains approximately one percent of files. |
| `files_control` | Files-only view; media grouping is not called. |
| `tree_control` | Tree view; media grouping is not called. |

Fixtures use deterministic shuffled synthetic local URLs. Actual filename
recognition populates every media entry before timing, as the normal metadata
loader does. All file sorts are disabled so prepared input order is deterministic;
semantic episode and section ordering remains part of the measured production
grouping path. Distinct timing-fixture sections avoid equal localized sort keys;
Unicode normalization and folding edge cases are tested separately. No filesystem
scan occurs in timing.

## Measurement boundary and evidence

The driver times a loop of awaited `SourceBrowserFilter.project(input:)` calls
after priming tree and visibility caches. The interval includes cached-input
checks, search, grouping, episode/section ordering, complete projection creation,
and minimal result consumption. It measures wall time with `DispatchTime` and
whole-process CPU time with `CLOCK_PROCESS_CPUTIME_ID`. Replacing the prior result
inside the loop is included; disposal of the final result is outside timing.
Fixtures, recognition, warmup, trace checks, JSON encoding, and process launch are
outside timing. These are component timings, not whole-player frame rate,
filesystem discovery, UI layout, energy, or allocation measurements.

One calibration observation per variant selects a shared iteration count
targeting 60 ms for the faster variant (capped at 65,536 iterations). Calibration
records are retained separately and excluded from the final summary. Final
observations alternate AB/BA within each workload/size, with a fresh process for
every observation and three warmup projections after cache priming. No final
observations are discarded; no timing threshold gates correctness.

Evidence includes `measurements.jsonl`, `calibration.jsonl`, `summary.json`, full
verification traces, per-command stdout/stderr, `tests.json`, source/build
manifests, compiler/host information, and exact driver/helper sources. Summary
percentages are medians of paired changes, rather than differences between the
independent variant medians. The unique-section and non-media controls must be
reported alongside repeated-section results.

## Results

[The complete research report](RESULTS.md) includes all initial native and
exploratory Linux cases, the longer native confirmation, adverse observations,
and retained raw receipts. The confirmation supports a scoped improvement for
repeated season groups and broad searches. It does not establish a uniform
speedup across views, queries, inventory shapes, or platforms.

## Integrated dependency baseline

Current-checkout runs use `6dc482129373da1c611b6e8cc7ea7906c381912c`, which adds the
flat-file, source-preparation and filesystem-root sidebar and sidecar changes to the original
baseline. This keeps the media-grouping change as the only staged production
difference and retains
the shared-source guards. Existing evidence and the manually dispatched
historical workflow retain their original revisions.
