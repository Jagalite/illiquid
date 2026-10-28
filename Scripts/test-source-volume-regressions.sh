#!/usr/bin/env bash
# Test actual volume-root selection without launching the player or mounting disks.
# macOS additionally compiles the real FSEvents adapter and runs plan integration.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/illiquid-source-volume.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Sources/IlliquidApp" "$work/Tests/IlliquidAppTests"
cp "$root/Sources/IlliquidApp/UI/SourceVolumeChangePolicy.swift" "$work/Sources/IlliquidApp/"
if [[ "$(uname -s)" == "Darwin" ]]; then
    mkdir -p "$work/Sources/IlliquidCore"
    cp "$root/Sources/IlliquidApp/UI/SourceFilesystemMonitor.swift" "$work/Sources/IlliquidApp/"
    cp "$root/Sources/IlliquidApp/UI/SourceFilesystemEventMailbox.swift" "$work/Sources/IlliquidApp/"
    cp "$root/Tests/IlliquidAppTests/SourceFilesystemLifecycleTests.swift" "$work/Tests/IlliquidAppTests/"
    cp "$root/Sources/IlliquidCore/Utilities/LifecyclePerformance.swift" "$work/Sources/IlliquidCore/"
    # Support the separate planner extraction when it is present after merging.
    if [[ -f "$root/Sources/IlliquidApp/UI/SourceFilesystemInvalidation.swift" ]]; then
        cp "$root/Sources/IlliquidApp/UI/SourceFilesystemInvalidation.swift" "$work/Sources/IlliquidApp/"
    fi
fi
cp "$root/Tests/IlliquidAppTests/SourceVolumeChangePolicyTests.swift" "$work/Tests/IlliquidAppTests/"
cat > "$work/Package.swift" <<'SWIFT'
// swift-tools-version: 6.1
import PackageDescription
#if os(macOS)
let nativeTargets: [Target] = [.target(name: "IlliquidCore")]
let appDependencies: [Target.Dependency] = ["IlliquidCore"]
#else
let nativeTargets: [Target] = []
let appDependencies: [Target.Dependency] = []
#endif
let package = Package(
    name: "IlliquidSourceVolumeRegressions",
    platforms: [.macOS("26.0")],
    targets: nativeTargets + [
        .target(name: "IlliquidApp", dependencies: appDependencies),
        .testTarget(name: "IlliquidAppTests", dependencies: ["IlliquidApp"])
    ]
)
SWIFT
swift test --package-path "$work" "$@"
