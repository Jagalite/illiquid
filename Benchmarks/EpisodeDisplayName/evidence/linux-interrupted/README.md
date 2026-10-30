# Interrupted local attempts

These two attempts are retained for provenance and are excluded from the final timing statistics.

- `no-space.tar.gz`: all four 40-test qualification runs and full UTF-8 parity passed; disk exhaustion interrupted timing after 29 observations. The empty original `failure.json` and last log are preserved. `aborted.json` records the infrastructure failure. Its qualified executable hashes and test evidence are reused by the recovered campaign.
- `missing-compiler.tar.gz`: a clean retry stopped when the shared Swift compiler disappeared. Its failure and available test logs are preserved.

Each archive contains all run evidence except disposable build/cache directories. `manifest.json` records every retained file and archive hash. No observations from these attempts are combined with the fresh recovered campaign.
