#!/usr/bin/env bash
# Exercise the real planner without AppKit or the native dependency graph.
# Only extract the existing pure declarations; do not reimplement their logic.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/illiquid-filesystem-loss.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Sources/IlliquidApp" "$work/Tests/IlliquidAppTests"
python3 - "$root" "$work/Sources/IlliquidApp/Planner.swift" <<'PY'
import pathlib
import sys
root = pathlib.Path(sys.argv[1])
# The concurrent root-routing PRs move these declarations to this file.
extracted = root / "Sources/IlliquidApp/UI/SourceFilesystemInvalidation.swift"
if extracted.exists():
    source = extracted.read_text(encoding="utf-8")
else:
    source = (root / "Sources/IlliquidApp/UI/SourceFilesystemMonitor.swift").read_text(encoding="utf-8")
    start = source.index("struct SourceFilesystemEvent:")
    end = source.index("final class SourceFilesystemMonitor:")
    source = "import Foundation\n\n" + source[start:end]
pathlib.Path(sys.argv[2]).write_text(source, encoding="utf-8")
PY
for file in SourceFilesystemMonitorTests SourceFilesystemEventLossTests SourceFilesystemEventBufferTests; do
    cp "$root/Tests/IlliquidAppTests/$file.swift" "$work/Tests/IlliquidAppTests/"
done
cat > "$work/Package.swift" <<'SWIFT'
// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "IlliquidFilesystemEventLossRegressions", targets: [
    .target(name: "IlliquidApp"),
    .testTarget(name: "IlliquidAppTests", dependencies: ["IlliquidApp"])
])
SWIFT
swift test --package-path "$work" "$@"
