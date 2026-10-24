# Local execution environment diagnostics

The first full local attempt built both optimized executables and passed baseline
qualification, but candidate qualification terminated with SIGILL before any
performance observation was collected. Its complete command receipts, build
logs, qualification logs and manifest are preserved here. The stderr backtrace
contains a `/proc/<pid>/stat` path and no named harness assertion.

Diagnostic reruns used the exact same already-built candidate executable (hash
in `receipt-index.json`). The sandboxed per-scenario reruns reproduced the crash
for explicit cancellation while other scenarios and a combined qualification
passed. Six further sandboxed qualification attempts, with the diagnostic
`SWIFT_BACKTRACE=disable` environment value recorded in their receipts, produced
one crash and five successes. This setting did not provide an underlying error
message. All observations from these diagnostic attempts are preserved; none
were included in the performance matrix.

The tool's explicit approved `require_escalated` execution path then ran the same
candidate executable through qualification six consecutive times successfully.
A fresh, complete six-pair matrix was built and run through that same approved
path with unchanged production, Swift harness, template, C helper and runner
inputs. All 144 observations and both six-scenario qualifications passed; those
receipts are in `../linux/`. Binary paths differ between the fresh build trees,
and both binary hashes are recorded rather than assuming identical executable
bytes across rebuilds.

These observations support an execution-environment-dependent failure. A sandbox
process-statistics issue is suspected; the precise syscall or library root cause
has not been established. The failed attempt was retained, not selectively
filtered into the successful matrix. Its performance observation count is zero.
