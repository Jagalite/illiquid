# Native replication: auxiliary font ownership and physical-memory tradeoffs

## Result and decision

The macOS experiment confirms that omitting unused auxiliary font payloads
reduces live allocator ownership by approximately one font-payload length per
auxiliary input. It also finds a repeatable adverse result: **retained resident
memory and physical footprint increase by about 4 MiB with 16 MiB of fonts, and
about 16 MiB with 64 MiB of fonts**. All six paired comparisons show that increase
in each of the three auxiliary-input layouts at both sizes.

This is evidence for a narrower allocation-ownership improvement. It does not
establish lower process RAM, lower peak memory, or faster playback. The physical
memory increase should be investigated before treating this as an overall
macOS memory-performance win. The existing PR remains draft while its own native
qualification and this tradeoff are assessed.

This addendum consolidates an independently tested implementation into the
research for PR #101. It does **not** claim to qualify that PR's exact source.
The measured candidate uses a default-enabled Boolean option; the reviewed
PR #101 implementation at `f68d14cb216e7c4986df6cd67252567317c1d7ff` uses an
explicit default-preserving policy enum. Their seven opt-out sites and font-copy
guards have the same reviewed behavior, but their complete application source
trees and regression suites differ. Results below apply to the exact commits
and workloads identified here. The existing Linux results remain a separate
experiment and are not pooled with these macOS observations.

## Executed source and environment

- Baseline: `6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635`.
- Candidate: `979bdd34a93af1c564d505b1b6a4f6b12de27379`, with an empty working-tree status in the recorded run.
- [Completed native qualification](https://github.com/Jagalite/illiquid/actions/runs/40101300598): job `120893823744`, all steps successful.
- macOS 26.6.2 (25G83), virtual Apple M1, 7 GiB reported memory.
- Apple Swift 6.3.3; FFmpeg 8.1.2 from the repository's pinned native SDK.
- The benchmark compiles the complete production demuxer and executor in each
  variant using optimized Swift 6, whole-module optimization and warnings as
  errors. It extracts only unchanged support declarations.

The native cohort contains **19 scenarios, six balanced baseline/candidate
pairs per scenario, and 228 fresh processes**. It covers direct auxiliary
readers, one primary with one or two serialized auxiliary readers, and primary
controls. Scenario order reverses between pairs; variant order alternates.
No observations were discarded.

The [independent evidence audit](../Benchmarks/AuxiliaryAttachmentPolicy/evidence/macos-replication-979bdd/AUDIT.md)
passed 10,463 checks, including cohort completeness, paired arithmetic, all
396 reader receipts and 56,232 packet receipts, source and binary hashes, and
the exact native test counts and skips.

## All measured scenarios

Values are medians of the six **paired differences**, not differences between
independent medians. Heap saved is baseline minus candidate. The three physical
memory columns and opening-time column are candidate minus baseline: positive
values mean a larger or slower candidate. MiB means 1,048,576 bytes.

| Font fixture | Inputs | Heap saved (MiB) | RSS change (MiB) | Footprint change (MiB) | Peak RSS change (MiB) | Open time change (ms) |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| none | one auxiliary / direct | 0.0000 | +0.0547 | +0.0547 | +0.0547 | -0.012 |
| fonts-2mib | one auxiliary / direct | 2.0042 | -0.0312 | +0.0156 | -0.0312 | -0.389 |
| fonts-16mib | one auxiliary / direct | 16.0203 | +3.9062 | +3.9844 | +0.0391 | +0.007 |
| fonts-64mib | one auxiliary / direct | 64.0203 | +15.9688 | +16.0469 | +0.0938 | +1.478 |
| unsupported-only | one auxiliary / direct | 0.0039 | +0.0859 | +0.1641 | +0.0859 | -0.503 |
| mixed | one auxiliary / direct | 2.0042 | -0.0703 | +0.0078 | -0.0703 | -1.054 |
| none | primary + 1 / executor | 0.0000 | +0.0312 | +0.0312 | +0.0312 | -0.077 |
| fonts-2mib | primary + 1 / executor | 2.0002 | -0.0078 | -0.0078 | -0.0078 | -0.439 |
| fonts-16mib | primary + 1 / executor | 16.0163 | +4.0547 | +4.0390 | +0.1172 | +1.262 |
| fonts-64mib | primary + 1 / executor | 64.0163 | +16.0547 | +16.0547 | +0.1172 | -2.629 |
| unsupported-only | primary + 1 / executor | 0.0000 | +0.0938 | +0.0938 | +0.0938 | -0.236 |
| mixed | primary + 1 / executor | 2.0002 | +0.0938 | +0.0938 | +0.0938 | -1.663 |
| none | primary + 2 / executor | 0.0000 | +0.0703 | +0.0703 | +0.0703 | +0.151 |
| fonts-2mib | primary + 2 / executor | 4.0005 | -0.0000 | -0.0000 | +0.0000 | -0.676 |
| fonts-16mib | primary + 2 / executor | 32.0327 | +3.9922 | +3.9687 | +0.0391 | +12.036 |
| fonts-64mib | primary + 2 / executor | 128.0327 | +15.9922 | +15.9765 | +0.0469 | -63.114 |
| none | primary only / direct | 0.0000 | -0.0000 | -0.0000 | +0.0000 | -0.135 |
| fonts-2mib | primary only / direct | 0.0000 | -0.0234 | -0.0234 | -0.0234 | +0.412 |
| fonts-16mib | primary only / direct | 0.0000 | +0.1328 | +0.1328 | +0.1094 | -0.055 |

Source: [complete summary](../Benchmarks/AuxiliaryAttachmentPolicy/evidence/macos-replication-979bdd/summary.json) and
[all 228 complete observations, gzip](../Benchmarks/AuxiliaryAttachmentPolicy/evidence/macos-replication-979bdd/observations.jsonl.gz).
The [readable scalar observations](../Benchmarks/AuxiliaryAttachmentPolicy/evidence/macos-replication-979bdd/scalar-observations.jsonl) preserve
every process identity, memory/timing sample and copied-byte count; the compressed
original additionally contains all per-reader metadata and packet receipts.

### Interpretation

For primary plus two auxiliary readers, exact copied font lengths fall from
6 to 2 MiB, 48 to 16 MiB, and 192 to 64 MiB for the 2/16/64 MiB fixtures.
Live allocator reductions are approximately 4.0005, 32.0327 and 128.0327 MiB.
Small additional differences reflect object and allocation overhead rather
than additional font payloads.

Those allocation reductions do not translate into matching physical-memory
savings in this run. The 2 MiB case is near the no-font/control noise level.
The larger fixtures have consistent increases in retained resident memory and
physical footprint across direct and serialized layouts. Their sampled lifetime
peak RSS is essentially unchanged. These are distinct measurements; none is
a substitute for another. The experiment does not isolate the cause of the
physical-memory increase.

The live heap controls are unchanged except for a 4,112-byte reduction in the
direct unsupported-only case and tiny executor variations. Primary-only and
no-font physical-memory measurements also vary, and remain visible above.

Opening wall and CPU times are exploratory single-open observations. They
include improvements and regressions; for example the primary-plus-two,
16 MiB fixture is about 12.036 ms slower by paired median. No general latency,
FPS, energy or startup improvement is claimed.

The raw observations include after-release samples and weak-reference release
checks. All reader objects were released. However, metadata hashing and packet
validation occur between the retained sample and the after-release sample, so
the latter is not a clean isolated measurement of deallocation or long-running
cache behavior. It should not be used to erase the retained-memory regression.

## Native behavior qualification

The completed run built the application graph in Debug and Release. In each
configuration **73 test functions passed and ten were explicitly skipped**.
The Swift Testing footer says 83 tests in ten suites passed, but that count
includes the skipped tests; it must not be read as 83 executed successes.
All **20 cases in the new auxiliary suite** executed: three functions with six
fixture arguments each and two helper functions. The logs are retained verbatim
in the compressed receipt bundle. The new suite
checks default payload lifetime, opted-out metadata and codec preservation,
full packet data including side data, seeking and active-subtitle lookup,
executor forwarding, duration and frame-step behavior, and thumbnail pixels.
Existing font-admission, native foundation and thumbnail checks also ran under
the workflow's recorded filter. One existing mixed-attachment admission test,
two frame-step performance tests and seven timestamp-discovery tests were
skipped because their separate fixture environment variables were absent.
The new suite's actual frame-step and thumbnail output checks did execute.

The benchmark verifies full projected non-font metadata, primary font hashes,
codec-private data and initial/post-seek packet receipts outside the retained
memory sampling region. It keeps the measured inputs alive through that sample.
Original FFmpeg attachment extradata remains allocated in each native context.

These fixtures contain deterministic synthetic font-labelled bytes. They
qualify ownership and reader-output compatibility, **not actual embedded-font
rendering**. PR #101 adds a separate real-font libass test, whose result must be
established by that PR's own execution. No live player UI or full playback
session was measured here.

## Reproduction and retained evidence

Use the immutable candidate commit above with its
[benchmark instructions](https://github.com/Jagalite/illiquid/blob/979bdd34a93af1c564d505b1b6a4f6b12de27379/Benchmarks/AuxiliaryFontAttachments/README.md)
and [workflow](https://github.com/Jagalite/illiquid/blob/979bdd34a93af1c564d505b1b6a4f6b12de27379/.github/workflows/auxiliary-font-attachments.yml).
Follow current repository build-coordination instructions when the shared Kyoto
queue is available. This execution used an isolated GitHub-hosted macOS runner.

The [evidence index](../Benchmarks/AuxiliaryAttachmentPolicy/evidence/macos-replication-979bdd/index.json) records the original downloaded
artifact checksum, compact log-bundle checksum, and the hashes of every retained
file. The [full text receipts](../Benchmarks/AuxiliaryAttachmentPolicy/evidence/macos-replication-979bdd/full-text-receipts.json.gz) preserve
all text files from the native artifact, including exact compiled source
snapshots, the runner and harness, fixture and command receipts, build logs and
Debug/Release test logs. The exact executed workflow and new test source are
also included. Binary outputs are identified by hashes, rather than checked
into the repository.

The original artifact was `auxiliary-font-native-evidence`, ID `12563367510`,
from run `40101300598`. All text receipts are preserved even after the temporary
Actions artifact expires. The 64 MiB fixture is a stress case. The 16 MiB per-font
and 64 MiB playback admission limits do not universally bound raw-demuxer
allocations, which occur before that validation.
