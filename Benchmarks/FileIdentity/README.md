# File identity path research

This experiment avoids URL reconstruction for ordinary ASCII persistence keys.
NormalizedFileURL.persistenceKey(for:) retains local-authority validation and
lexical standardization. Non-ASCII names and unusual paths keep the original
URL construction to preserve Foundation's exact persisted byte spelling.
The URL-returning normalize and filesystem-resolving preparation APIs are unchanged.

The frozen baseline helper is the exact Git blob from main at
ea2ff568237e2667f7b1aeee67b11a44ebe95b72. Its manifest is checked before any
compilation. All other production files are identical between variants and
copied from the current checkout; their hashes and exact staged sources are
retained in each run.

## Reproduce

Use Python 3.10+ and Swift 6.1+; no package dependencies or media SDK are needed.
Follow the repository's Kyoto coordination rule when that queue is available.
The runner keeps builds serial and gives every test configuration its own package.

~~~sh
python3 Benchmarks/FileIdentity/run.py --mode all --pairs 8 --target-ms 75 \
  --output /tmp/illiquid-file-identity
# A specific workload, or correctness only:
python3 Benchmarks/FileIdentity/run.py --mode benchmark --pairs 2 \
  --case lookup-1000 --output /tmp/illiquid-file-identity-smoke
python3 Benchmarks/FileIdentity/run.py --mode tests \
  --output /tmp/illiquid-file-identity-tests
~~~

Output must be a new or empty directory. Tests run on both implementations in
debug and release, including local-source validation and the existing playlist,
deduplication, natural-ordering, and selection regressions.

## Measurement

The actual production sources compile into a separate optimized dynamic library.
The common driver imports that module without cross-module optimization, keeping
the public calls observable. It checks results before and after timing, compares
key UTF-8 bytes with the unchanged normalize(url)?.path, verifies complete
deduplicated items, and requires matching receipts and sinks across variants.

Thirteen workloads cover ASCII, decomposed Unicode, relative, escaped, long and
rejected URLs; same-file comparisons; actual FolderPlaylist.index(of:) lookups
with 100, 1,000 and 10,000 entries; and actual playlist deduplication of 1,000 and
10,000 unique entries plus 10% duplicates. The lookup cases equally mix a final
item hit and a miss. The unchanged URL-returning normalizer and rejected inputs
are controls.

Each workload calibrates one shared iteration count until both variants take at
least the requested target time. All calibration trials are retained. Measurement
uses eight fresh processes per variant with alternating baseline-first and
candidate-first order. Fixture creation, sorting, verification and warmup are
outside the timer. A small result observer remains inside both timings.

Results retain wall and process CPU time, all observations, ranges and paired
reductions, source/compiler/binary identities, command logs and test receipts.
The runner re-reads the persisted observation set and rejects missing rows or
parity mismatches. CI gates correctness and completed measurement, not a noisy
timing threshold.

These are component timings. They do not measure folder I/O, full folder-open
latency, UI responsiveness, decoding, whole-player CPU, or energy use. The native
macOS workflow provides the relevant Foundation implementation; results from a
different operating system must be labeled separately.

## Results

Research in progress. Only a run that passes compatibility checks and demonstrates
a repeatable improvement can support a production PR. Native results and their
provenance will be recorded here after qualification.
