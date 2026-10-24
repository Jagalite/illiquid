#!/usr/bin/env bash
# Build the repository's verified FFmpeg archive without network access.
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "$0")/../.." && pwd)"
sdk_root="${1:-/tmp/illiquid-deinterlacer-memory-sdk}"
if [[ -e "$sdk_root" ]]; then
  echo "SDK destination must not exist: $sdk_root" >&2
  exit 1
fi
python3 - "$repo_root" "$sdk_root" <<'PY'
import hashlib, json, sys, tarfile
from pathlib import Path
repo, destination = map(Path, sys.argv[1:])
manifest = json.loads((repo / "DependencySources/source-manifest.json").read_text())
reviewed = json.loads((repo / "Licenses/corresponding-source-manifest.json").read_text())
if manifest != reviewed:
    raise SystemExit("Dependency source manifest differs from the reviewed manifest")
record = next(r for r in manifest["records"]
              if r["component"] == "ffmpeg" and r.get("installed_version") == "8.1.2")
archive = repo / "DependencySources" / record["archive"]
digest = hashlib.sha256(archive.read_bytes()).hexdigest()
if digest != record["sha256"] or digest != record["expected_sha256"]:
    raise SystemExit("FFmpeg archive checksum mismatch")
destination.mkdir(parents=True)
with tarfile.open(archive) as source:
    source.extractall(destination / "source", filter="data")
(destination / "source-receipt.json").write_text(json.dumps({
    "archive": str(archive), "sha256": digest,
    "verifiedAgainstProjectManifest": True, "component": record,
}, indent=2) + "\n")
PY
sdk_root="$(cd -- "$sdk_root" && pwd)"
mkdir -p "$sdk_root/build"
cd "$sdk_root/build"
"$sdk_root/source/ffmpeg-8.1.2/configure" \
  --prefix="$sdk_root" --disable-everything --disable-autodetect \
  --disable-network --disable-doc --disable-programs --disable-avdevice \
  --disable-x86asm --disable-shared --enable-static --enable-pic \
  --enable-pthreads --enable-gpl \
  --enable-filter=buffer,bwdif,buffersink,scale \
  > "$sdk_root/configure.log" 2>&1
make -j "${ILLIQUID_FFMPEG_BUILD_JOBS:-4}" > "$sdk_root/build.log" 2>&1
make install > "$sdk_root/install.log" 2>&1
python3 - "$sdk_root" <<'PY'
import hashlib, json, subprocess, sys
from pathlib import Path
root = Path(sys.argv[1])
(root / "build-receipt.json").write_text(json.dumps({
    "sdkRoot": str(root),
    "compiler": subprocess.check_output(["cc", "--version"], text=True).splitlines()[0],
    "libraries": {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                  for p in sorted((root / "lib").glob("*.a"))},
    "configureLogSHA256": hashlib.sha256((root / "configure.log").read_bytes()).hexdigest(),
}, indent=2) + "\n")
print("Built pinned FFmpeg development libraries:", root)
PY
