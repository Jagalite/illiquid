#!/bin/zsh
set -euo pipefail
unsetopt BG_NICE

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "${repository_root}"

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
artifact_root="${SUPERPLAYR_REFERENCE_QUALIFICATION_ARTIFACT_DIR:-${repository_root}/QualificationArtifacts/${stamp}}"
fixture_dir="${SUPERPLAYR_NATIVE_FIXTURE_DIR:-${repository_root}/TestFixtures/Generated}"
module_cache="${TMPDIR:-/tmp}/superplayr-reference-qualification-module-cache"
if [[ -e "${artifact_root}" ]]; then
    print -u2 "Qualification artifact destination already exists: ${artifact_root}"
    print -u2 "Use a new empty path so stale semantic results cannot enter the acceptance report."
    exit 2
fi
mkdir -p "${artifact_root}" "${module_cache}/clang" "${module_cache}/swiftpm"

typeset -A exit_codes
run_logged() {
    local name="$1"
    shift
    set +e
    "$@" > "${artifact_root}/${name}.log" 2>&1
    local result=$?
    set -e
    exit_codes["${name}"]="${result}"
    print "${result}" > "${artifact_root}/${name}.exit-code"
}

system_profiler SPHardwareDataType SPSoftwareDataType SPDisplaysDataType SPAudioDataType \
    -json > "${artifact_root}/system-profile.json" 2> "${artifact_root}/system-profile.stderr" || true
sw_vers > "${artifact_root}/sw-vers.txt"
uname -a > "${artifact_root}/uname.txt"

run_logged build-harness env \
    CLANG_MODULE_CACHE_PATH="${module_cache}/clang" \
    SWIFTPM_MODULECACHE_OVERRIDE="${module_cache}/swiftpm" \
    swift build --disable-sandbox --product SuperplayrDifferentialHarness

run_logged verify-fixtures .build/debug/SuperplayrDifferentialHarness \
    verify-fixture-manifest --directory "${fixture_dir}"

run_logged deterministic-races .build/debug/SuperplayrDifferentialHarness \
    deterministic-races --output "${artifact_root}/deterministic-races.json"

run_logged deterministic-semantic-policies .build/debug/SuperplayrDifferentialHarness \
    deterministic-semantic-policies \
    --output "${artifact_root}/deterministic-semantic-policies.json"

run_logged deterministic-acceptance .build/debug/SuperplayrDifferentialHarness \
    deterministic-acceptance \
    --output "${artifact_root}/deterministic-acceptance.json"

run_logged homebrew-semantic-matrix .build/debug/SuperplayrDifferentialHarness \
    semantic-matrix --directory "${fixture_dir}" \
    --output "${artifact_root}/homebrew-semantic-matrix" \
    --mpv "${SUPERPLAYR_MPV_BIN:-/opt/homebrew/bin/mpv}"

if [[ "${exit_codes["homebrew-semantic-matrix"]:-not-run}" == "0" ]]; then
    run_logged acceptance-report .build/debug/SuperplayrDifferentialHarness \
        acceptance-report \
        --matrix-directory "${artifact_root}/homebrew-semantic-matrix" \
        --output "${artifact_root}/acceptance-report.json"
else
    exit_codes["acceptance-report"]="not-run"
fi

run_logged pinned-mpv-build Scripts/build-pinned-mpv-oracle.sh
pinned_binary="${MPV_ORACLE_BUILD_DIR:-/tmp/superplayr-reference-src/mpv/build-oracle}/mpv"
if [[ "${exit_codes["pinned-mpv-build"]:-not-run}" == "0" && -x "${pinned_binary}" ]]; then
    run_logged pinned-semantic-matrix .build/debug/SuperplayrDifferentialHarness \
        semantic-matrix --directory "${fixture_dir}" \
        --output "${artifact_root}/pinned-semantic-matrix" \
        --mpv "${pinned_binary}" \
        --mpv-source-revision 94335ab87ab225ca3e36e0faeac831639d3e1d4e
    pinned_status="measured"
else
    exit_codes["pinned-semantic-matrix"]="not-run"
    pinned_status="blocked: exact source checkout present but Meson unavailable or build failed; see pinned-mpv-build.log"
fi

run_logged native-renderer-smoke .build/debug/SuperplayrDifferentialHarness \
    native-renderer-smoke --fixture "${fixture_dir}/h264-aac.mp4" \
    --output "${artifact_root}/native-renderer-smoke"

run_logged build-replacement-stress env \
    CLANG_MODULE_CACHE_PATH="${module_cache}/clang" \
    SWIFTPM_MODULECACHE_OVERRIDE="${module_cache}/swiftpm" \
    swift build --disable-sandbox --product SuperplayrPlaybackStress
if [[ "${exit_codes["build-replacement-stress"]:-not-run}" == "0" ]]; then
    run_logged replacement-stress /usr/bin/time -l \
        .build/debug/SuperplayrPlaybackStress \
        --media "${fixture_dir}/h264-aac.mp4" --reopen-count 50 --duration 10
else
    exit_codes["replacement-stress"]="not-run"
fi

for sanitizer in address thread; do
    run_logged "${sanitizer}-build" env \
        CLANG_MODULE_CACHE_PATH="${module_cache}/clang" \
        SWIFTPM_MODULECACHE_OVERRIDE="${module_cache}/swiftpm" \
        swift build --disable-sandbox --sanitize "${sanitizer}" \
        --product SuperplayrPlaybackStress
    if [[ "${exit_codes["${sanitizer}-build"]:-not-run}" == "0" ]]; then
        run_logged "${sanitizer}-stress" /usr/bin/time -l \
            .build/debug/SuperplayrPlaybackStress \
            --media "${fixture_dir}/h264-aac.mp4" --reopen-count 50 --duration 10
    else
        exit_codes["${sanitizer}-stress"]="not-run"
    fi
done

run_logged swift-tests env \
    CLANG_MODULE_CACHE_PATH="${module_cache}/clang" \
    SWIFTPM_MODULECACHE_OVERRIDE="${module_cache}/swiftpm" \
    swift test --disable-sandbox --no-parallel
run_logged fixture-semantic-tests env \
    CLANG_MODULE_CACHE_PATH="${module_cache}/clang" \
    SWIFTPM_MODULECACHE_OVERRIDE="${module_cache}/swiftpm" \
    SUPERPLAYR_NATIVE_FIXTURE_DIR="${fixture_dir}" \
    SUPERPLAYR_NATIVE_REQUIRE_FIXTURES=1 \
    swift test --disable-sandbox --skip-build --no-parallel --filter \
    'requiredFixtureManifest|prioritizedFixtureTruth|fixtureMatrixAccounts|unknownDuration|timelineOrigins|bitmapSubtitleCapabilities|mirroredAndInterlaced|nativeTrackIDs|cleanAndTruncated|inputExecutor|safelyDownmixes|heavyAnimatedASS|detectsSubtitle|seekInvalidates|convertsMultipleAudio|catalogSelection|audioFormatChange|codecCapabilityFixtures|rotationMatrix|anamorphicFixture|decodesAudioFixtureMatrix|resampled44100|embeddedSRT|subtitlePacketInvalidates|libassRendersExternal'
run_logged architecture-check env \
    CLANG_MODULE_CACHE_PATH="${module_cache}/clang" \
    SWIFTPM_MODULECACHE_OVERRIDE="${module_cache}/swiftpm" \
    swift run --disable-sandbox SuperplayrArchitectureCheck
run_logged build-app env \
    CLANG_MODULE_CACHE_PATH="${module_cache}/clang" \
    SWIFTPM_MODULECACHE_OVERRIDE="${module_cache}/swiftpm" \
    SUPERPLAYR_SWIFTPM_DISABLE_SANDBOX=1 \
    Scripts/build-app.sh
run_logged verify-app Scripts/verify-app.sh --require-signature dist/Superplayr.app

set +e
dist/Superplayr.app/Contents/MacOS/Superplayr "${fixture_dir}/h264-aac.mp4" \
    > "${artifact_root}/packaged-app-smoke.log" 2>&1 &
app_pid=$!
sleep 5
if kill -0 "${app_pid}" 2>/dev/null; then
    kill -TERM "${app_pid}" 2>/dev/null
    wait "${app_pid}" 2>/dev/null
    app_status="launched for five-second observation window; terminated by qualification runner"
    exit_codes["packaged-app-smoke"]="observation-window"
else
    wait "${app_pid}"
    exit_codes["packaged-app-smoke"]="$?"
    app_status="process exited before the five-second observation window; see packaged-app-smoke.log"
fi
set -e
print "${exit_codes["packaged-app-smoke"]}" > "${artifact_root}/packaged-app-smoke.exit-code"

cat > "${artifact_root}/qualification-summary.json" <<EOF
{
  "artifactSchemaVersion": 1,
  "generatedAtUTC": "${stamp}",
  "fixtureDirectory": "${fixture_dir}",
  "automatedGates": {
    "fixtureManifest": "exit ${exit_codes["verify-fixtures"]:-not-run}",
    "deterministicRaces": "exit ${exit_codes["deterministic-races"]:-not-run}",
    "deterministicSemanticPolicies": "exit ${exit_codes["deterministic-semantic-policies"]:-not-run}",
    "deterministicAcceptance": "exit ${exit_codes["deterministic-acceptance"]:-not-run}; unobservable physical gates remain unmeasured",
    "homebrewOracleMatrix": "exit ${exit_codes["homebrew-semantic-matrix"]:-not-run}; executable revision is unpinned",
    "acceptanceReport": "exit ${exit_codes["acceptance-report"]:-not-run}; live semantic evidence is merged with deterministic evidence; renderer-only gates remain unmeasured",
    "pinnedOracleMatrix": "${pinned_status}",
    "nativeRendererSmoke": "exit ${exit_codes["native-renderer-smoke"]:-not-run}; see log for renderer availability",
    "replacementStress50": "build exit ${exit_codes["build-replacement-stress"]:-not-run}; run exit ${exit_codes["replacement-stress"]:-not-run}",
    "addressSanitizerStress50": "build exit ${exit_codes["address-build"]:-not-run}; run exit ${exit_codes["address-stress"]:-not-run}",
    "threadSanitizerStress50": "build exit ${exit_codes["thread-build"]:-not-run}; run exit ${exit_codes["thread-stress"]:-not-run}",
    "swiftTests": "exit ${exit_codes["swift-tests"]:-not-run}",
    "fixtureSemanticTests": "exit ${exit_codes["fixture-semantic-tests"]:-not-run}; renderer-dependent fixture tests run in separate gates",
    "architectureCheck": "exit ${exit_codes["architecture-check"]:-not-run}",
    "packageBuild": "exit ${exit_codes["build-app"]:-not-run}",
    "packageVerification": "exit ${exit_codes["verify-app"]:-not-run}",
    "packagedAppSmoke": "${app_status}"
  },
  "physicalMatrix": {
    "builtInSDR_EDR": "unmeasured: requires human visual grade and EDR observation",
    "externalSDR_HDR": "unmeasured: no external display attached by the automated runner",
    "builtInSpeakersHeadphones": "unmeasured: renderer state is not physical audibility",
    "HDMI_USB_WirelessAudio": "unmeasured: routes require physical devices and human confirmation",
    "sleepWake": "unmeasured: automation does not suspend the qualification host",
    "displayDisconnectReconnect": "unmeasured: requires a physical cable or device transition",
    "fullscreen": "unmeasured: requires UI observation",
    "pictureInPicture": "unmeasured: requires UI observation",
    "HDR_HLG_SDRGrade": "unmeasured: screenshots do not prove the physical tone-map path",
    "powerThermal": "unmeasured: requires a controlled long-run measurement"
  }
}
EOF

print "${artifact_root}"

required_gates=(
    build-harness
    verify-fixtures
    deterministic-races
    deterministic-semantic-policies
    deterministic-acceptance
    homebrew-semantic-matrix
    acceptance-report
    build-replacement-stress
    address-build
    thread-build
    swift-tests
    fixture-semantic-tests
    architecture-check
    build-app
    verify-app
)
required_failures=()
for gate in "${required_gates[@]}"; do
    gate_status_file="${artifact_root}/${gate}.exit-code"
    if [[ -f "${gate_status_file}" ]]; then
        gate_status="$(<"${gate_status_file}")"
    else
        gate_status="not-run"
    fi
    if [[ "${gate_status}" != "0" ]]; then
        required_failures+=("${gate}=${gate_status}")
    fi
done

if (( ${#required_failures[@]} > 0 )); then
    print -u2 "Required qualification gates failed: ${required_failures[*]}"
    exit 1
fi
