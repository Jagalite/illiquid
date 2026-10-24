# Native auxiliary-font audit evidence

This directory retains the native experiment from
[run 40101084730](https://github.com/Jagalite/illiquid/actions/runs/40101084730)
at candidate `4e64b3d2b6098536c61710dca2354442c718961c`, plus a separate audit.
It is evidence for that prototype, not qualification of PR #101's head.

- `native-run-40101084730.zip`: the complete, unchanged Actions artifact;
  SHA-256 `1b1ebc11ec33c6f9b57d28d86d811c0e0d4c5e6b7a952364ababfec0ff070583`.
- `artifact-receipt.json`: permanent run/artifact identifiers, digest, size,
  and observed step outcomes. Temporary download credentials are excluded.
- `audit-metrics.json`: independent arithmetic, process/order, inventory, and
  source-provenance checks.
- `audit-traces.json`: independent verification of the saved complete traces
  and compiled-component hashes.
- `audit.json`: the combined local audit receipt and script hashes.

The ZIP contains all measured/calibration stdout records, complete verification
traces, summary and raw JSON, source snapshots, compiled component binaries,
build commands, and the application compilation-failure log. Generated media
fixtures and the FFmpeg dynamic libraries are not included; their hashes and
generation/build provenance are recorded. Do not execute the archived binaries
to run the audit; the Python auditors read their bytes only.

Read the [research report](../../AUXILIARY_FONT_NATIVE_MEMORY_AUDIT.md) for the
findings and qualification limits, or the
[audit instructions](../../../Benchmarks/AuxiliaryFontNativeAudit/README.md)
to recompute them.
