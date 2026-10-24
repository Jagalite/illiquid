# Auxiliary-input font payload ownership

The primary playback input projects supported embedded-font bytes into owned
Swift `Data` for subtitle rendering. Independent inputs used for subtitle packet
reads, delayed audio, frame-step discovery, timeline thumbnails and thumbnail
metadata do not consume that projection. Previously each input nevertheless
made its own full Swift font copy.

The candidate makes the projection optional and passes
`includesFontAttachments: false` at those auxiliary call sites. Both initializer
defaults remain `true`. The main playback input continues to supply its owned
fonts to main and Picture-in-Picture subtitle pipelines.

**FFmpeg still loads and owns every attachment's native extradata in each open
input.** This change eliminates the unused Swift copy; it does not eliminate
FFmpeg attachment memory or share demuxers. No whole-player RAM or frame-rate
claim follows from this component experiment.

## Reproduce

On the repository's supported Apple Silicon macOS runner, after installing the
verified native SDK:

```sh
python3 Benchmarks/AuxiliaryFontPayloads/generate-fixtures.py \
  --output /tmp/auxiliary-font-fixtures
python3 Benchmarks/AuxiliaryFontPayloads/run.py \
  --fixtures /tmp/auxiliary-font-fixtures \
  --output /tmp/auxiliary-font-results --pairs 6
```

`--validate-inputs` checks source availability, unchanged shared dependencies and
declaration boundaries without requiring macOS. It does not compile or execute
the native experiment. The baseline is
`6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635`.

The dedicated workflow runs on the research branch before PR creation. It also
builds the complete application/test graph against the pinned native SDK and
runs the new ownership/rendering regressions and related existing suites.

## Fixtures and scenarios

Every workload is a generated Matroska file containing real FFV1 video, FLAC
audio, embedded ASS subtitle packets and the listed attachments. No fixture
media is checked in or downloaded.

| Fixture | Supported attachment bytes per input | Purpose |
| --- | ---: | --- |
| No font | 0 | Normal-open control |
| Actual font | 569,208 | Unmodified bundled OFL `NotoSans-Regular.ttf` |
| Synthetic 1 MiB | 1,048,576 | Modest copied-payload workload |
| Synthetic 16 MiB | 16,777,216 | Single-font payload stress case |
| Synthetic 32 MiB | 33,554,432 | Four distinct 8 MiB payloads |

The large and 1 MiB synthetic cases have supported font metadata but deliberately
synthetic bytes. They exercise admission and byte ownership, not valid-font
parsing or rendering. The separate real-font native integration test configures
the main and PiP subtitle pipelines and checks identical nonempty rendered output.

Each fixture is measured with a primary input only, one standalone auxiliary
input, primary plus one auxiliary, and primary plus two auxiliaries. These are
component configurations representing independent input roles; they do not
simulate a complete playback session or every possible simultaneous input.

## Measurement boundary

The runner compiles complete baseline and candidate production demuxer,
executor, packet and supporting files into separate native libraries. It does
not replace production implementations or discard arbitrary source lines.
Two unchanged support declarations are extracted at checked boundaries. The
same read-only benchmark extensions are appended to the complete demuxer and
executor source files to inspect their native ownership and synchronize their
serial queue. Original and compiled hashes are retained.

Each observation starts a fresh process and warms three no-font input executors.
The measured inputs are then opened through the real `FFmpegInputExecutor`.
A barrier on its actual serial queue establishes that the opening closure has
returned before memory is sampled. The inputs remain strongly owned during the
retained sample and are destroyed before the released sample.

Reported memory metrics are:

- **Owned Swift font payload bytes:** the sum of production
  `mediaInfo.attachments[].data.count` over the retained inputs. This is a
  deterministic payload count, not an allocator size or RSS measurement.
- **Retained allocator delta:** `malloc_zone_statistics(NULL).size_in_use` after
  the opens minus the warmed pre-open reading. It includes native demuxer/AVIO,
  Swift metadata, queues and allocator effects for the complete component
  fixture. It is not exact per-object allocation attribution.
- **Native font extradata bytes:** a separate post-measurement inventory proves
  that the native payload remains present in every input in both variants.
- **Released allocator delta:** an additional control after destroying measured
  inputs. Allocator/runtime bookkeeping can remain; this is not an RSS release
  guarantee.

Open wall and process CPU timings are recorded as secondary observations.
They include the queue-completion barrier and are not presented as a player
startup or playback-throughput benchmark. Release measurements use six balanced
AB/BA pairs per case/scenario. All samples remain in the evidence. Debug builds
also run the full semantic matrix once per variant.

## Correctness and provenance

After the measured inputs have been destroyed, a separate untimed input set
checks every stored media-info field, selected streams, attachment metadata,
full attachment SHA-256 values, copied codec parameters, direct codec-private
bytes, every packet's payload and side data, and packets after a seek. Comparison
explicitly excludes only the intended auxiliary Swift attachment projection;
native extradata and all other observations must match exactly.

Primary calls omit the new argument to exercise its default. Primary font
payload bytes and order must match the fixture manifest in both implementations.
Weak witnesses establish executor destruction before the retained media-info
snapshots are hashed again, proving owned font bytes survive input closure.

The output records production and harness hashes, baseline/candidate revisions,
compiler and SDK information, native library/binary hashes, complete command
logs, raw observations, semantic receipts, ranges and medians. The workflow
uploads these files and prints a compressed evidence bundle with its SHA-256 for
review. Measurement results should be reported only after that native run has
completed successfully.
