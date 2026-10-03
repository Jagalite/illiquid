#!/bin/zsh
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/../.." && pwd)"
baseline_revision="${1:-8cf2db78d52c679444dd1b668bda32877b842c6b}"
candidate_revision="${2:-98c7179347963ba395d9f990d0410d6d00d657ff}"
output_root="${3:-/private/tmp/superplayr-output-comparison}"
harness_revision="${4:-$(git -C "${repository_root}" rev-parse HEAD)}"
fixture_source="${SUPERPLAYR_NATIVE_FIXTURE_DIR:-${repository_root}/TestFixtures/Generated}"
test_path="Tests/SuperplayrNativePlaybackTests/OutputRegressionArtifactTests.swift"
fixture_names=(
    h264-aac.mp4
    hdr10-pq-p010.mkv
    hlg-p010.mkv
    av1-video-only.mkv
    embedded-srt.mkv
    embedded-ass-font.mkv
    external.ass
    heavy-animated.ass
    audio-5.1.flac
)

if [[ -e "${output_root}" ]]; then
    print -u2 "Refusing to reuse output root: ${output_root}"
    exit 2
fi

mkdir -p "${output_root}/worktrees" "${output_root}/build" "${output_root}/artifacts"

run_revision() {
    local label="$1"
    local revision="$2"
    local worktree="${output_root}/worktrees/${label}"
    local scratch="${output_root}/build/${label}"
    local artifacts="${output_root}/artifacts/${label}"
    local fixtures="${worktree}/TestFixtures/Generated"

    git -C "${repository_root}" worktree add --detach "${worktree}" "${revision}"
    mkdir -p "${fixtures}" "${artifacts}"
    for fixture in "${fixture_names[@]}"; do
        [[ -f "${fixture_source}/${fixture}" ]] || {
            print -u2 "Missing fixture: ${fixture_source}/${fixture}"
            exit 3
        }
        cp "${fixture_source}/${fixture}" "${fixtures}/${fixture}"
    done

    git -C "${repository_root}" diff "${harness_revision}^" "${harness_revision}" \
        -- "${test_path}" | git -C "${worktree}" apply -
    git -C "${worktree}" rev-parse HEAD > "${artifacts}/product-source-revision.txt"
    git -C "${worktree}" status --short > "${artifacts}/test-overlay-files.txt"
    shasum -a 256 "${fixtures}"/* > "${artifacts}/fixture-sha256.txt"

    (
        cd "${worktree}"
        SUPERPLAYR_NATIVE_FIXTURE_DIR="${fixtures}" \
        SUPERPLAYR_OUTPUT_ARTIFACT_DIR="${artifacts}" \
        SUPERPLAYR_OUTPUT_REQUIRE=1 \
        SUPERPLAYR_OUTPUT_SOURCE_REVISION="${revision}" \
        SUPERPLAYR_OUTPUT_HARNESS_REVISION="${harness_revision}" \
        swift test --scratch-path "${scratch}" --no-parallel \
            --filter OutputRegressionArtifactTests
    ) > "${artifacts}/test-output.log" 2>&1
}

run_revision baseline "${baseline_revision}"
run_revision candidate "${candidate_revision}"

python3 "${repository_root}/Benchmarks/OutputRegression/compare.py" \
    --baseline "${output_root}/artifacts/baseline/manifest.json" \
    --candidate "${output_root}/artifacts/candidate/manifest.json" \
    --output "${output_root}/comparison.json" \
    > "${output_root}/comparison-output.log"

print "${output_root}/comparison.json"
