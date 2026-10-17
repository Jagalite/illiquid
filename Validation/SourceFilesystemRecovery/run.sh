#!/usr/bin/env bash
# Compare the production planner with the exact pre-fix implementation, then
# exercise stream-loss, path containment, and batch-order invariants.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/illiquid-filesystem-coverage.XXXXXX")"
trap 'rm -rf "$work"' EXIT
baseline=8c3cc3d4008d5d1b8d436bcf2d51d891382b6548
# An exported baseline may be used offline; its Git blob ID is always verified.
if [[ -n "${ILLIQUID_FILESYSTEM_BASELINE_FILE:-}" ]]; then
    cp "$ILLIQUID_FILESYSTEM_BASELINE_FILE" "$work/monitor.swift"
else
    git -C "$root" show "$baseline:Sources/IlliquidApp/UI/SourceFilesystemMonitor.swift" > "$work/monitor.swift"
fi
python3 - "$work" <<'PY'
import hashlib
import pathlib
import sys
work = pathlib.Path(sys.argv[1])
source = (work / "monitor.swift").read_bytes()
blob = hashlib.sha1(b"blob " + str(len(source)).encode() + b"\0" + source).hexdigest()
if blob != "5d72b86349b8655e7188cd4f551ffd7816637abf":
    raise SystemExit("Unexpected baseline monitor blob")
text = source.decode("utf-8")
start = text.index("struct SourceFilesystemEvent:")
end = text.index("final class SourceFilesystemMonitor:")
policy = "import Foundation\n\n" + text[start:end]
(work / "BaselinePlanner.swift").write_text(
    policy.replace("SourceFilesystem", "BaselineSourceFilesystem"), encoding="utf-8")
PY
swiftc -O -warnings-as-errors \
    "$work/BaselinePlanner.swift" \
    "$root/Sources/IlliquidApp/UI/SourceFilesystemInvalidationPlanner.swift" \
    "$root/Validation/SourceFilesystemRecovery/ValidatePlanner.swift" \
    -o "$work/validate-planner"
"$work/validate-planner"
