# Incomplete first final cohort — excluded from conclusions

This run completed six rounds in memory, but its saved measurement and command
files were missing two records when independently audited after execution:
`(srt-unicode-1000, baseline, round 4)` and
`(vtt-unicode-1000, candidate, round 4)`. The saved measurements therefore contain
130 records instead of 132. Both the original output and copied evidence had the
same omissions. The cause of the file preservation failure was not established.

The two affected summary distributions cannot be reproduced from these records.
Their missing values were not reconstructed from medians. This entire cohort is
excluded from the report's final performance table, including its nine complete
workloads. A fresh complete cohort was collected after making successful-run
output finalization atomic and adding saved-record integrity checks. This directory
retains the original incomplete evidence and exact runner for transparency;
`summary.json` here is the original unqualified in-memory summary, not a validated
six-sample report.
