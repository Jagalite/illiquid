# Subtitle vertex staging

The main Metal subtitle renderer used to build an Array containing six
vertices per quad, then copy that array into its pooled shared Metal buffer.
Each vertex upload repeated that array construction and explicit copy.

The candidate writes the same vertex fields directly into the checked-out
Metal buffer. It also reads the texture's dimensions and calculates the
frame-constant coordinate offsets once per upload. The resource pool, buffer
growth policy, vertex descriptor, triangle/quad order, shaders and completion
handlers are unchanged.

## Research results

See [RESULTS.md](RESULTS.md) for the measured portable CPU results and the
explicit native qualification status. Portable timings do not establish a
native Metal or whole-player speedup.

## Memory scope

Each vertex has two Float2 fields and one UInt8x4 color. The regression tests check a 20-byte field layout with a 24-byte stride.
At 256 quads, the removed
array's element storage and explicit copy each span 36,864 bytes (36 KiB).
This is source-level staging payload accounting, not a measured malloc count
or resident-memory reduction. Swift may optimize small array literals; no
per-quad heap-allocation claim is made.

The shared Metal buffer still exists and retains its previous capacity.
The new writer retains no additional CPU buffer. Vertex values are trivial
numeric data and are stored through raw memory; padding bytes are not shader
attributes and are deliberately excluded from field-parity comparisons.

Apple documents the raw-store contract in
[storeBytes](https://developer.apple.com/documentation/swift/unsafemutablerawbufferpointer/storebytes(of:tobyteoffset:as:)).
Its [shared-storage guidance](https://developer.apple.com/documentation/metal/mtlstoragemode/shared)
requires CPU/GPU access coordination. The existing renderer already provides
that coordination: a resource set remains checked out until its command
buffer's completion handler returns it to the pool.

## Reproduce

Requires macOS with a Metal device, Swift 6.1+ and Python 3.10+. Follow
[AGENTS.md](../../AGENTS.md): compile through Kyoto when available. The workflow
checks for Kyoto before using serialized direct builds on its isolated runner.

```sh
python3 Benchmarks/SubtitleVertexStaging/run.py --tests-only \
  --output /tmp/illiquid-vertex-tests
python3 Benchmarks/SubtitleVertexStaging/run.py --pairs 8 --target-ms 80 \
  --output /tmp/illiquid-vertex-timing
```

Use an empty output directory for every attempt.

## Source and correctness

The frozen baseline is the complete production compositor at main commit
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`.
Its SHA-256 is checked before use. The component adapter extracts the original
complete Vertex, FrameResources, makeVertices and uploadVertices declarations,
or the candidate's complete uploadVertices and frame resources plus the
complete new writer. Shared frame/configuration declarations must remain
byte-for-byte identical.

A thin adapter supplies a real Metal device, configuration and persistent
resources, calls those methods and reads logical vertex fields. Each variant
is compiled as a separate production module, then linked to the same driver.
The adapter does not substitute a fake texture, buffer or allocation API.
Extracted source, source hashes, compiler commands, binary hashes and host identity
are recorded with every run.

The driver compares every vertex position, texture coordinate and RGBA value
to a corner-based oracle. Float bit patterns are checked exactly; padding is
excluded. It checks both the entire output and the same consumed checksum
before/after timing. Buffer capacity and output receipts must agree across
paired variants.

Qualification includes both upload implementations in debug and release,
writer unit tests in debug/release and AddressSanitizer, and a separate native
app-graph build with the existing Metal ASS compositor and staging tests.
A new native render regression cycles through 64, 1, 0, 128, 2 and 64 quads
using one renderer and compares its pixels to an independent CPU reference.
That exercises capacity growth, smaller reused textures, empty clears and
changed colors.

## Timing protocol

Ten workloads use 1, 8, 64 and 256 quads, plus a varying-size sequence.
Each runs with rectangle-edge coordinates and with texel-center coordinates
plus a diagnostic negative pixel offset. All use a non-square canvas/output.
Two or more distinct frames per iteration prevent the driver from treating
the input as a single unchanged caption.

Fixtures, textures and initial buffer growth are outside timing. Warmup fills
the buffer to the workload's maximum required capacity; the varying-size case
measures reuse across changing counts, not repeated allocation growth.
The timed unit is one CPU vertex upload, including field construction,
the baseline array/copy or candidate direct stores, and an equal final-vertex
checksum read. No texture pixel upload, shader, draw, command buffer or
GPU execution is timed.

Eight fresh-process pairs alternate baseline/candidate order. Each pair uses
the same seed and iteration count. Calibration targets 80 ms on the faster
variant, with an estimated 1.5-second cap on the slower variant. Actual
durations and every sample are retained; no timing samples are discarded and
no control is subtracted.

These measurements qualify vertex-staging CPU work. The texture-property
loads and frame-constant calculations are part of that work, so any measured
gain is not attributed to memcpy alone. They do not establish a whole-player
CPU, frame-rate, energy or physical-memory improvement.
