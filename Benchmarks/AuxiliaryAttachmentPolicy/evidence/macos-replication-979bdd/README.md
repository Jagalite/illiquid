# Native replication at 979bdd3

See the [research report](../../../../Documentation/AUXILIARY_FONT_MACOS_REPLICATION.md)
for all measured scenarios, the physical-memory regressions, and exact-source
qualification limits.

This evidence is from [run 40101300598](https://github.com/Jagalite/illiquid/actions/runs/40101300598) against baseline `6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635`
and candidate `979bdd34a93af1c564d505b1b6a4f6b12de27379`. It is an independent Boolean-option implementation,
not an execution of PR #101's policy-enum implementation. The raw cohort contains
228 observations. Each Debug and Release run passed 73 test functions and
explicitly skipped ten. All 20 cases in the new auxiliary suite executed.

`summary.json` is an exact copy from the verified Actions artifact;
`observations.jsonl.gz` decompresses to its exact complete raw observations.
`scalar-observations.jsonl` exposes every process's memory/timing samples and
copied-byte counts without repeating the large packet/metadata records.
The compact log bundle contains the same original bytes for those files and
the other readable JSON receipts. `full-text-receipts.json.gz` is a gzip-compressed
JSON object mapping original relative paths to their exact UTF-8 text. It retains
all text artifact files plus the immutable workflow and new test source. Binary
build outputs are omitted and their hashes are retained in `index.json`.

Positive `median_paired_reduction` values in the original summary mean baseline
minus candidate. In particular, the negative resident/footprint reductions in
the larger fixtures are real measured increases, not missing data. No adverse
observations were discarded. After-release readings follow validation work and
are diagnostic rather than clean deallocation measurements.
