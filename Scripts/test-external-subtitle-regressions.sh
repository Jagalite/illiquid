#!/usr/bin/env bash
# Exercise the real text converter without resolving macOS playback SDKs.
# Native file decoding, byte limits, and error mapping run in the app test suite.
set -euo pipefail
# An optional leading --baseline-ref selects the exact converter to test while
# keeping the working-tree regression tests identical for both implementations.
subtitle_source_ref=""
if [[ "${1:-}" == "--baseline-ref" ]]; then
    [[ $# -ge 2 && -n "$2" ]] || { echo "--baseline-ref requires a Git revision" >&2; exit 2; }
    subtitle_source_ref="$2"
    shift 2
fi
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/illiquid-subtitle-regressions.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Sources/IlliquidNativePlayback" "$work/Tests/IlliquidNativePlaybackTests"
if [[ -n "$subtitle_source_ref" ]]; then
    subtitle_source_ref="$(git -C "$root" rev-parse --verify "$subtitle_source_ref^{commit}")"
    git -C "$root" show "$subtitle_source_ref:Sources/IlliquidNativePlayback/Subtitles/ExternalTextSubtitleConverter.swift" \
        > "$work/Sources/IlliquidNativePlayback/ExternalTextSubtitleConverter.swift"
else
    cp "$root/Sources/IlliquidNativePlayback/Subtitles/ExternalTextSubtitleConverter.swift" \
        "$work/Sources/IlliquidNativePlayback/"
fi
cp "$root/Tests/IlliquidNativePlaybackTests/ExternalTextSubtitleConverterTests.swift" \
    "$root/Tests/IlliquidNativePlaybackTests/ExternalSubtitleEscapingTests.swift" \
    "$root/Tests/IlliquidNativePlaybackTests/SubtitleCueStreamingTests.swift" \
    "$work/Tests/IlliquidNativePlaybackTests/"
cat > "$work/Package.swift" <<'SWIFT'
// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "IlliquidExternalSubtitleRegressions", platforms: [.macOS("26.0")], targets: [
    .target(name: "IlliquidNativePlayback"),
    .testTarget(name: "IlliquidNativePlaybackTests", dependencies: ["IlliquidNativePlayback"])
])
SWIFT
swift test --package-path "$work" "$@"
