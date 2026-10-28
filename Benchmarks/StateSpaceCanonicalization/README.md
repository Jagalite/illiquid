# State-space pre-transition canonicalization

This experiment measures the complete release-build PR seed inventory through
the IlliquidStateSpaceExplorer CLI. It compares the pinned main
commit with the current worktree. The candidate defers the pre-transition key
until a stale transition actually needs it.

On macOS or Linux with Swift 6.1 or later and Python 3:

```sh
python3 Benchmarks/StateSpaceCanonicalization/run.py \
  --pairs 4 --output /tmp/illiquid-state-space-key-results
```

Use a new output directory. When Kyoto is available, submit the entire command
through the shared queue and inspect its show/logs/wait results as required by
AGENTS.md. On isolated CI where Kyoto is unavailable, builds run serially in
separate baseline and candidate scratch packages.

The runner copies byte-identical production source files into dependency-free
Swift packages: the playback core's actual MediaTrack dependency and all playback
core and state-space sources. The CLI is byte-identical on macOS. On Linux only
its Darwin import is adapted to Glibc and stderr logging uses Foundation; that exact
transformation and both file hashes are recorded. There are no model stubs.
Both variants use the same current tests and parity driver.

Validation includes debug and release core/state-space tests on both variants,
18 small searches across all six models with POR off/on/validation, complete
graph and predecessor hashes, ordered state-key hashes, and three injected
failure artifacts with minimization and replay. Python hashes exact serialized
Swift receipts outside the timing interval. The full timing runs compare
every summary, progress report, inventory entry, and canonical digest exactly.

Primary measurements use four balanced AB/BA pairs of fresh, serial processes
after an excluded warm-up of both executables. Compilation, tests and parity
checks are outside the timing interval. Child wall time includes process
startup, full search, progress analysis, summary writes and teardown. CPU time
comes from child resource usage. No timing threshold is a correctness gate.

The production PR profile's state/edge/depth caps and 60-second per-seed time
limit are unchanged. Every timed run must complete within all bounds; a
time-capped run is rejected rather than compared to a more complete search.
The shallow parity driver disables the wall-clock limit on both sides.

The review directory retains source/binary hashes, all commands and logs, raw
timings, complete per-run qualification records, a canonical output record,
parity receipts and summary statistics. Platform results apply to the recorded toolchain and host. Native playback,
rendering, memory, power use and wall-clock-limited nightly search coverage are outside this
experiment's claims. The source change is confined to the qualification tool.
