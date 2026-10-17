#!/usr/bin/env bash
# Compile the actual Foundation-only budget and its tests without the macOS app
# dependency graph. Uses the Swift toolchain's bundled Testing module.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
configuration=debug
while (($#)); do
    case "$1" in
        --configuration)
            if (($# < 2)); then
                echo "--configuration requires debug or release" >&2
                exit 2
            fi
            configuration="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [--configuration debug|release]"
            echo "Set SUBTITLE_BUDGET_SOURCE to test an unchanged baseline source file."
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 2
            ;;
    esac
done
case "$configuration" in
    debug|release) ;;
    *) echo "Unsupported configuration: $configuration" >&2; exit 2 ;;
esac

budget_source="${SUBTITLE_BUDGET_SOURCE:-$root/Sources/IlliquidNativePlayback/Subtitles/SubtitleMemoryBudget.swift}"
work="$(mktemp -d "${TMPDIR:-/tmp}/illiquid-subtitle-budget-tests.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Sources/IlliquidNativePlayback" "$work/Tests/IlliquidNativePlaybackTests"
cp "$budget_source" "$work/Sources/IlliquidNativePlayback/SubtitleMemoryBudget.swift"
cp "$root/Tests/IlliquidNativePlaybackTests/SubtitleMemoryBudgetTests.swift" \
    "$work/Tests/IlliquidNativePlaybackTests/"
cat > "$work/Package.swift" <<'SWIFT'
// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "IlliquidSubtitleBudgetTests", targets: [
    .target(name: "IlliquidNativePlayback"),
    .testTarget(name: "IlliquidNativePlaybackTests", dependencies: ["IlliquidNativePlayback"]),
])
SWIFT
CLANG_MODULE_CACHE_PATH="$work/module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$work/module-cache" \
swift test --package-path "$work" --configuration "$configuration" \
    --cache-path "$work/cache" --config-path "$work/config" --security-path "$work/security" \
    --jobs 2
