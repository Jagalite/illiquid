#!/usr/bin/env bash
# Exercise the actual event-routing code and repository tests without the player.
# macOS also compiles the real FSEvents adapter and its real logging dependency.
# Tests do not start FSEvents, mount a volume, or launch the native application.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/illiquid-source-filesystem.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Sources/IlliquidApp" "$work/Tests/IlliquidAppTests"
cp "$root/Sources/IlliquidApp/UI/SourceFilesystemInvalidation.swift" "$work/Sources/IlliquidApp/"
if [[ "$(uname -s)" == "Darwin" ]]; then
    mkdir -p "$work/Sources/IlliquidCore"
    cp "$root/Sources/IlliquidApp/UI/SourceFilesystemMonitor.swift" "$work/Sources/IlliquidApp/"
    cp "$root/Sources/IlliquidCore/Utilities/LifecyclePerformance.swift" "$work/Sources/IlliquidCore/"
fi
for test in SourceFilesystemMonitorTests SourceFilesystemRootInvalidationTests; do
    cp "$root/Tests/IlliquidAppTests/$test.swift" "$work/Tests/IlliquidAppTests/"
done
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
    name: "IlliquidSourceFilesystemRegressions",
    platforms: [.macOS("26.0")],
    targets: nativeTargets + [
        .target(name: "IlliquidApp", dependencies: appDependencies),
        .testTarget(name: "IlliquidAppTests", dependencies: ["IlliquidApp"])
    ]
)
SWIFT
swift test --package-path "$work" "$@"
