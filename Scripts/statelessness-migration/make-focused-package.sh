#!/bin/zsh
# Creates the focused state-space test package used while the full Illiquid
# test bundle cannot load on the host (discrepancy D2). Target sources are
# symlinks into this worktree; the manifest pins the same Statelessness
# revision as Package.swift. Run its tests through Kyoto:
#   kyoto.py submit --cwd DEST --resource DEST/.build -- swift test
set -euo pipefail
repository_root="$(cd "$(dirname "$0")/../.." && pwd)"
destination="${1:?usage: make-focused-package.sh DESTINATION}"
mkdir -p "${destination}/Sources" "${destination}/Tests"
for target in IlliquidCore IlliquidPlaybackCore IlliquidPlaybackStateSpace; do
  ln -sfn "${repository_root}/Sources/${target}" "${destination}/Sources/${target}"
done
ln -sfn "${repository_root}/Tests/IlliquidPlaybackStateSpaceTests" \
  "${destination}/Tests/IlliquidPlaybackStateSpaceTests"
cp "${repository_root}/Scripts/statelessness-migration/focused-package/Package.swift" \
  "${destination}/Package.swift"
