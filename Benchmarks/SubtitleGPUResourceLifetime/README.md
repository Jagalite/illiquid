# Main subtitle GPU resource lifetime

## Validation status

Recorded on 2026-10-28. The change remains a draft until native qualification passes.

| Check | Observed result |
| --- | --- |
| Portable production pool, debug | 6 tests passed |
| Portable production pool, release | 6 tests passed |
| Actual Metal allocations and output pixels | Queued; no measured result yet |
| Native application build and authority handoff | Queued; no result yet |

[Passing portable run](https://github.com/Jagalite/illiquid/actions/runs/40642849317)
at `66977dc4040629b50de71ca9bdec842e761e383b`;
[native qualification run](https://github.com/Jagalite/illiquid/actions/runs/40643119244)
at `6e41b75242decf9e2bc57004009bf05ccd2b7d60`.
The production changes and pool test source are identical in these revisions.

The portable check extracts the complete production pool/resource declarations
and copies the actual pool test file unchanged. Type-only Metal protocol
declarations typecheck the unused optional fields, which remain nil. This tests
Swift ownership and locking without a Metal implementation or rendering.
It does not replace either native gate.

Reproduce that narrower check with Swift 6.2.4 and Python 3:

```sh
python3 Benchmarks/SubtitleGPUResourceLifetime/check_pool.py --output /tmp/illiquid-subtitle-pool
```

The checked-in `results/portable-result.json` and
`results/2026-10-28-portable-tests.log` retain the observed test outcome and
the artifact receipt. Source hashes and staged declarations are also retained
in the [portable artifact](https://github.com/Jagalite/illiquid/actions/runs/40642849317/artifacts/12795523964).

## Finding

The main subtitle renderer reuses a pool of texture and vertex-buffer pairs.
Before this change, every completed draw returned its pair to the same pool,
which survived as long as the shared overlay. A large atlas could therefore
remain owned after a subtitle source was replaced, even if the next source
needed much smaller subtitles.

Each pair now carries an immutable source generation. When a main subtitle
pipeline gains presentation authority, the renderer advances that generation
and detaches its idle pairs under the existing lock. Those resources are
released after unlocking. Later returns from earlier generations are discarded.
The existing command-buffer completion closure continues to own borrowed
resources until GPU completion; retirement never modifies borrowed resources.

## Authority boundary

Candidate pipelines share the committed source's overlay while preparing their
private libass context. Initial authority revocation, candidate preparation,
and candidate termination must therefore leave the shared GPU cache alone.

Retirement runs synchronously in the changed-to-true branch of
`SubtitlePipeline.setPresentationAuthorityEnabled`, guarded by `presentsOverlay`.
Repeated true assignments do nothing. Rollback also passes through this boundary.
The call is synchronous because an immediate seek can supersede the queued
visible-clear revision; tying retirement only to that clear could lose it.

Normal subtitle gaps, seeks, geometry changes, and small frames within the
same source preserve existing reuse. Stop-only and subtitle-disable reclamation
are outside this change.

## Reproduce

Requires macOS 26, the repository's Xcode toolchain, Python 3, and a real Metal
device. Follow `AGENTS.md`: submit the command through Kyoto where available;
otherwise compile serially in an isolated checkout.

```sh
python3 Benchmarks/SubtitleGPUResourceLifetime/run.py --output /tmp/illiquid-subtitle-gpu-memory
```

The output directory must be new or empty. The runner refuses non-macOS
execution and refuses to overwrite previous evidence.

The temporary component package stages the full production compositor, memory
budget, shader loader, Metal shader resource, and complete `ASSRenderedRegion`
declaration. It runs actual pool/Metal tests in debug and release, then compares
release probes built from baseline and candidate source.

The workflow's separate native job compiles the full application/test graph
and exercises the authority handoff plus existing main/PiP subtitle tests:

```sh
swift test --force-resolved-versions -c release --no-parallel --filter 'SubtitleGPUResource|MetalASSSubtitleCompositorTests|PiPSubtitlePipelineTests'
```

The existing fixture-dependent PiP media-session test requires
`ILLIQUID_PIP_FOLLOWUP_FIXTURE` or `ILLIQUID_NATIVE_FIXTURE_DIR`. Neither is set
by this workflow, so that test's media-session body is not qualified here.
The optional heavy animated ASS benchmark is also not enabled.

## Baseline and measurements

Baseline: `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`.

The baseline adapter only widens test visibility, adds read-only accounting,
and supplies a no-op retirement entrypoint because the original renderer has
no such operation. Its original acquire/release, draw, encode, upload, vertex
construction, and offscreen-render bodies remain intact. Shared dependencies
must exactly match the pinned baseline or the runner fails.

| Fixture | Atlas | Quads | Nominal uploaded pixels | Readback |
| --- | --- | ---: | ---: | --- |
| R8 coverage | 2048 × 2048 | 256 | 4 MiB | 64 × 64 |
| Premultiplied BGRA | 2048 × 2048 | 256 | 16 MiB | 64 × 64 |

These upload sizes define the synthetic fixtures. Actual idle texture and
vertex-buffer allocations are measured with `MTLResource.allocatedSize`.

The probes record ownership after a large frame, an ordinary empty frame,
source retirement, rebuilding the large frame, and a following 32 × 32
one-quad source. Acceptance requires:

- Actual Metal resources and unchanged reuse across ordinary subtitle gaps.
- Unchanged baseline ownership after its no-op retirement.
- Zero candidate idle pairs and texture/buffer bytes after retirement.
- Smaller retained allocations for the following small source.
- Matching complete output hashes across baseline/candidate and exact
  output-byte equality before and after rebuilding resources.

Candidate Metal tests add varying coverage/colors and compare small frames
rendered through reused and fresh resources. Pool tests use weak references,
delayed returns, overlapping source generations, and concurrent returns versus
retirement without sleeps. Native authority tests cover candidate isolation,
promotion, immediate clears, rollback, and nonpresenting pipelines.

The workflow retains `summary.json`, per-variant measurements, source hashes,
commands, test logs, staged sources, and environment information. The PR
records the observed results and corresponding workflow run.

## Interpretation and tradeoffs

The measurement is **idle pool-owned Metal resource bytes**. It does not
measure RSS, physical footprint, or immediate driver-memory reclamation.
The large synthetic atlases do not establish typical-media memory consumption.

A source handoff now releases cached resources; later frames allocate the
capacity they need. Same-source reuse remains. This experiment does not
establish playback speed, frame pacing, energy use, or source-switch latency.

The delayed-completion tests exercise the real production pool. The offscreen
Metal probe waits for command completion; it does not stall a native GPU
command across a visible UI source switch. The asynchronous ownership closure
and rendering/encoding paths remain unchanged.

Apple API contracts:

- [Command-buffer completion handlers](https://developer.apple.com/documentation/metal/mtlcommandbuffer/addcompletedhandler(_:)) run after GPU command execution finishes.
- [MTLResource.allocatedSize](https://developer.apple.com/documentation/metal/mtlresource/allocatedsize) reports allocated resource size in bytes.
