# Normalized file identity performance

## Status and result

The portable study completed successfully on 2026-10-28: ordinary ASCII key
generation took **7.89% less wall time**, escaped localhost keys took **7.57%
less**, and complete playlist lookup/deduplication workloads took **6.82–7.58%
less**. Every favorable workload improved in all ten pairs. All four
baseline/candidate debug/release test runs passed.

**Native macOS qualification is still pending. These Linux measurements do not
establish a macOS speedup or authorize a whole-player performance claim.**
The macOS workflow must pass compatibility and demonstrate a useful tradeoff
before this change is considered ready to merge.

There are small, repeatable control regressions: Unicode fallback keys take
0.91% more wall time (+34.19 ns/key), and rejected sources take 4.05% more
(+7.92 ns/key). They occur in both measurement orders and are retained in the
results. No no-regression claim is made.

## Production change and compatibility

This study compares against main at
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`.
Previously, `NormalizedFileURL.persistenceKey(for:)` called
`normalize(url)?.path`, constructing an intermediate file URL solely to read
its path back after local-source validation, lexical standardization, and
canonical Unicode composition.

The candidate returns a simple printable ASCII absolute path directly.
Unicode and control bytes, repeated slashes, dot-prefixed components,
empty/nonabsolute paths, and non-root trailing separators use the original
URL reconstruction. URL-valued normalization, explicit filesystem resolution,
authority validation, and playlist ordering/metadata behavior are unchanged.

This restriction is deliberate. Foundation's file URL initializer passes
through the filesystem representation, which can affect Unicode byte
representation and unusual path forms. Removing that step unconditionally is
not assumed equivalent. See the
[Swift Foundation URL implementation](https://github.com/swiftlang/swift-foundation/blob/swift-6.3.2-RELEASE/Sources/FoundationEssentials/URL/URL_Swift.swift).
Tests compare UTF-8 bytes, because ordinary Swift string equality can hide
canonical-equivalence differences in persisted keys.

## Portable measurements

Measured probe:
[`035abc66a4226ec2913d949035d3568d1943b74f`](https://github.com/Jagalite/illiquid/commit/035abc66a4226ec2913d949035d3568d1943b74f),
[successful run 40637671688](https://github.com/Jagalite/illiquid/actions/runs/40637671688).
The production implementation, harness, and runner are byte-identical to the
candidate on the main research branch. The probe differs only in its workflow
and the narrow empty-relative-reference fixture correction incorporated here.

Environment: Linux 6.17.0-1022-azure, x86_64, glibc 2.39,
Swift 6.4 (`swift-6.4-RELEASE`). These values come from the successful run's
manifest; an earlier diagnostic probe used Swift 6.4.1.

Medians are per key or complete operation as labeled. Negative time change
means less time; positive means more time. CPU and wall results agree closely.

| Workload | Baseline | Candidate | Wall time change | CPU time change | Faster pairs |
|---|---:|---:|---:|---:|---:|
| Ordinary ASCII key | 3.683 µs/key | 3.393 µs/key | -7.89% | -7.90% | 10/10 |
| Unicode fallback key | 3.777 µs/key | 3.811 µs/key | +0.91% | +0.90% | 1/10 |
| Escaped localhost key | 3.749 µs/key | 3.465 µs/key | -7.57% | -7.57% | 10/10 |
| Rejected-source key control | 0.195 µs/key | 0.203 µs/key | +4.05% | +4.05% | 0/10 |
| Last-item lookup, 100 items | 0.367 ms/op | 0.340 ms/op | -7.26% | -7.25% | 10/10 |
| Last-item lookup, 10,000 items | 37.575 ms/op | 34.727 ms/op | -7.58% | -7.57% | 10/10 |
| Missing lookup, 10,000 items | 37.308 ms/op | 34.528 ms/op | -7.45% | -7.46% | 10/10 |
| Deduplicate 1,000 unique items | 3.944 ms/op | 3.675 ms/op | -6.82% | -6.82% | 10/10 |
| Deduplicate 1,000 items (500 identities) | 3.933 ms/op | 3.640 ms/op | -7.44% | -7.44% | 10/10 |

There are 180 retained observations: nine workloads, ten paired rounds, and two
variants. Each workload has five baseline-first and five candidate-first pairs.
The shortest measured sample was 178.18 ms; the calibration target was 150 ms.
An independent audit recomputed all medians, ratios, reductions, sample order,
operation counts and checksums without discrepancies. The source, harness,
runner, and updated test hashes were checked against the proposed contents.

### Correctness

Each of baseline debug, baseline release, candidate debug, and candidate release
passed **70 tests in ten suites**. The six new test methods include 7,290
encoded/literal path combinations, independently expected ASCII values,
Unicode composition, control characters, encoded separators and dot segments,
queries/fragments, relative URLs, authority handling, and playlist metadata.

The relative-reference test requires all 78 nonempty base/reference pairs to
construct and match the frozen legacy oracle byte for byte. It also tests
empty references when Foundation constructs them; versions that reject an
empty reference cannot pass that value to the identity function. This corrects
the fixture assumption found by the initial portable probe without relaxing
any nonempty identity comparison.

Complete output parity for all nine benchmark fixtures passed before timing,
including exact key bytes and serialized deduplication metadata.

### Evidence

[Retained evidence](evidence/linux-x86_64-20261028/README.md) includes the manifest,
command receipts, correctness/completion receipts, calibration, all raw
observations, summaries, and explicitly labeled test log tails.

The [full CI artifact](https://github.com/Jagalite/illiquid/actions/runs/40637671688/artifacts/12794093168)
includes complete logs and source snapshots (14-day CI retention).
Artifact ZIP SHA-256:
`ce63fbb0055bbadb0d799495c5b0b3e44e922adbe464c8fe2d2c8a2d096e9258`.

Initial probes produced no timing samples: the first macOS probe stopped on
warnings in existing tests treated as errors by the new harness, and the first
portable probes stopped on the empty-relative-reference fixture assumption.
Warnings remain fatal for the separately optimized production module and
benchmark driver. Existing Swift Testing suite warnings are not promoted to
errors by the test runner.

## Limits

This is a single hosted Linux machine with warmed, immutable synthetic inputs,
not an independent multi-host study. Input construction, playlist sorting,
filesystem scanning and I/O are excluded; output consumption and bounded
autorelease-pool cleanup are included. Large-lookup results measure scanning
the actual production playlist implementation. They do not establish decoding
throughput, frame rate, energy use, whole-player CPU, or perceived UI latency.
The Unicode and rejected-source regressions must be assessed alongside gains.
Native Foundation behavior and native performance remain outstanding gates.

## Reproduce

Use Swift 6.1 or newer and Python 3.10 or newer. On macOS, select the repository's
Xcode configuration. The pinned baseline must exist in the checkout's Git history.

```sh
export DEVELOPER_DIR=/Applications/Xcode_26.6.app/Contents/Developer
python3 Benchmarks/NormalizedFileIdentity/run.py \
  --output /tmp/illiquid-file-identity --pairs 10 --target-ms 150
```

The output directory must be new or empty. Build commands run serially.
If the shared Kyoto queue is available, coordinate builds through it as required
by `AGENTS.md`. The isolated CI host has no Kyoto installation.

## Method

The runner builds the exact baseline and candidate production sources in
separate optimized Swift modules, then links the same driver to each without
cross-module optimization. It runs the new file-identity tests and the existing
local-source, utility and playlist regression suites against both variants in
debug and release configurations. Complete fixture/output comparisons precede
timing; key strings are compared as UTF-8 bytes.

Nine synthetic workloads cover ordinary paths, decomposed-Unicode fallback controls, escaped
localhost URLs, rejected-source controls, tail and missing playlist lookups, and
unique/repeated playlist deduplication. Key workloads report time per key.
Lookup and deduplication workloads report time per complete operation at the
specified playlist size. Fixture creation and sorting happen before timing;
output consumption and bounded autorelease-pool cleanup are included.

Each fresh process warms the operation before measurement. Calibration gives
both variants the same iteration count, targeting at least 150 ms for the
faster variant. Ten adjacent pairs alternate AB/BA, and case traversal reverses
each round. Wall time, process CPU time, exact iteration counts and checksums are
retained for every sample. There is no noisy timing threshold in CI.

The output includes source/binary hashes, environment and command receipts,
test logs, full verification logs, calibration, all observations and summaries.
The macOS workflow uploads full artifacts and emits compact receipts in its log
so the final research record can be retained with the change.
