#!/bin/zsh
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "${repository_root}"

profile="${SUPERPLAYR_STATE_SPACE_PROFILE:-pr}"
shard_index="${SUPERPLAYR_STATE_SPACE_SHARD_INDEX:-0}"
shard_count="${SUPERPLAYR_STATE_SPACE_SHARD_COUNT:-1}"
artifact_root="${SUPERPLAYR_STATE_SPACE_ARTIFACT_ROOT:-${repository_root}/Artifacts/PlaybackStateSpace/${profile}}"
baseline_args=()
if [[ -n "${SUPERPLAYR_STATE_SPACE_BASELINE:-}" ]]; then
    baseline_args+=(--baseline "${SUPERPLAYR_STATE_SPACE_BASELINE}")
elif [[ "${profile}" == "pr" ]]; then
    baseline_args+=(--baseline "${repository_root}/Documentation/Baselines/PLAYBACK_STATE_SPACE_PR_BASELINE.json")
fi

swift build --product SuperplayrStateSpaceExplorer
SUPERPLAYR_SOURCE_REVISION="$(git rev-parse HEAD)" \
SUPERPLAYR_SOURCE_DIRTY="$([[ -n "$(git status --porcelain)" ]] && print 1 || print 0)" \
  .build/debug/SuperplayrStateSpaceExplorer \
    --profile "${profile}" \
    --shard-index "${shard_index}" \
    --shard-count "${shard_count}" \
    --all-seeds \
    "${baseline_args[@]}" \
    --output "${artifact_root}"
