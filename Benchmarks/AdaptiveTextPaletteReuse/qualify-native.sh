#!/usr/bin/env bash
set -euo pipefail

output=${1:?Usage: qualify-native.sh OUTPUT [--current-support-regression-only]}
mode=${2:-}
if (( $# > 2 )) || [[ -n "$mode" && "$mode" != --current-support-regression-only ]]; then
    echo 'Invalid qualification mode' >&2
    exit 2
fi
support_args=()
if [[ -n "$mode" ]]; then
    support_args+=("$mode")
fi
python3 Benchmarks/AdaptiveTextPaletteReuse/test_source_policy.py
test "$(uname -s)" = Darwin
mkdir -p "$output"
git rev-parse HEAD > "$output/revision.txt"
python3 Benchmarks/AdaptiveTextPaletteReuse/run.py "${support_args[@]}" --tests-only --output "$output/tests"
if [[ -n "$mode" ]]; then
    python3 Benchmarks/AdaptiveTextPaletteReuse/run.py "$mode" --receipts-only --output "$output/receipts"
else
    python3 Benchmarks/AdaptiveTextPaletteReuse/run.py --output "$output/benchmark" \
        --rounds 6 --target-ms 100
fi

if ! xcrun -sdk macosx metal --version; then
    xcodebuild -downloadComponent MetalToolchain
fi
python3 Scripts/verify-corresponding-source.py DependencySources
if [[ ${GITHUB_ACTIONS:-} == true && ${RUNNER_ENVIRONMENT:-} == github-hosted ]]; then
    python3 Scripts/install-ci-native-sdk.py
    # GITHUB_ENV normally takes effect in the following workflow step. This
    # script builds in the same step; import only the installer's two settings
    # without evaluating shell text.
    while IFS='=' read -r key value; do
        case "$key" in
            PKG_CONFIG_PATH|PKG_CONFIG_LIBDIR) export "$key=$value" ;;
        esac
    done < "$GITHUB_ENV"
else
    echo 'Using the existing reviewed native SDK; the test runner verifies its availability.'
fi

# This compiles the real application modules and tests, including SwiftUI,
# AppKit, playback dependencies, and the unextracted PlayerTheme.swift.
native_status=0
bash Scripts/tests/run-native-swift-tests.sh --build --jobs 2 --filter \
    'AdaptiveTextPaletteReuseTests|AdaptiveTextLegibilityPerformanceTests|AdaptiveTextLegibilityTests|AdaptiveRainbowTextColorTests|AdaptiveTextColorAuditTests' \
    2>&1 | tee "$output/native-app-tests.log" || native_status=$?

# Retain the native runner's machine-readable receipt and require every new
# regression to execute, as well as its existing nonzero-test/failure guard.
receipt_status=0
python3 - "$output" <<'PY' || receipt_status=$?
from pathlib import Path
import json, re, shutil, sys
import xml.etree.ElementTree as ET

output = Path(sys.argv[1])
log = (output / 'native-app-tests.log').read_text()
receipts = re.findall(r'^native-swift-tests: receipt=(.+)$', log, re.MULTILINE)
if len(receipts) != 1:
    raise SystemExit('Expected one native application test receipt')
report = output / 'native-app-tests.xml'
shutil.copyfile(receipts[0], report)
root = ET.parse(report).getroot()
executed = [case for case in root.findall('.//testcase')
            if case.find('skipped') is None and 'time' in case.attrib]
names = [case.attrib.get('name', '') for case in executed]
required = {
    'uncachedStylesMatchTwoContextReferenceAcrossModesPalettesAndRegions',
    'revisionsAndStyleHitsPreservePreviousColorHistory',
    'generationResetAndStoreSwitchDiscardCachedStylesAndHistory',
    'existingComponentsAndFullStyleCacheRetainTheirFastPathBehavior',
    'cacheOverflowPreservesUncachedAndHistoryResults',
    'staticThemesStaticModeAndMissingSamplesKeepFallbacks',
}
missing = sorted(name for name in required if not any(name in actual for actual in names))
failed = root.findall('.//failure') + root.findall('.//error')
result = {'executed_tests': len(executed), 'required_palette_tests': len(required),
          'executed_test_names': names, 'missing_palette_tests': missing, 'failures': len(failed)}
(output / 'native-app-tests.json').write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
print(json.dumps(result, sort_keys=True))
if missing or failed or not executed:
    raise SystemExit('Native application test execution is incomplete')
PY
if ((native_status != 0)); then
    exit "$native_status"
fi
exit "$receipt_status"
