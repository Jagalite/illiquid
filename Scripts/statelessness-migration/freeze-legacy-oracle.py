#!/usr/bin/env python3
"""Record the frozen legacy state-space explorer for the Statelessness migration.

Hashes the committed bytes (git blobs, not the working tree) of every legacy
verification source, script, test, contract and dependency file at REVISION,
together with compiler and dependency identity, and writes a JSON manifest.
The manifest identifies the migration oracle; it is not itself a passing run.
Pair it with the Kyoto receipts recorded in the Phase 0 document.
"""
import argparse
import datetime
import hashlib
import json
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
FROZEN = [
    "Sources/IlliquidPlaybackCore",
    "Sources/IlliquidPlaybackStateSpace",
    "Validation/IlliquidStateSpaceExplorer",
    "Scripts/run-playback-state-space.sh",
    "Tests/IlliquidPlaybackStateSpaceTests",
    "Documentation/PLAYBACK_STATE_SPACE_SEARCH.md",
    "Package.swift",
    "Package.resolved",
]


def git(*args, binary=False):
    result = subprocess.run(["git", *args], cwd=ROOT, capture_output=True, check=True)
    return result.stdout if binary else result.stdout.decode()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()
    revision = git("rev-parse", f"{args.revision}^{{commit}}").strip()
    paths = sorted(git("ls-tree", "-r", "--name-only", revision, "--", *FROZEN).splitlines())
    if not paths:
        raise SystemExit("no frozen paths found")
    files = {path: hashlib.sha256(git("show", f"{revision}:{path}", binary=True)).hexdigest()
             for path in paths}
    swift = subprocess.run(["swift", "--version"], capture_output=True, text=True,
                           stdin=subprocess.DEVNULL)
    manifest = {
        "schema": "illiquid.statelessness-migration.legacy-oracle.v1",
        "created": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "revision": revision,
        "frozenRoots": FROZEN,
        "swift": " ".join((swift.stdout or swift.stderr).split()),
        "files": files,
        "aggregateSha256": hashlib.sha256(
            "".join(f"{digest}  {path}\n" for path, digest in files.items()).encode()
        ).hexdigest(),
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    if args.output.exists():
        raise SystemExit(f"{args.output} exists; frozen manifests are never overwritten")
    args.output.write_text(json.dumps(manifest, indent=1, sort_keys=True) + "\n")
    print(f"{args.output}: {len(files)} files, aggregate {manifest['aggregateSha256']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
