# Initial UTF8View experiment

Measured commit: `7bcb4d27b756495579bfef2717faf99f65c76e40`.

[Run 40639439495, Linux job 122653885666](https://github.com/Jagalite/illiquid/actions/runs/40639439495/job/122653885666).

This first candidate used `text.utf8.contains(where:)`. It passed 69 tests in
each baseline/candidate debug/release run and all 838 differential outputs
matched. Ordinary ASCII documents improved by 31.6–37.3%, and 4–120 KB ASCII plots
by 82.7–89.7%. However, 32 KB prefixes followed by `!` or Unicode regressed by
7.6% and 6.0%, respectively.

These observations motivated a contiguous-byte scan using `String.withUTF8`.
They are retained as a separate, superseded experiment and must not be pooled
with measurements of the revised candidate. Native macOS was still queued
before the follow-up replaced this run.
