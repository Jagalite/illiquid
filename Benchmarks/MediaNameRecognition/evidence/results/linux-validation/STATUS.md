# Tests passed; the original corpus attempt failed

All four baseline/candidate debug/release invocations passed, each reporting
12 tests in one suite. `test-results.json` and the four complete test logs retain
those results.

The later `corpus-baseline` process exited with signal 4 on the directory-only
dot case. Its command receipt, stderr, and partial corpus remain here. The
separate `../linux-dot-diagnostic/` probe reproduces the trap in both variants
and directly in Linux Foundation. The completed final corpus is in `../linux/`.

This directory is **not an overall verified run** and has no timing result.
The production and test sources match the final experiment. Its earlier harness
and runner are preserved as they were executed.
