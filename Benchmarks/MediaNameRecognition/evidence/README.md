# Media filename recognition evidence

The [research report](../../../Documentation/MEDIA_NAME_RECOGNITION_PERFORMANCE.md)
explains the production change, methods, results, and limitations. This directory
keeps small result files inspectable and the complete evidence in compressed
archives. The archives preserve original source snapshots, logs, raw timing rows,
canonical output bytes, and receipts, including unsuccessful attempts.

## Completed qualification

[Native GitHub Actions run 39069883928](https://github.com/Jagalite/illiquid/actions/runs/39069883928)
succeeded on measured commit `8df44b9630dc1814c44031cad6ba3c2925db7a93`.
The native host was macOS 26.6.2, Apple M1 (Virtual), Apple Swift 6.3.3, and Xcode
26.6. Seven of eight workloads had lower median paired wall and CPU costs;
ambiguous names were 0.52% slower in wall time and 1.15% slower in CPU time.
The Linux Swift 6.3.2 cohort improved all eight paired medians. Each final cohort
contains 96 fresh-process observations: eight workloads, six pairs, 4,000 calls
per process, and 128 warmup calls. These are synthetic warm recognizer component
measurements.

| Result files | Status and use |
| --- | --- |
| [macOS summary](results/macos/summary.json), [raw observations](results/macos/measurements.jsonl), [source hashes](results/macos/sources.json), [verification](results/macos/verification.json) | Complete final native cohort; 188,534 byte-identical outputs and four baseline/candidate debug/release test runs, each with 12 tests. |
| [Native integration log](results/macos-integration/tests.log), [provenance](results/macos-integration/provenance.json) | Debug application graph built and linked; 71 selected tests in seven suites passed. |
| [Linux summary](results/linux/summary.json), [raw observations](results/linux/measurements.jsonl), [source hashes](results/linux/sources.json), [verification](results/linux/verification.json) | Complete final Linux cohort; 188,534 byte-identical outputs. All 48 pairs retained, including the two slower observations. |
| [Linux date-only summary](results/linux-date-only/summary.json), [raw observations](results/linux-date-only/measurements.jsonl) | Complete exploratory two-pair ablation; 3,734 identical outputs. |
| [Linux tags-only summary](results/linux-tags-only/summary.json), [raw observations](results/linux-tags-only/measurements.jsonl) | Complete exploratory two-pair ablation; 3,734 identical outputs. |
| [Linux test receipts](results/linux-validation/test-results.json), [status](results/linux-validation/STATUS.md) | All four configurations passed 12 tests; the subsequent original baseline corpus failed. The attempt is not overall verified and supplies no timing result. |

Percentage summaries use the median of matched candidate/baseline ratios; that
statistic differs from dividing the separate per-variant medians. Both wall and
process CPU observations remain available. Do not pool platforms or exploratory
variants into the final cohorts.

## Complete archives

Each archive contains the named cohort directory. Extract them into the same
empty destination to recreate the full evidence layout. [archive-index.json](archive-index.json)
records each archive's SHA-256 and every member's uncompressed hash and byte count.
Tar headers are normalized for deterministic packaging; file contents, including
the original gzip streams, are unchanged. `results/` contains exact copies of
selected archive files, not a complete verifier input directory.

| Archive | Contents and qualification |
| --- | --- |
| [macos.tar.xz](archives/macos.tar.xz) | Full native component evidence under `macos/component`, host details, and GitHub artifact provenance. |
| [macos-integration.tar.xz](archives/macos-integration.tar.xz) | Native application build/consumer-test log and artifact provenance. |
| [linux.tar.xz](archives/linux.tar.xz) | Complete final six-pair Linux cohort. |
| [linux-date-only.tar.xz](archives/linux-date-only.tar.xz) | Complete exploratory date-only cohort and alternate source. |
| [linux-tags-only.tar.xz](archives/linux-tags-only.tar.xz) | Complete exploratory tags-only cohort and alternate source. |
| [linux-validation.tar.xz](archives/linux-validation.tar.xz) | Four passing test configurations and original failed baseline corpus, including 3,108 partial records. Production/tests match final; the earlier harness/runner are preserved. |
| [linux-interrupted.tar.xz](archives/linux-interrupted.tar.xz) | Incomplete 86/96 timing observations after disk exhaustion; excluded from timing conclusions. Its successful differential comparison is preserved. |
| [linux-dot-diagnostic.tar.xz](archives/linux-dot-diagnostic.tar.xz) | Sources and logs reproducing the directory-only `.` trap in baseline, candidate, and Linux Foundation alone, plus successful `.mkv` controls. Executables omitted. |
| [linux-toolchain-attempt.tar.xz](archives/linux-toolchain-attempt.tar.xz) | Initial compiler-version loader failure, before any test or timing. Excluded from qualification. |

Reproducible `build/` products and caches are omitted. Original product hashes
remain receipts. `verification-original.json` preserves each original complete
run's receipt; archived `verification.json` accurately reports zero present
binaries. The Linux copy-provenance receipt records that the final cohort's six
products were rehashed before omission. Absolute historical command paths remain
in the evidence and need not exist for offline verification.

## Offline recheck

From the repository root:

```sh
mkdir -p /tmp/illiquid-recognition-evidence
for archive in Benchmarks/MediaNameRecognition/evidence/archives/*.tar.xz; do
  tar -xJf "$archive" -C /tmp/illiquid-recognition-evidence
done
python3 Benchmarks/MediaNameRecognition/run.py --mode verify --output /tmp/illiquid-recognition-evidence/macos/component
python3 Benchmarks/MediaNameRecognition/run.py --mode verify --output /tmp/illiquid-recognition-evidence/linux
python3 Benchmarks/MediaNameRecognition/run.py --mode verify --output /tmp/illiquid-recognition-evidence/linux-date-only
python3 Benchmarks/MediaNameRecognition/run.py --mode verify --output /tmp/illiquid-recognition-evidence/linux-tags-only
python3 Benchmarks/MediaNameRecognition/evidence/audit.py \
  --evidence-root /tmp/illiquid-recognition-evidence \
  --repository-root "$PWD" \
  --output /tmp/illiquid-recognition-evidence/independent-audit.json
```

These commands verify saved evidence without compiling or timing the recognizer.
The normal verifier intentionally cannot certify the failed or incomplete
attempts. [audit.py](audit.py) and its retained
[independent-audit.json](independent-audit.json) independently check the Linux
cohorts without importing the runner: all 160 completed measurements against
command/stdout receipts, every wall/CPU summary, canonical bytes and checksums,
source/copy hashes, and the exhaustive date section against Python's Gregorian
calendar. That date section has 146,098 valid and 38,702 invalid-boundary records
across both field orders. The audit also explicitly checks the limitations of
the retained failed and interrupted runs.

The native source hashes, corpus bytes, four test logs, complete timing matrix,
and wall/CPU ratios were also independently reviewed against the downloaded
artifact. This evidence establishes the selected native correctness checks and
component performance; it does not quantify whole-player or scan throughput.
