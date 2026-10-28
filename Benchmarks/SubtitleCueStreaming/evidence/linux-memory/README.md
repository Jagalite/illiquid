# Subtitle conversion: qualifying peak-memory measurements

## Scope and status

This is a follow-up to [PR #213](https://github.com/Jagalite/illiquid/pull/213),
which streams subtitle cue lines and appends their escaped payloads directly to
ASS output. This follow-up changes the measurement harness, regression tests,
and research evidence; it does not change the production converter.

The fresh qualification run is
[GitHub Actions run 40734627916](https://github.com/Jagalite/illiquid/actions/runs/40734627916),
using code commit
[`1de4df35187b9e7483d40dd5731158ea0f79b2fc`](https://github.com/Jagalite/illiquid/commit/1de4df35187b9e7483d40dd5731158ea0f79b2fc).
The comparison baseline remains
[`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`](https://github.com/Jagalite/illiquid/commit/ea2ff568237e2667f7b1aeee67b11a44ebe95b72).
**Linux component qualification and the independent audit passed.** The
[macOS job](https://github.com/Jagalite/illiquid/actions/runs/40734628101) remains
queued; native qualification is pending. The [original report](../../README.md)
retains the earlier experiment as a historical record.

## Why the earlier memory measurement was inconclusive

All sixteen original observations reported the same 63,057,920-byte peak
(60.14 MiB) before constructing the fixture, before conversion, and after
conversion. That floor concealed any smaller process peak and established
neither a memory saving nor memory non-regression. The original
[memory receipts](../linux/memory.jsonl) retain those observations.

On Linux, `getrusage(RUSAGE_SELF).ru_maxrss` reports the process's maximum resident
set size in KiB, and resource-usage history survives `execve`.
The [Linux getrusage manual](https://man7.org/linux/man-pages/man2/getrusage.2.html)
documents both properties. Replacing a memory-heavy measurement launcher with
the benchmark executable therefore does not necessarily remove its old peak.
The runner also retains complete verification traces, which can make that
launcher substantially larger than a small conversion workload.

The local [launcher regression test](../../test_memory_launcher.py) reproduced this
contamination: a parent holding touched memory raised the direct child's RSS
floor, while the new launch path removed that floor. CI reruns this probe and
records its observations. This diagnoses the launch path; it does not by itself
establish a memory improvement in the converter.

## Measurement changes

[fresh_process.py](../../fresh_process.py) runs in a fresh, isolated Python interpreter
(`-I`), explicitly forks, and then executes one benchmark command in the child.
Replacing the original interpreter first discards its large resident allocations.
Forking from the small interpreter then starts a new resource-usage history;
the [Linux fork manual](https://man7.org/linux/man-pages/man2/fork.2.html) describes
the reset of the child's resource-use counters. The final executable can still
inherit a small launch floor, so this is a whole-process measurement rather than
a zero-based heap counter. The helper forwards standard output, standard error,
and the child's exit status; its regression test also checks failure propagation.

Each memory process constructs one fixture, performs exactly one conversion with
no warmup, and records three high-water marks:

1. Before fixture construction.
2. After fixture construction, immediately before conversion.
3. After conversion, with both source and returned ASS output retained through
   `withExtendedLifetime`.

Fixture hashing, output metadata traversal, independent expected-output
construction, and validation occur after the final RSS sample. The large inputs
are built into reserved buffers in small pieces to limit construction temporaries.
The runner retains all three marks and their difference; the difference between
two high-water marks is not a live allocation or retained-heap measurement.

## Workloads and comparison

The twelve memory workloads separate ordinary subtitle imports from synthetic
stress inputs. Each has an independently constructed expected ASS result and cue
count, checked with exact UTF-8 comparison after sampling.

| Workload family | Formats | Purpose |
| --- | --- | --- |
| 128 ordinary cues | SRT, WebVTT | Small existing controls |
| 2,000 two-line ordinary cues | SRT, WebVTT | Larger ordinary controls |
| One cue with 65,536 payload lines | SRT, WebVTT | Approximately 1.06 MiB multiline stress |
| One cue with 262,144 payload lines | SRT, WebVTT | Approximately 4.25 MiB multiline stress |
| Ignored NOTE with 65,536 or 262,144 lines | WebVTT | Cost of discarding a large comment block |
| One four-MiB payload line | SRT, WebVTT | Large-string control without many line boundaries |

Each workload uses eight adjacent baseline/candidate pairs in separate processes,
alternating AB and BA order: four pairs in each order, 192 memory observations in
total. Baseline and candidate are optimized builds of their complete production
converter sources with the same driver. The retained results show raw observations,
per-variant medians and ranges, and the median of each pair's percentage change
`100 * (candidate / baseline - 1)`. Negative values mean a smaller candidate peak.

The eight existing timing workloads and their fixture construction remain
unchanged. Their fresh timing run is a control, not evidence that changing the
memory launcher accelerates production code.

## Correctness qualification

All **274 complete input/output/error records** matched across baseline and
candidate debug and release builds: 134 successful conversions and 140 typed
errors. Every memory workload is included. The independent Python audit
reconstructed all twelve memory inputs, exact ASS outputs, and cue counts, and
verified fixture identity, input/output lengths, consumed output tokens,
conversion counts, and watermark consistency.

All **47 Swift tests passed in each of four configurations** (baseline/candidate,
debug/release), for **188 test executions**. Two added tests cover 4,096 escaped
Unicode payload lines with a final empty field, and 4,096-line NOTE blocks
followed by a retained cue. Both launcher regression tests passed as well.

## Fresh results

The successful cohort ran on **GitHub Actions Ubuntu 24.04, x86_64 AMD EPYC
9V45, four logical CPUs, Swift 6.4.1, and glibc 2.39**. Both release variants used
`-O -whole-module-optimization`. Each row below contains eight balanced pairs;
all 192 observations are retained without exclusions. MiB means 1,048,576 bytes.

| Workload | Baseline median MiB | Candidate median MiB | Median paired change | Paired range |
| --- | ---: | ---: | ---: | ---: |
| SRT, 128 ordinary cues | 18.166 | 18.053 | -0.45% | -1.37% to -0.06% |
| WebVTT, 128 ordinary cues | 18.229 | 18.277 | -0.08% | -1.04% to +1.34% |
| SRT, 2,000 two-line cues | 18.758 | 18.707 | -0.40% | -1.31% to +0.62% |
| WebVTT, 2,000 two-line cues | 18.859 | 18.756 | -0.50% | -1.42% to +0.02% |
| SRT, 65,536 payload lines | 27.461 | 20.428 | -25.53% | -26.24% to -25.26% |
| WebVTT, 65,536 payload lines | 27.586 | 20.574 | -25.53% | -25.74% to -24.78% |
| SRT, 262,144 payload lines | 56.088 | 27.197 | -51.48% | -51.76% to -51.28% |
| WebVTT, 262,144 payload lines | 56.174 | 27.209 | -51.59% | -51.76% to -51.47% |
| WebVTT NOTE, 65,536 lines | 19.420 | 19.270 | -0.87% | -1.33% to -0.40% |
| WebVTT NOTE, 262,144 lines | 28.768 | 22.369 | -22.18% | -22.69% to -21.83% |
| SRT, one 4 MiB payload line | 30.113 | 30.047 | -0.14% | -0.67% to +0.23% |
| WebVTT, one 4 MiB payload line | 30.176 | 30.066 | -0.43% | -0.50% to -0.03% |

The four dense-line cases and the 262,144-line NOTE favored the candidate in
**all eight pairs each**. The largest payload-line cases saved about 28.9 MiB
of process peak; the largest ignored comment saved about 6.4 MiB. These are
synthetic stress workloads. Ordinary subtitle files and four-MiB single lines
showed paired changes below approximately 0.5%, with adverse individual pairs
in several controls. The smaller NOTE changed by less than 1%. Those small
effects do not support a substantial memory-saving claim for these workloads.

The percentage column is the median of eight paired ratios, not the ratio of
the two separately computed medians. For example, the short WebVTT candidate has
a slightly higher separate median but a -0.08% median paired change; its pairs
split evenly in direction. The full ranges preserve that uncertainty.

The CI launcher probe retained 128 MiB in its parent. The direct child reported
146,223,104 bytes (139.45 MiB); the isolated child reported 10,301,440 bytes
(9.82 MiB). Actual Swift pre-fixture peaks ranged from **14.859 to 15.137 MiB**,
with 56 distinct values, and every conversion produced positive high-water
growth. The former uniform inherited floor is absent.

All **64 timing pairs** also favored the streaming candidate for elapsed and
CPU time. The shortest samples were 158.620 ms elapsed and 158.629 ms CPU.
For the existing 128-cue LF cases, median full-conversion elapsed time was
0.871 to 0.706 ms for SRT and 1.547 to 1.143 ms for WebVTT. These are controls
for the already-proposed production optimization. The launcher is outside the
timed loop, and this follow-up introduces no additional production speedup.
The earlier cohort used a different CPU/compiler; its absolute times must not
be compared with this cohort to infer a new optimization.

## Evidence and independent audit

The [independent audit](independent-audit.json) hashed all 402 retained artifact
files, checked all 371 command stdout/stderr receipts, verified source snapshots
and build flags, and independently recomputed all timing and RSS summaries.
It also checked the isolated test-package sources and manifests. Executable
binaries were not included in the artifact: their runner-recorded digests are
retained, but their hashes could not be independently recomputed.

- [Raw memory observations](memory.jsonl) and [memory summary](memory-summary.json)
- [Raw timing observations](measurements.jsonl) and [timing summary](summary.json)
- [Parity](parity.json), [Swift tests](tests.json), and [launcher tests](launcher-tests.log)
- [Compiler/source provenance](provenance.json) and [completion receipt](completion.json)
- [Normalized command receipts](commands.json) and [publication inventory](publication.json)
- [Independent audit program](audit.py)

The [CI run](https://github.com/Jagalite/illiquid/actions/runs/40734627916) retains
the complete artifact, including full differential traces and command/test logs,
until **2026-11-11**. Its archive SHA-256 is
`83bdf54cdd19ef47c211d45fbee352de5902210daa857bd20962e7472561da5a`.
The compact numerical receipts and per-case hashes remain committed here.
Machine-specific command paths use `<REPO>`, `<OUTPUT>`, and `<PYTHON>`;
provenance omits detailed kernel and hardware flags. Numerical observations,
source hashes, and original stdout/stderr hashes are unchanged. The inventory
records original and published hashes; the audit's file hashes refer to the
original artifact before these publication transformations.

To audit the unpacked artifact or a fresh complete benchmark directory, set
`RSS_STUDY_OUTPUT` to that directory and `RSS_AUDIT_OUTPUT` to a new JSON file:

```sh
python3 Benchmarks/SubtitleCueStreaming/evidence/linux-memory/audit.py \
  "$RSS_STUDY_OUTPUT" --output "$RSS_AUDIT_OUTPUT"
```

The audit is pinned to this production comparison and its 47-test suite. For a
changed converter or test matrix, update its expectations explicitly.


## Reproduction and limits

Set `RSS_STUDY_OUTPUT` to a new output directory. Follow the repository's
[build-coordination instructions](../../../../AGENTS.md): if Kyoto is available, set
`KYOTO_SCRIPT` to its location and submit the entire serial workflow through it:

```sh
python3 "$KYOTO_SCRIPT" submit -- env ILLIQUID_CUE_STREAMING_QUEUED=1 \
  python3 Benchmarks/SubtitleCueStreaming/run.py \
  --pairs 8 --target-ms 150 --output "$RSS_STUDY_OUTPUT"
```

On a host where Kyoto is unavailable, the runner explains that limitation and
uses isolated build directories with compilation serialized:

```sh
python3 Benchmarks/SubtitleCueStreaming/run.py \
  --pairs 8 --target-ms 150 --output "$RSS_STUDY_OUTPUT"
```

The output includes source snapshots, commands and logs, full parity traces,
launcher-probe results, individual measurements, and summaries. Inspect the
completion receipt and executed test results before treating a run as qualified.

RSS includes runtime, shared-library mappings, retained input and output, and
conversion temporaries. Small workloads may remain below an existing high-water
mark. Results do not isolate heap allocations, prove a leak fix, establish
steady-state player RAM, or quantify the frequency of stress inputs in real use.
The parent retains large full-output traces, and launch isolation does not remove
general host load, cache effects, or scheduling noise. Linux component results do
not establish macOS behavior. Disk I/O, decoding,
libass rendering, live playback, frame rate, and UI response remain outside this
experiment.
