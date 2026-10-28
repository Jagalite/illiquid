#!/usr/bin/env bash
# Test volume-root selection and bounded event delivery without launching the player.
# macOS additionally compiles the real FSEvents adapter and runs plan integration.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/illiquid-source-volume.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Sources/IlliquidApp" "$work/Tests/IlliquidAppTests"
cp "$root/Sources/IlliquidApp/UI/SourceVolumeChangePolicy.swift" "$work/Sources/IlliquidApp/"
cp "$root/Sources/IlliquidApp/UI/SourceFilesystemInvalidation.swift" "$work/Sources/IlliquidApp/"
cp "$root/Sources/IlliquidApp/UI/SourceFilesystemEventDelivery.swift" "$work/Sources/IlliquidApp/"
cp "$root/Tests/IlliquidAppTests/SourceFilesystemEventDeliveryTests.swift" "$work/Tests/IlliquidAppTests/"
if [[ "$(uname -s)" == "Darwin" ]]; then
    mkdir -p "$work/Sources/IlliquidCore"
    cp "$root/Sources/IlliquidApp/UI/SourceFilesystemMonitor.swift" "$work/Sources/IlliquidApp/"
    cp "$root/Tests/IlliquidAppTests/SourceFilesystemLifecycleTests.swift" "$work/Tests/IlliquidAppTests/"
    cp "$root/Sources/IlliquidCore/Utilities/LifecyclePerformance.swift" "$work/Sources/IlliquidCore/"
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
python3 - "$work" "$@" <<'PY'
import json
from pathlib import Path
import subprocess
import sys

command = ['swift', 'test', '--package-path', sys.argv[1], *sys.argv[2:]]
queue = Path('/Volumes/seed1/Projects/kyoto/kyoto.py')
if queue.is_file():
    cli = [sys.executable, str(queue)]
    submitted = subprocess.check_output([*cli, 'submit', '--', *command], text=True)
    print(submitted, flush=True)
    job_id = str(json.loads(submitted)['id'])
    subprocess.run([*cli, 'show', job_id], check=True)
    result = subprocess.run([*cli, 'wait', job_id])
    subprocess.run([*cli, 'logs', job_id], check=True)
    sys.exit(result.returncode)
print('Shared Kyoto queue is unavailable; compiling and testing the isolated '
      'filesystem components directly.', flush=True)
subprocess.run(command, check=True)
PY
