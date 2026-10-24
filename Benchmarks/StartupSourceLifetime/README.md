# Startup source snapshot lifetime

This native macOS experiment isolates source data retained by the application's
startup loader after its published model closes a restored tab. The baseline is
`4abf4b44f13386ccd04f1ce4ad0e756255ca4d14`; the candidate is the current working
tree. It measures a staged source-owning component, not the complete player.

```sh
python3 Benchmarks/StartupSourceLifetime/run.py \
  --output /tmp/illiquid-startup-source-results --pairs 8
```

The output directory must be new or empty. The run needs macOS, Swift 6.1 or
later, and the baseline Git object. It has no external package dependencies and
downloads nothing. Follow `AGENTS.md`: when the shared Kyoto queue is available,
submit the command through that queue. Hosted qualification records the absence
of Kyoto before compiling isolated benchmark packages directly. The two builds
are serialized and use independent package build directories.

## Production code under measurement

Both release executables use the same `Owner.swift.in` and `Stubs.swift`. The
runner inserts these exact, unmodified excerpts from each revision's
`AppModel.swift`:

- Static startup declarations, including `StartupResources`, the history/source
  read factory, and the complete `loadShared()` method.
- The source-tab properties and their invalidation call.
- The complete `closeSourceTab(_:)` method.
- `SourceFolderLibrary`, `SourceTabItem`, `SourceTab`, and the related source
  serialization, normalization, selection, and visibility declarations.

The complete production `ReadOnlyStartupLoader.swift`,
`SourceStartupSnapshot.swift`, and `NormalizedFileURL.swift` files are compiled.
Candidate publication therefore executes the real new shared-loader helper.
The baseline executes the actual earlier `AppModel.loadShared()` body, not a
second handwritten implementation of that behavior. Exact source and excerpt
hashes, extraction boundaries, generated packages, compiler commands, and binary
hashes are recorded. Source types, property declarations, close semantics, and
snapshot/path decoding dependencies must remain identical between variants.

The small owner initializer stores `sources.tabs` and `sources.selectedID`, as
the application does. Playback/session objects, timing instrumentation,
preference persistence, and source-root indexing have inert dependencies. The
actual player graph, filesystem watches, asynchronous source index, native
playback, and UI are outside the experiment. In the real app an old source index
or in-flight indexing task may temporarily retain source strings after removal;
this test does not claim immediate whole-app release or visible UI latency.
The player continues to own its persistence store in both variants, so these
measurements are not a reduction in playback-history storage.

## Workloads and lifetime controls

The fixture preferences object supplies one tab containing 0, 100, 10,000, or
100,000 synthetic unique long ASCII file paths. It builds serialized input only
when the real source snapshot reader requests it. It stores no input arrays or
JSON payload afterward and reads/writes no production preferences. Its fresh
named `UserDefaults` suite is never seeded, cleared, or written by the probe.
The paths do not need to exist: production normalization is lexical.

Each size has two modes: closing the restored tab through the exact production
method, and leaving it unchanged. Every observation is a new process. Eight
alternating AB/BA pairs, with rotated cohort order, produce 128 observations.
At least six even pairs are required; no observations are removed.

The probe records four memory stages:

1. Before startup.
2. After the shared model is published and its startup async frame has returned.
3. After closing the source tab, or after the unchanged control.
4. After a benchmark-only diagnostic call to the real loader's `stop()`.

The fourth stage is an attribution control. The old loader should release its
cached snapshot there; the candidate already retired that ownership at
publication. The control that leaves the tab open should continue to retain
the model's live source data in both variants. Diagnostic stop must not change
the live model or prevent a subsequent singleton lookup.

Memory samples explicitly keep the published model alive. Source receipts
contain only scalars and the short selected tab ID, never item arrays, views, or
long path strings. Every observation verifies the ordered path checksum, byte
count, item count, tab selection, singleton identity, and exactly one source
read against an independent Python fixture oracle.

## Metrics and interpretation

**Live malloc bytes** use `malloc_zone_statistics(NULL).size_in_use` across the
process's malloc zones. This includes the staged owner's runtime and other live
allocations, not only path payload bytes. Raw values and within-process changes
are retained. Current resident bytes and physical footprint use Mach
`TASK_VM_INFO`; peak RSS uses `getrusage`. Those metrics have different meanings,
and released allocation bytes do not imply that the OS immediately reclaims the
same number of resident pages.

The primary result is memory after the source action. The unchanged-source and
zero-item cases establish control behavior. Large libraries and long paths are
scaling stress cases; their results are not a typical whole-player memory
percentage, startup peak reduction, or allocation-traffic claim.

Wall and process CPU times for startup, close, and diagnostic retirement are
also retained. Closing now may pay the cost of destroying source arrays and
strings that the baseline deferred until shutdown. This is a real ownership
tradeoff; report the observed close cost alongside memory savings. The staged
holder excludes the real source index's temporary ownership, so its close time
does not establish a UI hitch. Unchanged-mode action timing is clock overhead
and is excluded from comparative summaries. Short timings can be noisy; no
timing threshold gates CI.

`observations.jsonl` retains all raw measurements and semantic receipts.
`summary.json` contains medians, ranges, every paired difference, and the number
of lower candidate samples. `oracle.json`, `manifest.json`, logs, exact source
snapshots, and generated package source hashes make the run reviewable. The
runner rejects source or harness changes before publishing a completed result.
