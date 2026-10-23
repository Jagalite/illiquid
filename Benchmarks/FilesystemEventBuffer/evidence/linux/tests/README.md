# Linux test receipts

Debug and release focused runs passed 30 tests in three suites. The negative
control intentionally failed two selected overflow regressions against the
original unbounded array behavior. The adapter package is included in `negative-control.tar.gz` without its
build products; its filter and flags are recorded in `manifest.json`.

The focused tests preceded a comment-only wording correction in the production
buffer. `SourceFilesystemInvalidation-tested.swift` preserves the exact tested
source and matches its manifest hash. The final production source is preserved
as `candidate-SourceFilesystemInvalidation.swift` in `../source-snapshots.tar.gz` and was compiled
and exercised by the recorded memory/parity benchmark. The only difference is
the two-line comment about dropping this buffer's ownership references.
