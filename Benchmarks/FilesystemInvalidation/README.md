# Filesystem event planning

This experiment compares the complete production
`SourceFilesystemInvalidationPlanner.plan(events:roots:)` implementation with
the version at `7f9ba073394b77a908e0589447c6edc8d10b832c`.

## Why this work matters

`SourcesSidebar.enqueueFilesystemEvents` collects filesystem notifications and
debounces them for 150 ms. Its main-actor task then calls the planner
synchronously before invalidating caches and scheduling directory reloads.
Large notification batches therefore add work to the main actor even when the
events do not require a refresh.

The baseline already creates a normalized URL for each event, but discards that
URL after extracting its path. It constructs another URL from the path to test
whether the event names `.plexmatch` or an NFO file. This second initializer has
no directory hint. Apple's
[URL initializer documentation](https://developer.apple.com/documentation/foundation/url/init(fileurlwithpath:isdirectory:))
explains that the explicit directory-hint variant avoids filesystem I/O used to
infer whether a path is a directory.

The candidate reuses the first normalized URL. It also short-circuits metadata
classification for structural events, whose flags already require a refresh,
and evaluates the full-rescan flag once per event. Root matching, parent-path
construction, refresh policy, event-loss handling, and final pruning stay the
same. The experiment does not add a persistent cache.

## Reproduce

From a checkout containing the baseline commit and a Swift 6.1+ toolchain:

```sh
python3 Benchmarks/FilesystemInvalidation/run.py \
  --output /tmp/illiquid-filesystem-planning-results \
  --pairs 8 --target-ms 100
```

Use a new output directory for each run. `--swiftc` selects a compiler;
`--tests-only` omits timing; `--cases` selects comma-separated workload names.
The Git baseline can be overridden explicitly with `--baseline`.

The macOS workflow uses the repository's pinned Xcode selection on `macos-26`.
The portable harness also runs on Linux. Platform results are kept separate;
Linux Foundation timings do not establish macOS performance.

## Correctness and measurement

The runner compiles the complete old and new production files unchanged, in
debug and optimized release configurations. It compares all members of all
three output sets for 60,947 deterministic plans per configuration, including:

- Every combination of the eight event flags across root/path combinations.
- Empty, relative, Unicode, percent-literal, dot-segment, and trailing-separator
  paths; filesystem root and overlapping source roots.
- Mixed batches in both event orders, global event loss, and local rescans.
- Existing directories named `.plexmatch` and `Series.nfo`, plus every measured
  workload's output.

The monitor, event-loss, root-boundary, and additional path-semantics test
suites run against both implementations in debug and release. These are
isolated packages containing unchanged production and test sources, not a
full player build.

Nineteen workloads include individual notifications, 256- and 4,096-event
batches, one or 32 watched roots, content-only writes, sidecar writes,
directory changes, overlapping roots, and unaffected controls. Four workloads
use existing temporary files or directories. Fixture creation and input-array
construction are outside the timed interval. The synthetic-path workloads do
not create their media paths; the baseline's URL initializer may still query
the filesystem.

Each measurement includes one complete planning call per iteration, including
normalization of the root list. The harness performs two warmup calls, then
records monotonic elapsed time and process CPU time. It consumes the three
result counts each iteration and checks the complete final plan outside the
timed interval. Both implementations use the same calibrated iteration count.
Fresh processes alternate baseline/candidate and candidate/baseline order;
no timing outliers are discarded. Summaries report the median ratio within
matched pairs, absolute median time per plan, ranges, and the number of pairs
favoring the candidate.

Raw receipts include compiler/platform details, exact source and executable
hashes, compiler/test commands and logs, a compressed complete reference
trace, calibration measurements, every timing sample, and the summary.

## Scope

The measured operation is event planning. The experiment excludes FSEvents
delivery, the 150 ms debounce, directory enumeration, downstream cache
invalidation, SwiftUI rendering, media decoding, and playback. It does not
measure end-to-end UI latency, physical-Mac energy consumption, or cold/network
filesystem behavior. Existing-file measurements run after warmup on a local
filesystem.

See `RESULTS.md` for measured outcomes and evidence locations.
