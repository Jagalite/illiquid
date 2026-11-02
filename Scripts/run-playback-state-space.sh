#!/bin/zsh
set -euo pipefail

# Runs the playback state-space qualification through Statelessness. Submit
# this whole script to the Kyoto queue: it compiles before it explores.

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "${repository_root}"

profile="${ILLIQUID_STATE_SPACE_PROFILE:-pr}"
shard_index="${ILLIQUID_STATE_SPACE_SHARD_INDEX:-0}"
shard_count="${ILLIQUID_STATE_SPACE_SHARD_COUNT:-1}"
artifact_root="${ILLIQUID_STATE_SPACE_ARTIFACT_ROOT:-${repository_root}/Artifacts/PlaybackStateSpace/${profile}}"
max_graph_bytes="${ILLIQUID_STATE_SPACE_MAX_GRAPH_BYTES:-3221225472}"
# Optional: space-separated model/seed pairs, and a per-seed time budget
# override (seconds or "none"). Both are recorded in each seed's record.
selected_seeds="${ILLIQUID_STATE_SPACE_SEEDS:-}"
time_limit_args=()
if [[ -n "${ILLIQUID_STATE_SPACE_TIME_LIMIT:-}" ]]; then
    time_limit_args+=(--time-limit "${ILLIQUID_STATE_SPACE_TIME_LIMIT}")
fi
pr_baseline="${repository_root}/Documentation/Baselines/PLAYBACK_STATE_SPACE_PR_BASELINE.json"
baseline_args=()
if [[ -n "${ILLIQUID_STATE_SPACE_BASELINE:-}" ]]; then
    baseline_args+=(--baseline "${ILLIQUID_STATE_SPACE_BASELINE}")
elif [[ "${profile}" == "pr" ]]; then
    [[ -f "${pr_baseline}" ]] || { print -u2 "missing ${pr_baseline}"; exit 64; }
    baseline_args+=(--baseline "${pr_baseline}")
fi

swift build --product IlliquidStateSpaceExplorer

# Provenance: revision, dirty-file hashes, and toolchain/platform identity.
mkdir -p "${artifact_root}"
provenance="${artifact_root}/provenance-shard-${shard_index}-of-${shard_count}.json"
python3 - "${provenance}" <<'PY'
import hashlib, json, os, platform, subprocess, sys
def run(*command):
    return subprocess.run(command, capture_output=True, text=True, check=True).stdout
# Every status entry is recorded: content SHA-256 for files that exist,
# "deleted" otherwise. Renames record the destination path.
status = run("git", "status", "--porcelain", "-z", "--untracked-files=all").split("\0")
dirty = {}
index = 0
while index < len(status):
    entry = status[index]
    index += 1
    if not entry:
        continue
    code, path = entry[:2], entry[3:]
    if "R" in code or "C" in code:
        index += 1  # skip the rename/copy source path
    if os.path.isfile(path):
        with open(path, "rb") as handle:
            dirty[path] = hashlib.sha256(handle.read()).hexdigest()
    else:
        dirty[path] = "deleted"
json.dump({
    "sourceRevision": run("git", "rev-parse", "HEAD").strip(),
    "sourceDirty": bool(dirty),
    "dirtyFiles": dirty,
    "swiftVersion": " ".join(run("swift", "--version").split()),
    "platform": f"{platform.system()} {platform.release()} {platform.machine()}",
}, open(sys.argv[1], "w"), indent=1, sort_keys=True)
PY

if [[ -n "${selected_seeds}" ]]; then
    result=0
    for selection in ${=selected_seeds}; do
        .build/debug/IlliquidStateSpaceExplorer \
            --profile "${profile}" \
            --model "${selection%%/*}" \
            --seed "${selection##*/}" \
            --provenance "${provenance}" \
            --max-graph-bytes "${max_graph_bytes}" \
            "${time_limit_args[@]}" \
            "${baseline_args[@]}" \
            --output "${artifact_root}/${selection%%/*}-${selection##*/}" || {
                code=$?
                # A finding (1) or usage error outranks incompleteness (2).
                if (( code != 2 )); then result=${code}; elif (( result == 0 )); then result=2; fi
            }
    done
    exit ${result}
fi

.build/debug/IlliquidStateSpaceExplorer \
    --profile "${profile}" \
    --shard-index "${shard_index}" \
    --shard-count "${shard_count}" \
    --all-seeds \
    --provenance "${provenance}" \
    --max-graph-bytes "${max_graph_bytes}" \
    "${time_limit_args[@]}" \
    "${baseline_args[@]}" \
    --output "${artifact_root}"
