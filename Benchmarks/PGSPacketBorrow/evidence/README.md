# Native PGS packet-borrow evidence

The [report](../../../Documentation/PGS_PACKET_BORROW_PERFORMANCE.md) explains the
result, test coverage, measurement method, and limits. Each compressed bundle is
the exact review receipt emitted by its GitHub Actions job, not a reconstructed
or filtered set of measurements. Corresponding provenance files record the
source revision, run URL, disposition, and compressed SHA-256.

## Qualification attempts

| Bundle | Run | Disposition |
| --- | --- | --- |
| `screening-short-samples.json.gz` | [39844852284](https://github.com/Jagalite/illiquid/actions/runs/39844852284) | Original 80 ms target; correctness passed, but 17 observations failed the 60 ms duration requirement. Retained and excluded from final reported timings. |
| `superseded-before-native-tests.json.gz` | [39845375893](https://github.com/Jagalite/illiquid/actions/runs/39845375893) | Fixture-update run using the original target; benchmark completed as the duration update superseded the workflow. Native tests did not run. Retained and excluded from final reported timings. |
| `qualified-timing-fixture-setup-failed.json.gz` | [39845803043](https://github.com/Jagalite/illiquid/actions/runs/39845803043) | All benchmark gates passed at the 240 ms target. Fixture setup then stopped because the pinned SDK lacks `ffprobe`; native tests did not run. Retained and excluded from final reported timings. |
| `qualified-timing-test-compile-failed.json.gz` | [39846875975](https://github.com/Jagalite/illiquid/actions/runs/39846875975) | Benchmark and production compilation passed. A new test needed its throwing parse separated from the `#require` macro. Latest reported component timings; integration remains pending after the test-only fix. |

The readable `measured-*.json` files summarize the latest component cohort.
`native-test-build.log` preserves the subsequent test compilation failure.
[Run 39851029701](https://github.com/Jagalite/illiquid/actions/runs/39851029701)
is the pending native integration rerun. There is no native test-pass claim.
No observations from any completed cohort are discarded.

## Read a bundle

Bundles are gzip-compressed JSON dictionaries mapping relative receipt names to
their original text. They include full baseline/candidate correctness traces,
build receipts, compiler logs, calibration trials, every raw timed observation,
normalized summaries, and process command receipts. A `completion.json` exists
only when that benchmark invocation reaches its completion checks. The latest
bundle also includes the native test build log, including its compilation error.

For example, inspect a retained cohort without extracting executable files:

```sh
python3 - <<'PY'
from pathlib import Path
import gzip, json
path = Path('Benchmarks/PGSPacketBorrow/evidence/qualified-timing-test-compile-failed.json.gz')
receipts = json.loads(gzip.decompress(path.read_bytes()))
print('\n'.join(sorted(receipts)))
print(receipts['benchmark/parity.json'])
print(receipts['benchmark/summary.json'])
PY
```

The corresponding `benchmark/build-receipt.json` identifies exact Git revisions,
all compiled production source hashes, compiler/SDK/library hashes, flags,
hardware, platform, and executable hashes. `benchmark/measurements.jsonl` and
`benchmark/commands.json` retain observation order, iterations, checksums, raw
durations, and process stdout receipts for independent recomputation.
