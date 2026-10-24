# Rejected visitor-only memory hypothesis

These are preliminary smoke observations, not formal timing evidence. The
first candidate only streamed match candidates; final sorting still copied
`Array(result.keys)`. Complete source snapshots and output-parity evidence are
retained here. At 32,768 media inputs its broad-query sampled allocator high
watermark changed by only 864 bytes (19,429,552 to 19,428,688), and the dense
terminal case was unchanged. The peak moved to final result sorting. This did
not establish a useful complete-call memory improvement.

`manifest.json`, `observations.jsonl`, and `verification/` describe the initial
64/512-input smoke. `large-memory-smoke.jsonl` contains the subsequent 32,768-input
memory-only observations using those same two executables and source snapshots;
it is an extension of the smoke, not part of the manifest's 80-observation count.

The final candidate also removes the temporary result-key array; its evidence
must be reported separately. Small timing smoke used one measured association
per process during concurrent builds and is too noisy for conclusions.
