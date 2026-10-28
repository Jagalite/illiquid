#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
output="${1:?Usage: check-parity.sh OUTPUT_DIRECTORY}"
mkdir -p "$output"
output="$(cd "$output" && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/illiquid-key-parity.XXXXXX")"
trap 'rm -rf "$work"' EXIT
if [[ ! -f /Volumes/seed1/Projects/kyoto/kyoto.py ]]; then
    printf '%s\n' 'Kyoto is unavailable on this host; compiling standalone parity probes directly and serially.'
fi
result=0
for mode in debug release; do
    directory="$work/$mode"
    mkdir -p "$directory"
    optimization=-Onone
    if [[ "$mode" == release ]]; then optimization=-O; fi
    swiftc -swift-version 6 "$optimization" -whole-module-optimization -parse-as-library \
        -emit-module -emit-object -module-name IlliquidCore \
        -emit-module-path "$directory/IlliquidCore.swiftmodule" \
        "$root/Sources/IlliquidCore/Utilities/NormalizedFileURL.swift" -o "$directory/IlliquidCore.o"
    swiftc -swift-version 6 "$optimization" -parse-as-library -I "$directory" \
        "$root/Benchmarks/PersistenceKey/Parity.swift" "$directory/IlliquidCore.o" -o "$directory/parity"
    "$directory/parity" > "$output/parity-$mode.json" || result=1
    cat "$output/parity-$mode.json"
done
exit "$result"
