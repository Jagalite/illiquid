# Linux evidence

These are the exact outputs of the recorded four-pair experiment. Source
snapshots were losslessly packaged in `source-snapshots.tar.gz` to keep duplicated
production files out of the PR's textual diff. The entries match
`manifest.json`'s `evidence_sources_sha256` names and hashes. The benchmark runner
emits these files as an ordinary `sources/` directory for inspection; CI uploads
that expanded evidence directory.

The negative-control test package is similarly packaged in
`tests/negative-control.tar.gz`. No binaries or compiler caches are included.
All raw measurements, summaries, and test logs remain directly readable here.
