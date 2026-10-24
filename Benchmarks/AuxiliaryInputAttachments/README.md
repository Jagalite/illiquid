# Auxiliary input font ownership

Illiquid opens independent FFmpeg inputs for subtitle packets, delayed audio,
thumbnail decoding, duration probes, and frame-step reads. Each input previously
materialized the same supported embedded fonts into independently owned Swift
`Data`, although only the primary media input supplies those fonts to the main
and picture-in-picture subtitle pipelines.

`FontAttachmentLoading.omit` suppresses those unused Swift copies. The default
remains `.include`; every stream descriptor and FFmpeg codec-private buffer
remains available in either mode. The auxiliary readers explicitly opt out.
FFmpeg's own per-context attachment allocation remains in both implementations.

## Experiment

The baseline is `6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635`. The runner compiles
complete production demuxer, executor, packet, stream-info and font source files
into separate optimized libraries, without changing their source text. Two
required supporting declarations are extracted verbatim from production.
The driver selects the existing default constructor for the baseline and the
explicit omission policy for candidate auxiliary inputs. Primary inputs use
the default constructor in both variants.

Five generated containers each contain a short H.264 video, FLAC audio, and ASS
subtitle track. Attachment cases are no fonts, the repository's licensed real
Noto Sans font, synthetic 2 MiB and 16 MiB fonts, and four 16 MiB fonts totaling
64 MiB. Synthetic font-labeled bytes exercise ownership, not font parsing or
representative user files. The real font fixture also drives rendering tests.

Four groups are measured per fixture: one primary input alone; one primary plus
one auxiliary executor; one primary plus two auxiliary executors; and one
primary plus one direct auxiliary demuxer. Each has six balanced AB/BA pairs,
with each observation in a fresh process. A no-font group warms Foundation,
FFmpeg, queues, and memory probes. The measured group is opened inside an
autorelease pool, which drains before retained-memory sampling.

Measurements occur while all inputs remain alive and **before** diagnostic
serialization, codec-private copying, packet reading, or payload hashing:

- Swift-owned attachment payload counts, separately for primary and auxiliaries.
- Whole-process live allocator bytes from `malloc_zone_statistics(NULL)`;
  the fixture's incremental value subtracts the warmed pre-open sample.
- Resident bytes from `task_info(MACH_TASK_BASIC_INFO)`, with the same subtraction.
- Process peak RSS sampled at that boundary; it is a lifetime peak, not a delta.
- Group-opening wall and process CPU time. Single-open timings are secondary,
  potentially noisy observations and do not establish an application speedup.

After sampling, the driver checks every stored metadata field, complete
codec-private payload hashes, every packet through EOF, and every packet after
a seek. Primary fonts match exactly; the only permitted output difference is
the intentionally empty auxiliary attachment array. Full reference outputs,
each observation, all unfavorable controls, compiler/source/library hashes, and
commands are retained. No observations are discarded.

This is an input-group allocation experiment. It does not measure full-player
memory, cold storage, decoding throughput, frame rate, or visible seek latency.
It does not remove FFmpeg's own attachment storage or libass font storage.
Savings depend on the font payload and number of active auxiliary inputs.

## Reproduction

On Apple Silicon macOS with the repository's verified native SDK:

```sh
python3 Benchmarks/AuxiliaryInputAttachments/run.py --validate-inputs
python3 Benchmarks/AuxiliaryInputAttachments/generate-fixtures.py \
  --output /tmp/auxiliary-font-fixtures
python3 Benchmarks/AuxiliaryInputAttachments/run.py \
  --fixtures /tmp/auxiliary-font-fixtures \
  --output /tmp/auxiliary-font-memory --pairs 6
```

The `Auxiliary input attachment memory` workflow runs this experiment and builds
the application/test graph in debug and release. It requires the real rendering
fixture and the mixed attachment fixture, and runs the new ownership/rendering
tests alongside existing font, playback-foundation, and input-failure tests.

## Qualification status

Local checks validate Python syntax, Swift parsing, fixture generation, source
provenance, and patch whitespace. Native results will be recorded after the
macOS workflow completes. No native performance result is claimed yet.
