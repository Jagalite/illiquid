# October 24 PR integration review

This candidate combines the retained changes with merge ancestry so GitHub can
record the original PRs as merged after the integration reaches main. Original
benchmark evidence, frozen baselines, and unsuccessful observations are retained.

## Disposition

| PRs | Decision |
| --- | --- |
| #94 | Merged directly after all 11 checks passed; playlist array sharing preserves first-item metadata and compacts sparse storage. |
| #92 / #98 | Retain #98; close #92 as an alternative startup snapshot ownership fix. |
| #100 / #114 | Retain #114; close #100 as an alternative scratch-frame release fix. |
| #101 / #103 | Retain #103 and independent research #111; close #101 as an alternative font-copy policy. |
| #116 / #112 | Retain #112; close #116 as an alternative visibility-row storage optimization. |
| #93, #95, #96, #99 | Integrate restoration, PCM, deinterlacer EOF, and source-scan snapshot ownership changes. |
| #102, #106 | Combine borrowed qualifier prefixes with streaming candidate scoring in one matcher. |
| #104, #105 | Integrate indexed media grouping and per-slot subtitle staging capacity. |
| #107, #108, #109, #110 | Integrate operation task cleanup, planar history deduplication, negative sidecar storage, and bounded thumbnail read reservation. |
| #113, #115 | Integrate immutable completion-contract sharing and compact PlexMatch episode mappings. |

## Integration fixes

- Preserve every independent generated-evidence attribute during conflict resolution.
- Resolve the subtitle matcher visitor signature to accept the borrowed token slices.
- Use an exactly representable 0.125-second PCM test delay (five full chunks plus
  880 samples). The old 3,148-sample requested delay quantizes to 3,147 samples
  through native CoreMedia's 60 kHz conversion; production timing is preserved.
- Keep the historical PiP benchmark's shared metrics declaration byte-identical.
  The added diagnostic documentation already exists in the staging research;
  it need not change a pinned shared declaration.
- Expose Darwin allocator/rusage interfaces when compiling the planar-history C
  probe alongside its portable POSIX clock interfaces.

## Native evidence and limits

The completed #112 native allocation/timing campaign is Actions run
[40102200273](https://github.com/Jagalite/illiquid/actions/runs/40102200273).
At 100,000 unchanged rows its median paired allocator reduction is 52,379,600
bytes. Native timing remains mixed: the hide-last paired CPU increase is 2.64%
and the keep-one increase is 5.04%, with no material keep-one memory saving.
The large retained-row saving is accepted with this documented tradeoff; no
universal speedup or whole-player RSS claim follows.

The #115 native component campaign also completed successfully in
[40103110705](https://github.com/Jagalite/illiquid/actions/runs/40103110705).
The independent #111 archived font audit was replayed successfully, checking
384 measured processes and 112 metric records. It explicitly preserves the
original application-test compilation failure. Font ownership savings do not
establish lower immediate RSS; the adverse RSS observations remain relevant.

The combined native script requires generated video/audio, timestamp, mixed
attachment, and real-font fixtures before running affected app/core/player/native
suites. It also reruns the corrected planar-history experiment and native
thumbnail read experiment. Local compilation is submitted through Kyoto; the
hosted workflow explains the unavailable queue before isolated direct builds.
A queued job is not a test pass. Final qualification receipts are recorded in
the integration PR after execution. Interactive UI, presentation latency,
hardware residency, and whole-player memory remain outside this review.
