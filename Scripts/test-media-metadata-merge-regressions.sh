#!/usr/bin/env bash
# Stage the exact Foundation-only metadata sources, without native playback.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
hints_source="${ILLIQUID_METADATA_HINTS_SOURCE:-$root/Sources/IlliquidCore/MediaLibrary/MediaMetadataHints.swift}"
if [[ "${1:-}" == "--hints-source" ]]; then
    if [[ $# -lt 2 ]]; then
        echo "--hints-source requires a Swift source file" >&2
        exit 2
    fi
    hints_source="$2"
    shift 2
fi
if [[ ! -f "$hints_source" ]]; then
    echo "Metadata hints source does not exist: $hints_source" >&2
    exit 2
fi
work="$(mktemp -d "${TMPDIR:-/tmp}/illiquid-metadata-merge.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Sources/IlliquidCore" "$work/Tests/IlliquidCoreTests"
for file in MediaNameRecognition PlexMatchHints; do
    cp "$root/Sources/IlliquidCore/MediaLibrary/$file.swift" "$work/Sources/IlliquidCore/"
done
cp "$hints_source" "$work/Sources/IlliquidCore/MediaMetadataHints.swift"
for file in MediaMetadataMergeTests PlexMatchHintsRegressionTests; do
    cp "$root/Tests/IlliquidCoreTests/$file.swift" "$work/Tests/IlliquidCoreTests/"
done
cat > "$work/Package.swift" <<'SWIFT'
// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "IlliquidMediaMetadataMergeRegressions",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "IlliquidCore"),
        .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"]),
    ]
)
SWIFT
swift test --package-path "$work" "$@"
