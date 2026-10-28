# Picture in Picture texture-coordinate preparation

## Question and change

The video pass in PiPSubtitleCompositor.compose calculates six texture
coordinates for every composed frame. The HDR conversion pass repeats an
identity calculation once per frame. These coordinates depend on geometry,
not on frame pixels or timestamps.

This experiment adds one geometry cache per compositor and a constant HDR
identity array. The cache key includes coded size, optional clean aperture,
rotation, mirroring, and all display-crop components. Floating-point components
are keyed by their exact bits, including signed zero. A miss calls the original
mapping function unchanged. The cache retains one numeric key and six vectors;
it retains no frame, pixel buffer, subtitle object, or GPU resource. Access
remains on the compositor's serial work queue.

## Reproduce

On macOS with Swift 6.1 or later:

```sh
python3 Benchmarks/PiPTextureCoordinates/run.py \
  --output /tmp/illiquid-pip-coordinates --pairs 10 --target-ms 120
```

The output directory must be new or empty. Builds in this runner are serial.
Use the shared Kyoto queue when available, as required by AGENTS.md. Hosted
macOS CI has no access to that queue and builds directly.

The baseline is commit ea2ff568237e2667f7b1aeee67b11a44ebe95b72. The runner obtains
the complete original helper with git show and compiles it unchanged. A
benchmark-only adapter supplies the candidate's API while forwarding every
request to the original function. Its HDR property recomputes identity UVs at
1920 by 1080, a positive size for which the six outputs are dimension independent.
The production helper's existing mapping and color functions must remain
byte-for-byte identical.

Both variants are separately compiled optimized dynamic libraries. The same
driver links to each without cross-module optimization. A BASELINE compile define
selects the original function directly for timed general requests, avoiding an
extra forwarding call. HDR requests use an identical non-inlined support function
in both modules to keep the static property access inside the timed loop; that
common call overhead is included. Nine semantic tests
(the two original geometry tests plus seven cache tests) run against both
variants in debug and release. The driver additionally compares complete Float
bit patterns over a deterministic geometry-transition corpus.

## Measurement protocol

Six workloads cover stable identity geometry, stable crop/rotation, stable
mirroring, a geometry change every 120 requests, alternating geometry on every
request, and HDR identity preparation. The alternating case is the cache-miss
control and must be reported alongside the hits.

Each timed iteration requests one six-coordinate array and consumes one
coordinate component in an identical checksum loop. Fixture creation, warmup,
full-output verification, JSON serialization, and process startup are excluded.
CPU and wall time are recorded separately. Calibration chooses a common
iteration count for both variants of each workload, targeting the faster
variant. All calibration trials and measured samples are retained.

Ten fresh-process pairs alternate baseline-first and candidate-first order;
workload order rotates between pairs. The runner compares complete verification
receipts and each pair's checksum and final coordinates. Timing is not a CI
assertion. Review the paired CPU results and miss overhead before accepting an
optimization.

## Scope

This measures native CoreGraphics coordinate preparation, including the cache
lookup and shared driver-loop overhead. It does not measure Metal command
encoding, GPU rendering, decoding, frame rate, whole-player CPU, memory, or energy.

The workflow separately compiles the full native app graph and runs PiP mapping,
composition-policy, upload-reuse, and subtitle-pipeline regressions. That gate is
separate from the microbenchmark and does not constitute a live PiP UI session.

The runner records compiler and platform details, commit IDs, source and binary
hashes, test outcomes, raw observations, complete coordinate receipts, and
summaries. CI also preserves logs and exact source snapshots.

## Qualification status

As of 2026-10-28 05:48:46 UTC, both jobs in
[run 40639073635](https://github.com/Jagalite/illiquid/actions/runs/40639073635)
were still queued. The local execution environment also failed to connect.
No compilation, test-pass, or performance result is claimed for this experiment.

The source submitted to CI is commit bb13fdb605cd2658334e06ab01dd487b4a20f839.
This status-only update does not change the submitted source. The pending
receipt in evidence/pending.json records the job identities and observation time.
The queued workflow may finish after this status was recorded; consult its
results before making a PR decision.

No pull request was opened because success has not yet been demonstrated.
Acceptance requires preserved coordinate semantics, a repeatable CPU reduction
in stable and mostly stable geometry, an explicit accounting of all-miss cost,
and a successful native build/regression gate. The performance claim must stay
within coordinate preparation even if those gates succeed.

The native suite includes a media-session test that returns early unless
ILLIQUID_PIP_FOLLOWUP_FIXTURE or ILLIQUID_NATIVE_FIXTURE_DIR is provided. This
workflow supplies neither; that real-media seek/fanout case is not qualified.
The pixel-buffer geometry, HDR, and subtitle-composition cases use generated
in-memory inputs and do not depend on that fixture.
