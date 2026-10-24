# Filesystem event buffer memory experiment

This compares the sidebar's original pending-event array with the actual
`SourceFilesystemEventBuffer` while a simulated debounce remains pending. It
measures retained allocator-accounted bytes after temporary input batches leave
scope. It does not run FSEvents, the main actor, or the app, and makes no claim
about process RSS, physical footprint, playback memory, or peak process memory.

Run from a checkout containing the pinned baseline commit:

```sh
python3 Benchmarks/FilesystemEventBuffer/run.py --output /tmp/filesystem-buffer --pairs 4
```

Use `--swift /path/to/swift` to select a toolchain. The script also works on macOS
with the selected Xcode toolchain. `--pairs` must be even: each workload uses the
same number of baseline/candidate and candidate/baseline pairs, each observation
in a fresh process. All compilation uses Swift 6 mode, `-O`, and warnings as
errors. The runner copies the full unchanged production invalidation source for
each variant. It extracts and validates the old sidebar's array declaration,
append, and drain statements from Git; only the SwiftUI `@State` wrapper is
omitted. The candidate directly aliases the production buffer. No platform
types or planner behavior are stubbed.

The inputs contain unique paths of 96–160 UTF-8 bytes, delivered in batches of
128. Workloads include ordinary bursts, the 4,096-event boundary, one event over
the boundary, sustained 100,000/1,000,000 events, and an explicit event-loss marker.
Only the accumulator's retained contents remain at the heap sample; path-byte
summation and recovery-plan assertions run afterward. The peak event count is
sampled after each append and excludes the temporary callback batch.

The allocator helper is copied from
`Benchmarks/RuntimeLeaseHistory/CLeaseHeap`: Linux uses
`mallinfo2().uordblks + mallinfo2().hblkhd`; macOS uses
`malloc_zone_statistics(NULL).size_in_use`. The reported delta subtracts the
same process's warmed, pre-input reading. Allocator overhead and caches can
contribute to these values, so exact retained event/path counts are also kept.
The elapsed time includes path generation and is recorded only as experiment
context, not as an application CPU claim.

Before measuring, both executables verify exact event contents, flags, arrival
order, and planner results for ten below-capacity cases, plus equivalent plans
for explicit event loss. Candidate-only checks cover overflow, oversized input,
bounded retention, draining, and reset followed by ordinary events. Every
measured candidate overflow must produce one event whose plan rescans all roots.

`OUTPUT/evidence/` contains source and executable hashes, copied tested sources,
compiler/host metadata, extracted baseline statements, command/build logs, a
compressed parity trace, all raw observations, and `summary.json`. Generated
compiler products and module caches stay outside that evidence directory.

The component does not represent FSEvents callback arrays or tasks waiting to
reach the main actor. One million events is a compressed stress workload, not
an observed frequency or duration of real filesystem activity. Coalescing an
overflow deliberately exchanges targeted event detail for the existing
conservative all-root rescan behavior.
