# Recovery EOF consolidation

Canonical source: PR172 at c1ef6aff6060ad35decbc6dce0c224164be941a2.
Production FFmpegPacket and MediaSession remain byte-identical: releaseAfterDrain
runs after actual successful drain, with its generation guard.

PR175 (53782c9688bf7edb7e41b780c6de3e79d75108ff) contributes native session
ownership coverage and the renamed VideoRecoveryGOPSequencingTests. Its sequencing
helper is test-only: failure/cancellation/seek simulations do not establish that
MediaSession calls a production hook. The external AVBufferRef test uses an
explicit optional binding for compatibility with nonoptional Clang imports.
The superseded portable harness and production API remain archived, not active.
PR202 (5af8eea6ddd786765f2aea4ad10bbb42085c5360) contributes its decoded-output
tests and exact-production-loop harness, including negative controls.

The archive preserves original changed-file bytes, hashes, API metadata, branch
history and patches, and failed check logs. These receipts belong to their
original heads and are not evidence for this consolidated patch. Archived sources
and workflows are reference material, not build inputs or current CI jobs.

The two historical auxiliary-font/PGS comparisons retain strict defaults and
manual workflows. PR/push checks explicitly select --current-support-regression:
only FFmpegPacket support is replaced identically in both arms. Historical
baseline and current target focal sources stay independently pinned, with target
identity checked against the canonical commit. Other support drift still fails.
This mode provides regression evidence, never historical performance evidence.
Auxiliary runs every fixture/input-count/default-policy memory pair and all
metadata/packet/seek/font checks, with no timing cohort. PGS executes its complete
workload verification cycles and edge/error checks, with no timing cohort.

The native test wrapper adds pkg-config directories from the already selected
pinned SDK library paths so CLibass headers resolve; shared SDK selection and
SDK contents are unchanged. EOF baseline staging temporarily excludes candidate
recovery test files and restores them after the baseline run.

Validation of this patch so far is noncompiling: Python AST and bash syntax,
exact-base git apply check, and executed Python source-guard positive/negative
controls. Native compilation, executed Swift tests, allocation comparisons,
and decoded output remain unqualified pending the parent-owned Kyoto runs.
