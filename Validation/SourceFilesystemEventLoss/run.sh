#!/usr/bin/env bash
# Verify event-loss recovery and preserve baseline behavior outside its scope.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/illiquid-filesystem-loss-coverage.XXXXXX")"
trap 'rm -rf "$work"' EXIT
baseline=8c3cc3d4008d5d1b8d436bcf2d51d891382b6548
# An exported baseline may be used offline; its Git blob ID is always verified.
if [[ -n "${ILLIQUID_FILESYSTEM_BASELINE_FILE:-}" ]]; then
    cp "$ILLIQUID_FILESYSTEM_BASELINE_FILE" "$work/monitor.swift"
else
    git -C "$root" show "$baseline:Sources/IlliquidApp/UI/SourceFilesystemMonitor.swift" > "$work/monitor.swift"
fi
python3 - "$work" "$root" <<'PY'
import hashlib
import pathlib
import sys
work, root = map(pathlib.Path, sys.argv[1:])
source = (work / "monitor.swift").read_bytes()
blob = hashlib.sha1(b"blob " + str(len(source)).encode() + b"\0" + source).hexdigest()
if blob != "5d72b86349b8655e7188cd4f551ffd7816637abf":
    raise SystemExit("Unexpected baseline monitor blob")
def declarations(text):
    start = text.index("struct SourceFilesystemEvent:")
    end = text.index("final class SourceFilesystemMonitor:")
    return "import Foundation\n\n" + text[start:end]
baseline = declarations(source.decode("utf-8"))
(work / "BaselinePlanner.swift").write_text(
    baseline.replace("SourceFilesystem", "BaselineSourceFilesystem"), encoding="utf-8")
extracted = root / "Sources/IlliquidApp/UI/SourceFilesystemInvalidation.swift"
if extracted.exists():
    candidate = extracted.read_text(encoding="utf-8")
else:
    candidate = declarations((root / "Sources/IlliquidApp/UI/SourceFilesystemMonitor.swift").read_text(encoding="utf-8"))
(work / "Planner.swift").write_text(candidate, encoding="utf-8")
PY
swiftc -O -warnings-as-errors \
    "$work/BaselinePlanner.swift" "$work/Planner.swift" \
    "$root/Validation/SourceFilesystemEventLoss/ValidatePlanner.swift" \
    -o "$work/validate-planner"
"$work/validate-planner"
