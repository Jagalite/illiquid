# Native operation work lifetime

This experiment investigates retained Swift `Task` handles after native playback
operations are superseded. It compares the runtime at commit
`4abf4b44f13386ccd04f1ce4ad0e756255ca4d14` with the current working-tree source.
The Linux component investigation passed. Native macOS qualification remains
pending as of 2026-10-24; the platform regression tests below are not claimed as
executed. The measured candidate runtime matches published commit
`49c42e9c143b9feb6c0210efb1884f487d61b666` by source hash.

## Measured results

The complete run used Swift 6.3.2 on Linux x86_64 with glibc 2.39. It collected
144 observations: four workloads, three history sizes, six matched pairs per
workload/size, and two variants. Each observation used a fresh process; three
pairs ran baseline first and three ran candidate first. Every pair preserved
terminal-result counts and digests. All six qualification scenarios passed for
each variant.

After a burst of superseded presentation operations, **every candidate sample
retained zero completed task handles**. The table reports medians of the
allocator-reported increase over the warmed pre-workload state, in bytes:

| Operations | Completed handles before | Completed handles after | Allocator increase before | Allocator increase after |
| ---: | ---: | ---: | ---: | ---: |
| 32 | 31 | 0 | 56,440 | 17,424 |
| 4,096 | 4,095 | 0 | 5,730,776 | 100,304 |
| 32,768 | 32,767 | 0 | 45,193,008 | 100,528 |

At 32,768 supersessions this is about 43.10 MiB versus 0.096 MiB. All six matched
pairs had lower retained allocator usage; the median **paired** reduction was
45,092,448 bytes. All 32,768 callback-capture lifetime probes had already been
destroyed in both variants before sampling. Clearing the settled registry
reclaimed a median 45,091,648 bytes in the baseline and zero in the candidate,
supporting attribution to retained handles and registry storage rather than
still-running callbacks.

The physical-stop control retained all 32,768 pending handles in both variants
until its gate was released. After those waits finished, the baseline retained
32,767 completed handles and the candidate retained zero. Median allocator
increases were 45,408,904 and 1,426,904 bytes respectively. The candidate still
retained empty dictionary capacity after this deliberately large simultaneous
pending-work peak: clearing its registry reclaimed a median 1,060,864 bytes.
The fix releases completed handles; it does not force dictionary capacity to
shrink after every legitimate pending-work burst.

Ordinary completion and explicit-cancellation controls retained zero completed
handles in both variants at every size. Their allocator differences were small
and variable; no improvement is claimed for those controls. Synthetic CPU/wall
timings are preserved in the raw observations but do not support a player
throughput claim.

The canceled-sleep qualification performed 300 polls in the baseline and one in
the candidate. The reentrant-cancellation case left two orphan task handles and
one stale deadline in the baseline, versus zero of either in the candidate,
while preserving one success and two cancellation results.

Evidence: [raw observations](evidence/linux/observations.jsonl),
[summary and ranges](evidence/linux/summary.json),
[qualification cases](evidence/linux/qualification.json),
[source/compiler/build manifest](evidence/linux/manifest.json),
[command receipts](evidence/linux/commands.json), and
[independent audit](evidence/linux/audit.json). The audit recomputed all summary
metrics and checked exact source, compiled-input, harness, and binary hashes.
The candidate runtime SHA-256 is
`7477ad521faedf4830f858f65b741832effc7f2513e72c67013a4d228e1b5eca`.

An earlier sandboxed attempt crashed before collecting any performance sample.
The complete failed attempt and unchanged-binary diagnostic reruns are retained
in [environment diagnostics](evidence/environment-diagnostics/README.md).
The final run through the approved execution path had no failed or omitted
observations. The precise environment failure remains unproven; it did not
require changing the measured code.

## Defect and ownership

[`NativePlaybackRuntime`](../../Sources/IlliquidNativePlayback/Production/NativePlaybackRuntime.swift)
stores asynchronous operation work in `operationWorkTasks`, keyed by effect ID.
Beginning a newer operation removes the older logical transaction from
`NativeOperationLedger`, but previously canceled only its deadline. The older
work task remained in the dictionary. When it completed,
`finishOperation(effectID:)` returned immediately because the transaction was
absent, leaving the completed task handle retained until runtime shutdown.
Repeated supersession therefore accumulated handles even after all work had
finished.

The presentation flush poller also ignored cancellation: `try?` swallowed its
sleep error, allowing a canceled task to continue polling and potentially run an
obsolete `onSuccess` callback. Terminal-result rejection in the ledger happens
after that callback and cannot prevent its side effects.

## Change

Supersession now cancels and removes obsolete operation work. Completion removes
work and deadline handles before consulting the logical ledger, so a late
completion can release ownership without producing a second terminal result.
Flush polling returns on cancellation, and external subtitle preparation checks
cancellation before installing its result.

**Physical session shutdown is an explicit exception.** A `.sessionCancellation`
task may be the only remaining owner of an old session's worker shutdown wait.
Supersession keeps that task in the runtime's shutdown inventory until the wait
finishes. Its late completion then removes the handle even though its logical
transaction is gone. Verified worker-release accounting happens before the
cancellation guard, including when runtime shutdown cancels and awaits the task.

Result delivery is synchronous and can dispatch another operation before the
outer `beginOperation` returns. Active-transaction guards prevent the outer,
already-superseded operation from registering another deadline or work task.
The flush/recovery call sites also check before changing the presentation fence,
so an obsolete outer effect cannot invalidate the newer effect's fence.

## Portable experiment

[`run.py`](run.py) builds two isolated release executables. Each uses the complete
production operation ledger and playback-core types, plus verbatim runtime
methods for beginning, correlating, finishing, canceling, and polling operation
work. Source snapshots, fragment hashes, compiler information, commands, and
binary hashes are retained in the output directory.

The surrounding laboratory dependencies are explicit: a Boolean presentation
completion probe, a physical-stop continuation gate, bounded effect-result
counters/digests, and deadline registration using the production admission
prefix. The native renderer and session are not instantiated by this executable.

Four measured workloads distinguish supersession from ordinary cleanup:

| Workload | Behavior |
| --- | --- |
| `supersede` | Start a burst of same-kind flush operations before their tasks run. |
| `complete` | Allow each operation to complete before starting the next. |
| `cancel` | Explicitly cancel each operation. |
| `physicalStop` | Supersede stop operations while their physical waits remain blocked, then release all waits. |

Qualification also checks cancellation during sleep, obsolete success callbacks,
late completion, and synchronous result reentry. The two variants must preserve
terminal-result counts and digests for the measured workloads.

Each sample runs in a fresh process after a small completion warm-up. The harness
waits for every callback-capture lifetime probe to be destroyed, then allows a
common quiet interval before measuring. It keeps no additional array of task
handles. It records the settled registry count and allocator live bytes with the
registry alive, then clears the research registry and measures again. macOS uses
`malloc_zone_statistics(NULL).size_in_use`; supported glibc systems use
`mallinfo2.uordblks + mallinfo2.hblkhd`. Variant order alternates between pairs.

## Reproduce

Run from the repository root with a Swift 6 toolchain supported by this checkout
and the pinned baseline commit available locally. Use an empty output directory.
Submit build commands through Kyoto when available, following
[`AGENTS.md`](../../AGENTS.md); the script uses isolated build and module-cache
directories.

```sh
python3 Benchmarks/NativeOperationWorkLifetime/run.py \
  --output /tmp/illiquid-operation-work \
  --pairs 6 --cycles 32,4096,32768
```

Use `--swift /absolute/path/to/swift` to select a toolchain, or `--tests-only` to
build both variants and run the qualification checks without the measurement
matrix. `--pairs` must be even and at least two. Outputs include `manifest.json`,
`commands.json`, `qualification.json`, `observations.jsonl`, `summary.json`, and
build/qualification logs. Source and harness snapshots are saved in `sources/`
and `harness/`; the staged packages remain in `baseline/` and `candidate/`. The
observation file is absent with `--tests-only`.

## Native integration

[`NativeOperationWorkLifetimeTests`](../../Tests/IlliquidNativePlaybackTests/NativeOperationWorkLifetimeTests.swift)
exercises the real runtime:

- A synchronous burst of 64 flushes retains only the newest work/deadline, produces
  one cancellation per superseded effect, and releases all handles after success.
- A cancellation callback synchronously submits a third effect while the second
  is being admitted; only the third effect may retain work and complete its fence.
- Two stop effects execute without suspension after loading a real media fixture.
  The first physical wait stays tracked after logical supersession. Both natural
  completion and immediate runtime shutdown must release all runtime leases
  without duplicate terminal results.

On a macOS native SDK checkout, run:

```sh
ILLIQUID_NATIVE_FIXTURE_DIR=/absolute/path/to/fixtures \
swift test --force-resolved-versions -c release --jobs 2 --no-parallel \
  --filter NativeOperationWorkLifetimeTests
```

The stop cases require `multiple-audio-flags.mkv`. They return when the fixture
environment variable is absent and fail if it is configured but the file is
missing. The dedicated
[`native-operation-work-lifetime.yml`](../../.github/workflows/native-operation-work-lifetime.yml)
workflow generates that fixture and additionally runs the existing authority,
lease-history, replacement/stop, and replacement/shutdown checks.

## Scope and interpretation

The memory claim is about completed task handles and their registry storage.
Completed handles do not establish that media payloads or callback captures remain
alive. Allocator deltas include Swift scheduler/runtime allocations and allocator
variation; the settled handle count and registry-clear comparison help identify
the retained ownership. These values are not RSS or whole-player memory savings.

Synthetic workload wall/CPU times include actor scheduling and the quiet interval;
they are not playback throughput, frame timing, or UI responsiveness. The
physical-stop gate validates task custody around the extracted methods; the native
fixture tests qualify real worker release. The change does not impose a cap on
legitimately pending physical shutdown waits or redesign all runtime reentrancy
behavior. It addresses operation work lifetime and the associated flush/subtitle
callbacks.
