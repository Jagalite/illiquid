#!/usr/bin/env bash
# Run the real media-identification sources without the macOS app dependency graph.
# Linux adjusts only FoundationXML/Glibc imports in temporary copies; no logic is replaced.
# Set ILLIQUID_NFO_SOURCE_REF to test an older source revision against today's tests.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/illiquid-nfo-regressions.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Sources/IlliquidCore" "$work/Tests/IlliquidCoreTests"
for file in MediaMetadataHints MediaNameRecognition MediaSidecarReader NFOMetadataHints PlexMatchHints; do
    path="Sources/IlliquidCore/MediaLibrary/$file.swift"
    if [[ -n "${ILLIQUID_NFO_SOURCE_REF:-}" ]]; then
        git -C "$root" show "$ILLIQUID_NFO_SOURCE_REF:$path" > "$work/Sources/IlliquidCore/$file.swift"
    else
        cp "$root/$path" "$work/Sources/IlliquidCore/"
    fi
done
for file in MediaNameRecognitionTests MediaSidecarTests NFOEpisodeScopeRegressionTests; do
    cp "$root/Tests/IlliquidCoreTests/$file.swift" "$work/Tests/IlliquidCoreTests/"
done
if [[ "$(uname -s)" == "Linux" ]]; then
    parser="$work/Sources/IlliquidCore/NFOMetadataHints.swift"
    { printf 'import FoundationXML\n'; cat "$parser"; } > "$parser.tmp"
    mv "$parser.tmp" "$parser"
    reader="$work/Sources/IlliquidCore/MediaSidecarReader.swift"
    sed 's/^import Darwin$/import Glibc/' "$reader" > "$reader.tmp"
    mv "$reader.tmp" "$reader"
fi
cat > "$work/Package.swift" <<'SWIFT'
// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "IlliquidNFOMetadataRegressions", targets: [
    .target(name: "IlliquidCore"),
    .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"])
])
SWIFT
swift test --package-path "$work" "$@"
