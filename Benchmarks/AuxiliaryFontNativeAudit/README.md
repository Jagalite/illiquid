# Independent native font-memory audit

This replays and checks the evidence from native Actions run
[40101084730](https://github.com/Jagalite/illiquid/actions/runs/40101084730).
It needs Python 3.10 or newer and only the standard library. It does not compile
or execute any native code and does not access the network.

From the repository root, use a new or empty output directory:

```sh
python3 Benchmarks/AuxiliaryFontNativeAudit/audit.py \
  --output /tmp/illiquid-native-font-audit-40101084730
```

The command verifies the exact retained ZIP digest, extracts it into a temporary
directory, and runs two independent auditors. It writes `audit-metrics.json`,
`audit-traces.json`, and a combined `audit.json`. A nonzero exit signals a
discrepancy. The retained receipts in
[the evidence directory](../../Documentation/PerformanceEvidence/AuxiliaryFontNativeAudit/README.md)
were produced with additional Git-source verification enabled.

## Checks

`metrics_audit.py` recomputes all 112 scenario/metric summaries from the 384
measurement records, validates the 32 calibration processes and their selected
iteration counts, and matches 416 raw process stdout bodies and hashes to the
observation records. It checks actual AB/BA sequence in both command and
observation order, memory checkpoint arithmetic, expected font ownership, and
default/no-font controls. Favorable and unfavorable observations are retained.

`verify_traces.py` compares the eight full verification outputs containing 48
complete traces across direct demuxers and serialized executors. It checks the
intentional auxiliary font omission, metadata, codec-private payload hashes,
complete packet and seek trace records, deterministic font-hash oracles, and recorded
source/build/binary hashes. It also records the failed application-test
compilation separately from the successful component commands.

For additional verification against the pinned production and driver Git
objects, make both commits available in this checkout and pass `--repository`:

```sh
git fetch origin \
  6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635 \
  4e64b3d2b6098536c61710dca2354442c718961c
python3 Benchmarks/AuxiliaryFontNativeAudit/audit.py \
  --repository . --output /tmp/illiquid-native-font-audit-with-git
```

The audit itself performs only `git show` reads when that option is supplied.
Without it, the archived compiled inputs are still checked against their
recorded hashes, but a fresh checkout need not contain the old prototype.

## Scope and native reproduction

The [research report](../../Documentation/AUXILIARY_FONT_NATIVE_MEMORY_AUDIT.md)
explains the allocation savings, immediate RSS regression, timing boundary, and
remaining qualification. An audit pass means the retained data and calculations
are consistent. The measured run's application tests failed to compile. It does
not mean those tests passed, nor does it qualify implementation PR #101's head.

For a separate native rerun, use the
[original benchmark instructions at the measured commit](https://github.com/Jagalite/illiquid/blob/4e64b3d2b6098536c61710dca2354442c718961c/Benchmarks/AuxiliaryFontAttachments/README.md)
and its
[workflow/dependency setup](https://github.com/Jagalite/illiquid/blob/4e64b3d2b6098536c61710dca2354442c718961c/.github/workflows/auxiliary-font-memory.yml).
Pin both revisions, regenerate fixtures, retain every sample, and label the new
host/cohort separately. Follow the current repository's `AGENTS.md`: submit
builds through Kyoto when available, explain a missing queue before direct
builds, and serialize shared build directories. The saved artifact omits media
fixtures and native FFmpeg libraries; it records their hashes and provenance.
