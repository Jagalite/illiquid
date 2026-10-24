# Native auxiliary-font evidence

This directory preserves every measured observation and control from the native
qualification runs. The [research report](../../../Documentation/AUXILIARY_FONT_MEMORY_PERFORMANCE.md)
explains the performance boundary and the adverse resident-memory result.

| Run | Measured candidate | Component result | Application qualification |
| --- | --- | --- | --- |
| [40101084730](https://github.com/Jagalite/illiquid/actions/runs/40101084730) | `4e64b3d2b6098536c61710dca2354442c718961c` | Complete; 384 final observations, 32 calibration observations, 48 verification traces | Failed during compilation of new test assertions; no test execution claimed |
| [40102141590](https://github.com/Jagalite/illiquid/actions/runs/40102141590) | `a95e1f09b379a31892181b20f6d9de0a042179c0` | Queued when the draft was prepared; no second cohort retained | Pending |

The subsequent `a95e1f09b379a31892181b20f6d9de0a042179c0` commit corrects the
throwing assertions. It does not change production or benchmark code. The first
run's measurements and failed build log remain intact.

Each run directory includes:

- `summary.json`, `manifest.json`, and `parity.json`: byte-identical copies of
  the original summary, source/environment receipts, and verification results.
- `observations.jsonl.gz`: the exact original observations after decompression,
  including calibration and adverse samples. Calibration is excluded from
  summary performance statistics.
- `native-tests.log`: the complete original application-test output, including
  failures when present.
- `independent-audit.json`: recomputed statistics and checks of source, command,
  binary, fixture, and trace provenance against the original downloaded artifact.
- `receipts.tar.gz`: all original non-build artifact files, including command
  receipts, complete stdout/stderr, verification traces, source and harness
  snapshots, fixture manifests, generation receipts, and native test output.
- `archive-members.jsonl.gz`: original path, byte count, and SHA-256 of each
  retained archive member.
- `provenance.json`: original run, commit, artifact URL and digest, exact retained
  and omitted files, archive hashes, and qualification status.

Archive paths and file payloads are unchanged. Archive metadata is normalized
for deterministic packaging. Executables, dylibs, compiled Swift module
products, and generated ABI JSON are omitted; their exact hashes are retained.
They were rehashed during the independent audit while the original artifact
was available. The retained hashes alone cannot reconstruct those binaries
after the GitHub artifact expires. Generated Matroska files and installed
compiler/native-library binaries were not included in the original artifact;
the manifests and generation/build commands identify them.

To inspect a run without modifying this evidence directory:

```sh
mkdir -p /tmp/auxiliary-font-receipts
tar -xzf Benchmarks/AuxiliaryFontAttachments/evidence/run-40101084730/receipts.tar.gz \
  -C /tmp/auxiliary-font-receipts
gzip -dc Benchmarks/AuxiliaryFontAttachments/evidence/run-40101084730/observations.jsonl.gz
```
