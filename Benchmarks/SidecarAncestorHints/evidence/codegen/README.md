# Ancestor-plan code-generation inspection

This is a static inspection of the already-built Linux x86_64 release modules.
It compiles and executes no Illiquid code. Candidate A stores the merged hints
inside a value-type path plan. Candidate B holds the same immutable fields in a
private final reference class. The baseline has the original value-type plan
without cached hints.

Reproduce after rebuilding the original A and B output trees (`linux-full` and
`reference-tests`) from their recorded source commits and toolchain. The compiled
binaries are intentionally not committed. Supply the directory containing those
trees and write a new receipt:

```sh
python3 inspect.py --research-root /path/to/ancestor-hints-research \
  --output /tmp/ancestor-plan-codegen.json
```

The script runs `objdump -d --no-show-raw-insn --disassemble=SYMBOL` and `nm -S`
on each module. `receipt.json` records the exact argument arrays, tool versions,
binary SHA-256 hashes, source receipts, symbol sizes, and supporting disassembly
excerpts. Each binary hash must match its benchmark build receipt. The script
also checks whether the baseline binary, production source hashes, and complete
`recognize` disassembly match the original candidate A run. The overall baseline
module hashes differ between builds; the production hashes and this function's
instruction disassembly are identical. The receipt retains that distinction.

| Static property of `MediaSidecarReader.recognize` | Baseline | A: value plan | B: reference plan |
| --- | ---: | ---: | ---: |
| Disassembled instruction lines | 2,182 | 2,374 | 2,276 |
| Prologue stack subtraction, bytes | 5,232 | 5,968 | 5,200 |
| Direct `memcpy` call sites | 1 | 7 | 1 |

Candidate A has six additional `memcpy` call sites with a 168-byte size argument
for the enlarged plan and calls to optional-plan value helpers. Candidate B has
no plan value-witness or optional-plan helper calls in `recognize`; those symbols
also disappear from the module. Its sole remaining 168-byte `memcpy` occurs
immediately before `RecognizedMediaName.applying`, as it does in the baseline.
That remaining copy handles the recognized result value, not the ancestor plan.

Candidate B introduces one direct `swift_allocObject` call site at the existing
plan-publication point. The preceding instructions reference `AncestorPathPlan`
class metadata and request 184 bytes (168 bytes of fields plus the object header).
The plan's five fields remain immutable. A local reference keeps the matched
snapshot alive through cancellation callbacks, including callbacks that reenter
recognition and replace the reader's current cached plan.

These observations support the intended mechanism: retaining one reference
avoids copying and retaining the large plan payload at each value-copy site.
They do **not** prove that the earlier NFO-only timing difference was caused by
these copies, or establish a timing benefit for B. Static counts include branches
that may not execute in a given scan. The stack figure excludes register saves
and callees. The 184-byte allocation request excludes allocator overhead. The
extra allocation occurs on plan publication and must be assessed in timing
controls with frequent parent changes.
