# PGS packet borrowing

This native macOS experiment measures the PGS **composition metadata** path before
FFmpeg pixel decoding. The previous decoder copied an entire `AVPacket` into
Foundation `Data`, then inspected segment headers and composition references. The
candidate passes the owning `FFmpegPacket` to the parser, which borrows its bytes
for the synchronous parse.

## Reproduce

After installing the repository's pinned native dependencies:

```sh
python3 Benchmarks/PGSPacketBorrow/run.py \
  --pairs 8 --target-ms 80 --output /tmp/pgs-packet-borrow
```

`--tests-only` builds both executables and runs complete-output parity without
timing. `--ffmpeg-prefix` defaults to `/opt/homebrew/opt/ffmpeg`. The runner requires
macOS; it does not download dependencies or replace native APIs with stubs.

The baseline is commit `7f9ba073394b77a908e0589447c6edc8d10b832c`. Its complete
`PGSSubtitlePresentation.swift` is frozen alongside SHA-256 hashes of unchanged
dependencies. The runner verifies the frozen parser against Git, checks that the
baseline is an ancestor, and rejects any changed shared dependency before building.
Both executables compile the complete real `FFmpegPacket`, `MediaTime`,
`FFmpegError`, `PacketQueue`, and `FixedRingBuffer` sources and the full CFFmpeg
module. Only the driver adapter is selected by `-D BASELINE`: old
`packet.data`/`update(in: Data)` versus new `update(in: FFmpegPacket)`.

## Workloads and correctness

Each workload rotates 16 authored packets. Cases cover a three-byte END packet,
one-object composition, two cropped objects, object-only packets around 4 KiB and
64 KiB, composition plus object data, and object data split across multiple
segments around 256 KiB. Every segment length fits the PGS UInt16 length field.
Large object data is deterministic pseudo-RLE used to model packet size and
segment traversal; this experiment does not decode or claim validity of its pixels.

Before timing, both variants emit individual complete snapshots of all object
coordinates, crop fields, nil/clear distinction, and errors. The corpus includes
authored expected values, all truncations of a two-object cropped composition,
null and negative packet lengths, boundary segment sizes, deterministic random
bytes, and mutated compositions. The runner compares the full traces, not just
an aggregate checksum. Native crop/decoder tests separately qualify integration.

## Measurement contract

- Optimized Swift, whole-module optimization, real `AVPacket` allocation and
  production packet ownership. Packet fixture construction is outside timing.
- A 4,096-call warmup precedes every observation. Results consume every returned
  object/crop field and are emitted to the invoking process.
- At least six fresh-process pairs alternate baseline/candidate and
  candidate/baseline order. The default is eight pairs.
- Each variant is independently calibrated to complete cycles of the identical
  16-packet input distribution. Iteration counts are recorded and times are
  normalized per packet. This avoids forcing the copying baseline to run for
  many seconds when the borrowed path is much faster.
- Both process CPU and monotonic wall time must reach at least 60 ms per timed
  sample. Short observations fail qualification; the runner retains their data.
- Timed checksums must match the expected repeated-cycle checksum, and both
  variants must have identical first/last outputs, cycle checksums, warmup
  checksums, and packet sizes.

The output directory retains exact compiled source snapshots, source/library and
binary hashes, compiler flags/environment, full correctness traces, calibration
pilots, raw JSONL measurements, normalized summaries, and command receipts.

These numbers describe a component before decoding. They do not establish
whole-player CPU, frame-rate, memory-residency, or energy improvements. The large
payload cases explain copy scaling; real PGS packet sizes and update frequency
determine the impact in actual playback.
