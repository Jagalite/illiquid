#!/usr/bin/env bash
set -euo pipefail
root=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
[[ -z "$(git status --porcelain)" ]] || { echo 'Release requires a clean checkout' >&2; exit 1; }
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Invalid release version' >&2; exit 1; }
if [[ -n "${ILLIQUID_RELEASE_TAG:-}" && "$ILLIQUID_RELEASE_TAG" != "v$version" ]]; then
    echo 'Tag does not match Info.plist version' >&2; exit 1
fi
python3 Scripts/verify-corresponding-source.py DependencySources
ILLIQUID_VERIFY_SDK_ONLY=1 python3 Scripts/install-ci-native-sdk.py
Scripts/build-local-dmg.sh --adhoc
revision=$(git rev-parse HEAD)
git archive --format=tar.gz --prefix="Illiquid-$version/" HEAD > "dist/Illiquid-$version-source.tar.gz"
# Normalize archive ownership/timestamps and include only committed source inputs.
python3 - "dist/Illiquid-$version-dependency-sources.tar.gz" <<'PY_ARCHIVE'
import gzip
import subprocess
import sys
import tarfile

def normalize(info):
    info.uid = info.gid = 0
    info.uname = info.gname = ''
    info.mtime = 0
    info.pax_headers = {}
    return info

files = subprocess.check_output(['git', 'ls-files', '-z', '--', 'DependencySources']).decode().split('\0')
with open(sys.argv[1], 'wb') as output:
    with gzip.GzipFile(filename='', mode='wb', fileobj=output, mtime=0) as compressed:
        with tarfile.open(fileobj=compressed, mode='w') as archive:
            for name in sorted(filter(None, files)):
                archive.add(name, recursive=False, filter=normalize)
PY_ARCHIVE
cp dist/Illiquid.app/Contents/Resources/NativeDependencyProvenance.json dist/build-provenance.json
python3 - "$revision" <<'PY'
import json,sys
from pathlib import Path
p=json.loads(Path('dist/build-provenance.json').read_text())
if p['sourceRevision'] != sys.argv[1] or p['sourceDirty']:
    raise SystemExit('Build provenance does not describe clean release revision')
PY
(
    cd dist
    shasum -a 256 "Illiquid-$version-macOS.dmg" "Illiquid-$version-source.tar.gz" \
        "Illiquid-$version-dependency-sources.tar.gz" build-provenance.json > SHA256SUMS
)
cat > dist/release-notes.md <<EOF
Illiquid $version — Apple Silicon, macOS 26 or later.

This is an **ad hoc signed, unnotarized prerelease**. Developer ID signing and
Apple notarization are planned for a later release. macOS may block the download;
follow Apple's documented Privacy & Security approval procedure only if you trust
this release. The DMG contains Illiquid.app and an Applications shortcut.

Source revision: \`$revision\`. Matching project source, dependency source,
build provenance and SHA-256 checksums are attached. Original project code is
GPL-3.0-or-later; dependency terms are included in the app and source package.

Packaging checks include dependency-lock verification, signature and library
closure audits, and launch/relaunch checks of a copy installed from the DMG.
These checks do not replace the physical-device playback QA checklist.
EOF
