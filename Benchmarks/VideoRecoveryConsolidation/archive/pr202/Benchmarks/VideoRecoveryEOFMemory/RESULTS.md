# EOF recovery-buffer memory: independent qualification

## Result

The generation-checked release in [PR #172](https://github.com/Jagalite/illiquid/pull/172)
releases the final compressed recovery GOP at the existing normal-return EOF boundary.
The exact guarded implementation passed the production-loop ownership experiment
in both debug and release builds against the repository's pinned FFmpeg 8.1.2.

| Synthetic workload | Payload | Baseline live backing bytes at EOS enqueue | Candidate live backing bytes at EOS enqueue |
| --- | ---: | ---: | ---: |
| Empty input | 0 | 0 | 0 |
| 4 packets, 256 KiB each | 1 MiB | 1,048,832 | 0 |
| 512 packets, 64 KiB each | 32 MiB | 33,587,200 | 0 |
| 4 packets, with one independently retained native buffer | 1 MiB | 1,048,832 | 262,208 |

These measurements were identical in both configurations and both fresh-process
pairs. In the independent-owner case, the remaining **262,208 bytes reached zero
when that consumer released its reference**. All tagged allocations were freed
exactly once after cleanup in every scenario.

The 512-packet workload reaches the recovery buffer's existing count and payload
limits. Its 33,587,200 backing bytes are 32 MiB of payload plus 32,768 bytes of
FFmpeg input padding. This is a controlled capacity case, not an estimate of
typical media GOP size or whole-player RSS savings.

## Relationship to the implementation

The initial investigation identified that the video worker retained the final GOP
after normal decoder drain while the session remained alive. Parallel implementation
PRs appeared during qualification. This work therefore builds on the smaller
generation-checked implementation in **PR #172** and adds independent validation.

There are **no additional production changes relative to PR #172**. The validation
branch retains that PR's exact `MediaSession.swift` and `FFmpegPacket.swift`.
It adds the controlled-loop experiment, the actual decoded-output ownership suite,
two CI workflows, and this evidence.

This validation PR targets `perf/video-recovery-eof-release-20261028-2d367`.
After the implementation merges, rebase/retarget the validation PR onto main as
appropriate; the implementation and qualification remain separately reviewable.

## Provenance

| Item | Qualified value |
| --- | --- |
| Original baseline | `ea2ff568237e2667f7b1aeee67b11a44ebe95b72` |
| Qualified experiment commit | `29227795552097be22675e0a8c498481042e44b3` |
| Implementation PR #172 snapshot | `c1ef6aff6060ad35decbc6dce0c224164be941a2` |
| Compiler | Swift 6.4.1, x86_64-unknown-linux-gnu |
| Host | Linux-7.0.0-1017-azure-x86_64-with-glibc2.39 |
| FFmpeg | 8.1.2, built from the repository's source archive |
| Archive SHA-256 | `464beb5e7bf0c311e68b45ae2f04e9cc2af88851abb4082231742a74d97b524c` |
| Qualification finished (UTC) | 2026-10-28T06:05:06.705588+00:00 |
| CI run | [40640946283](https://github.com/Jagalite/illiquid/actions/runs/40640946283) |
| Successful job | [122658686684](https://github.com/Jagalite/illiquid/actions/runs/40640946283/job/122658686684) |

The checkout was clean. The SDK builder verified the archive against both project
source manifests. The manifest retains the SDK source/build receipts and static
library hashes. Full original/staged source hashes, each extraction's hash, and
compiled binary hashes were recorded; final checks confirmed that sources and
binaries did not change during the experiment.

The complete baseline packet source is compiled only into the baseline binary;
the complete candidate packet source is compiled only into the candidate binary.
The baseline is not compiled against the new helper. The full baseline and
candidate `MediaSession` sources are retained, and their exact
`decodeVideoPacket`, pending-replay transfer, and `videoDecodeLoop` methods are
compiled into their respective harnesses.

For Linux, the runner omits unused CoreMedia APIs from the time utility, preserving
the exact rational type and seconds conversion. It extracts seven required C shim
helpers verbatim and adjusts only the controlled harness's platform imports.
The production session methods, packet operations, recovery owners, and native
release probe are unchanged.

## What the counters establish

Each packet starts with a real `av_new_packet` allocation. The probe transfers
the sole original `AVBufferRef` into a final-release callback. It does not copy
payload or retain an extra observer reference. Its live count reaches zero only
when the final native reference is released and the original backing is freed.

The reported bytes are `AVBufferRef.size`, including input padding. They exclude
packet/reference metadata, instrumentation overhead, allocator metadata or retained
pages, and GPU memory. Releasing ownership does not imply an identical immediate
reduction in resident or physical memory.

The decoder and output queues surrounding the extracted session methods are
controlled. Complete ordered output receipts are compared, including generations,
timestamps, packet signatures, drain output, EOS markers, failures, and replay
counts. These receipts are not decoded video pixels.

## Behavioral results

The experiment ran **72 primary fresh-process observations**:
nine scenarios × two AB/BA pairs × two configurations × two implementations.
All **36 complete baseline/candidate behavior comparisons** passed. The complete
canonical behavior for each scenario also matched across configurations and pairs.

| Scenario | Observed invariant |
| --- | --- |
| Empty input | EOS completes without any allocation. |
| Small GOP | All four allocations remain alive until drain returns; candidate releases them before EOS enqueue. |
| Budget GOP | All 512 allocations release at the same boundary; baseline retains them. |
| Repeated EOF | Repeated EOS preserves output/event order and causes no duplicate free. |
| Error after partial drain output | All four packets remain available for replay; a normal retry completion releases them. |
| Cancellation after partial output | Replay remains available without being classified as a decode failure. |
| Stale EOF | The stale event is rejected and the current GOP remains alive until valid EOF. |
| Independent owner | Its complete packet payload remains readable after the recovery owner releases; final free follows consumer release. |
| Later generation | The next generation records and releases its own GOP after flush; generation/EOS order matches baseline. |

Two additional **negative controls** required the old implementation to satisfy
the new EOF-release assertion. Debug and release both failed with exactly exit
**73** and:

```text
EOF_RELEASE_REGRESSION: expected 0 allocations / 0 bytes, found 4 / 1048832
```

The candidate passed the same assertion in both configurations. Compile errors,
crashes, or arbitrary nonzero exits do not qualify as negative controls. These
four assertion executions are additional to the 72 primary observations.

## Native qualification status

The new `VideoRecoveryDecodedOutputLifetimeTests` suite contributes three expanded
test cases using the actual software `VideoDecoder` and valid 32 × 24 BGRA input:

- Release after a normal drain while decoded pixels, PTS, and duration remain held.
- The same operation with an independent native packet clone that must remain valid.
- Cancelled native drain followed by recovery replay, with decoded output still valid.

Repeated release and decoder flush are also checked. The suite reuses the existing
scratch-frame fixture. The native workflow includes this suite, PR #172's direct
packet-lifetime regressions, existing packet-ownership tests, and scratch-frame
tests, compiling the full application/test graph.

**At report creation, the macOS component and native-regression jobs were still
queued. These native tests are added, not claimed as executed.**
Track [the macOS run](https://github.com/Jagalite/illiquid/actions/runs/40640946230)
and the validation PR's current checks. Keep the validation PR draft until the
native qualification succeeds. PR #172's dedicated real-session fixture study
remains separate and is not claimed as completed by this experiment.

## Lifecycle interpretation and limits

The release occurs after `VideoDecoder.drain` returns normally and before the
existing EOS output push can wait on presentation. Throwing errors and cooperative
cancellation skip the release. The helper checks generation under the existing
buffer lock so an obsolete completion does not retire a newer generation.

“Normal return” is the existing session API boundary. This work does not introduce
a stronger requirement about a particular FFmpeg EOF/EAGAIN status or change
tolerated software-error behavior.

Packet replay history is retired at decode completion, potentially before every
queued frame is presented. A later explicit decoder-recreation request uses the
existing seek fallback if no new replayable GOP exists. Independent packet and
decoded-frame ownership continue to govern the corresponding data's lifetime.

The controlled loop is synchronous. It does not qualify scheduler concurrency,
arbitrary concurrent decoder recreation, hardware decoding, visible presentation,
or end-to-end playback. The implementation retains the existing decoder-worker
lifecycle contract. No playback-speed, CPU, peak active-playback memory, or
whole-process RSS improvement is claimed.

## Retained evidence and reproduction

[Reproduction instructions](README.md) specify the pinned dependency, frozen
baseline, serial builds, and Kyoto coordination when available.

The [committed Linux evidence](evidence/linux) includes the complete manifest,
commands, all 72 ownership observations, the complete canonical controlled-output
receipts, and the summary. Files are preserved exactly as emitted by the successful
job. A separate `github-run.json` identifies the run and qualification scope.

The CI artifact additionally retains individual JSON reports, full original/staged
sources, and command/build logs for 14 days. This report and the committed evidence
remain available independently of that artifact's expiry.
