#!/bin/zsh
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "${repository_root}"

fixture_dir="${SUPERPLAYR_NATIVE_FIXTURE_DIR:-${repository_root}/TestFixtures/Generated}"
long_run_seconds="${SUPERPLAYR_NATIVE_LONG_RUN_SECONDS:-60}"
fixture_duration="${SUPERPLAYR_NATIVE_QUALIFICATION_DURATION:-120}"
if (( fixture_duration < long_run_seconds )); then
    fixture_duration="${long_run_seconds}"
fi
export SUPERPLAYR_NATIVE_FIXTURE_DIR="${fixture_dir}"
export SUPERPLAYR_NATIVE_REQUIRE_FIXTURES=1

SUPERPLAYR_STATE_SPACE_PROFILE=qualification \
    Scripts/run-playback-state-space.sh

SUPERPLAYR_NATIVE_QUALIFICATION_DURATION="${fixture_duration}" \
    Scripts/generate-native-fixtures.sh "${fixture_dir}"
.build/debug/SuperplayrDifferentialHarness verify-fixture-manifest \
    --directory "${fixture_dir}"

artifact_root="${SUPERPLAYR_DIFFERENTIAL_ARTIFACT_ROOT:-${fixture_dir}/Artifacts}"
mkdir -p "${artifact_root}"
artifact_dir="${artifact_root}/h264-aac-$(date -u +%Y%m%dT%H%M%SZ)"
oracle_args=()
if [[ -n "${SUPERPLAYR_MPV_ORACLE_BIN:-}" ]]; then
    oracle_args+=(--mpv "${SUPERPLAYR_MPV_ORACLE_BIN}")
fi
if [[ -n "${SUPERPLAYR_MPV_ORACLE_REVISION:-}" ]]; then
    oracle_args+=(--mpv-source-revision "${SUPERPLAYR_MPV_ORACLE_REVISION}")
fi
.build/debug/SuperplayrDifferentialHarness smoke \
    --fixture "${fixture_dir}/h264-aac.mp4" \
    --output "${artifact_dir}" \
    "${oracle_args[@]}"

SUPERPLAYR_NATIVE_LONG_RUN_SECONDS= swift test --no-parallel
SUPERPLAYR_NATIVE_LONG_RUN_SECONDS="${long_run_seconds}" \
    swift test --no-parallel --filter optionalLongDurationAVSyncAndMemoryGate

media="${fixture_dir}/hdr10-pq-p010.mkv"
swift build --sanitize address --product SuperplayrPlaybackStress
ASAN_OPTIONS=halt_on_error=1 .build/debug/SuperplayrPlaybackStress \
    --media "${media}" --reopen-count 12 --duration 8
swift build --sanitize thread --product SuperplayrPlaybackStress
TSAN_OPTIONS=halt_on_error=1 .build/debug/SuperplayrPlaybackStress \
    --media "${media}" --reopen-count 12 --duration 8

swift build --product Superplayr
swift run SuperplayrArchitectureCheck
Scripts/tests/platinum-packaging-tests.sh
Scripts/build-platinum-app.sh --adhoc
Scripts/audit-platinum-app.sh --require-signature dist/Illiquid.app
Scripts/package-platinum-dmg.sh
