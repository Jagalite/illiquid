#!/usr/bin/env python3
"""Extract and validate App Intents metadata for the SwiftPM-built macOS app.

Compilation must enable -emit-const-values for IlliquidApp. This script fails
closed on missing inputs, extractor errors, or missing expected action/entity
identities. It never registers an app, changes shortcuts, or signs/publishes it.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

ACTION_TYPES = {
    "OpenMediaAtTimeIntent", "EnqueueOrderedMediaIntent",
    "GetPlaybackReferenceIntent", "OpenPlaybackReferenceIntent",
}
ENTITY_TYPE = "PlaybackReferenceEntity"
REQUIRED_TYPES = ACTION_TYPES | {ENTITY_TYPE, "IlliquidAppShortcuts"}


def command(*args: str) -> str:
    return subprocess.check_output(list(args), text=True).strip()


def extract(source_root: Path, build_root: Path, output: Path,
            architecture: str, minimum_macos: str) -> dict:
    if architecture not in ("arm64", "x86_64") or not re.fullmatch(r"\d+(?:\.\d+){0,2}", minimum_macos):
        raise ValueError("Invalid macOS architecture or deployment version")
    source_root = source_root.resolve(strict=True)
    build_root = build_root.resolve(strict=True)
    output.mkdir(parents=True, exist_ok=True)
    output = output.resolve(strict=True)
    if (output / "Metadata.appintents").exists():
        raise ValueError("Metadata output must be fresh; refusing stale Metadata.appintents")
    files = sorted(build_root.glob("**/IlliquidApp.build/*.swiftconstvalues"))
    # Some SwiftPM toolchains put whole-module supplementary output beside the
    # executable. Keep that fallback explicit and scoped to this module.
    if not files:
        files = sorted(build_root.glob("**/IlliquidApp.swiftconstvalues"))
    if not files:
        raise ValueError("No IlliquidApp compile-time constant values were produced")
    # A universal SwiftPM build can contain duplicate per-architecture outputs.
    # Prefer the requested architecture, and reject nonidentical ambiguous inputs.
    preferred = [p for p in files if architecture + "-apple-macosx" in p.as_posix()]
    if preferred:
        files = preferred
    unique: dict[str, Path] = {}
    types: set[str] = set()
    for path in files:
        data = path.read_bytes()
        if path.name in unique:
            if unique[path.name].read_bytes() != data:
                raise ValueError(f"Ambiguous constant-value input: {path.name}")
            continue
        values = json.loads(data)
        if not isinstance(values, list):
            raise ValueError(f"Invalid constant-value file: {path}")
        for value in values:
            types.add(value.get("typeName", "").rsplit(".", 1)[-1])
        unique[path.name] = path
    if missing := REQUIRED_TYPES - types:
        raise ValueError(f"Missing extracted App Intents types: {sorted(missing)}")
    inputs = build_root / "illiquid-app-intents-inputs"
    inputs.mkdir(exist_ok=True)
    source_list = inputs / "sources.list"
    const_list = inputs / "constants.list"
    sources = sorted((source_root / "Sources/IlliquidApp").rglob("*.swift"))
    source_list.write_text("".join(str(p) + "\n" for p in sources))
    const_list.write_text("".join(str(p) + "\n" for p in unique.values()))
    tool = command("xcrun", "--find", "appintentsmetadataprocessor")
    toolchain = str(Path(tool).resolve().parents[2])
    sdk = command("xcrun", "--sdk", "macosx", "--show-sdk-path")
    xcode_version = command("xcodebuild", "-version").splitlines()[-1].split()[-1]
    subprocess.run([tool, "--output", str(output), "--toolchain-dir", toolchain,
        "--module-name", "IlliquidApp", "--sdk-root", sdk,
        "--xcode-version", xcode_version, "--platform-family", "macOS",
        "--deployment-target", minimum_macos,
        "--target-triple", f"{architecture}-apple-macosx{minimum_macos}",
        "--source-file-list", str(source_list), "--swift-const-vals-list", str(const_list),
        "--validate-assistant-intents"], check=True)
    metadata = output / "Metadata.appintents"
    produced = sorted(p for p in metadata.rglob("*") if p.is_file())
    if not produced:
        raise ValueError("The App Intents extractor produced no metadata bundle")
    content = b"\n".join(p.read_bytes() for p in produced)
    missing = {name for name in ACTION_TYPES | {ENTITY_TYPE} if name.encode() not in content}
    if missing:
        raise ValueError(f"Metadata bundle is missing action/entity identities: {sorted(missing)}")
    return {"module": "IlliquidApp", "actionTypes": sorted(ACTION_TYPES),
        "entityType": ENTITY_TYPE, "architecture": architecture,
        "deploymentTarget": minimum_macos,
        "files": [{"path": str(p.relative_to(output)),
                   "sha256": hashlib.sha256(p.read_bytes()).hexdigest(),
                   "bytes": p.stat().st_size} for p in produced]}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--build-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--architecture", required=True)
    parser.add_argument("--minimum-macos", default="26.0")
    parser.add_argument("--evidence", type=Path)
    args = parser.parse_args()
    try:
        result = extract(args.source_root, args.build_root, args.output,
                         args.architecture, args.minimum_macos)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"App Intents metadata extraction failed: {error}", file=sys.stderr)
        return 1
    serialized = json.dumps(result, indent=2) + "\n"
    if args.evidence:
        args.evidence.parent.mkdir(parents=True, exist_ok=True)
        args.evidence.write_text(serialized)
    print(serialized, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
