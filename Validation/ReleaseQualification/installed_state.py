#!/usr/bin/env python3
"""Record/compare state exported from disposable historical-package test installs.

Read-only with respect to applications and preferences. This does not install,
launch, migrate, sign, or qualify an application by itself. Receipts contain
private paths/settings and should not be committed without review.
"""
from __future__ import annotations

import argparse
import base64
import datetime
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
from typing import Any


def digest(path: Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(block)
    return hasher.hexdigest()


def executable_payload(path: Path) -> tuple[str, str]:
    """Ignore signing-only differences without modifying the installed binary."""
    with path.open("rb") as stream:
        magic = stream.read(4)
    macho = {bytes.fromhex(value) for value in (
        "feedface", "cefaedfe", "feedfacf", "cffaedfe",
        "cafebabe", "bebafeca", "cafebabf", "bfbafeca")}
    if magic not in macho:
        # Supports opaque synthetic fixtures; genuine Illiquid executables are Mach-O.
        return digest(path), "opaque-bytes-v1"
    if sys.platform != "darwin":
        raise ValueError("Mach-O snapshots require macOS codesign for signature-independent identity")
    with tempfile.TemporaryDirectory(prefix="illiquid-code-identity-") as directory:
        unsigned = Path(directory) / "executable"
        shutil.copyfile(path, unsigned)
        result = subprocess.run(["/usr/bin/codesign", "--remove-signature", str(unsigned)],
                                capture_output=True, timeout=30, check=False)
        if result.returncode != 0:
            raise ValueError("Cannot derive unsigned executable identity; check the test artifact's signature")
        return digest(unsigned), "mach-o-codesign-stripped-v1"


def canonical(value: Any) -> Any:
    if isinstance(value, bytes):
        try:
            return {"$json_data": json.loads(value)}
        except (ValueError, UnicodeError):
            return {"$base64_data": base64.b64encode(value).decode("ascii")}
    if isinstance(value, datetime.datetime):
        return {"$date": value.isoformat()}
    if isinstance(value, dict):
        return {key: canonical(item) for key, item in value.items()}
    if isinstance(value, list):
        return [canonical(item) for item in value]
    return value


def named_paths(values: list[str]) -> dict[str, Path]:
    result: dict[str, Path] = {}
    for value in values:
        name, separator, filename = value.partition("=")
        if not separator or not name or not filename or name in result:
            raise ValueError("Inputs must be unique NAME=PATH pairs")
        result[name] = Path(filename)
    return result


def snapshot(app: Path, package: Path, preferences: dict[str, Path], sessions: dict[str, Path]) -> dict[str, Any]:
    if not preferences or not sessions:
        raise ValueError("At least one preferences export and session export are required")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    executable = info["CFBundleExecutable"]
    if not isinstance(executable, str) or Path(executable).name != executable:
        raise ValueError("Invalid CFBundleExecutable")
    binary = app / "Contents/MacOS" / executable
    payload_hash, payload_identity = executable_payload(binary)
    state = {
        "preferences": {name: canonical(plistlib.loads(path.read_bytes())) for name, path in preferences.items()},
        "sessions": {name: json.loads(path.read_bytes()) for name, path in sessions.items()},
    }
    if not any(state["preferences"].values()) or not any(state["sessions"].values()):
        raise ValueError("Empty exports cannot demonstrate populated-state preservation")
    return {
        "schema": 2,
        "scope": "exported-state-only; operator must verify install and UI behavior",
        "application": {
            "path": str(app.resolve()),
            "bundle_identifier": info["CFBundleIdentifier"],
            "version": str(info["CFBundleShortVersionString"]),
            "build": str(info["CFBundleVersion"]),
            "executable_sha256": digest(binary),
            "payload_sha256": payload_hash,
            "payload_identity": payload_identity,
        },
        "package": {"path": str(package.resolve()), "sha256": digest(package)},
        "state": state,
    }


def differences(expected: Any, actual: Any, path: str = "state") -> list[str]:
    """Require existing values/order, allowing additive dictionary schema fields."""
    if isinstance(expected, dict):
        if not isinstance(actual, dict):
            return [path + ": type changed"]
        result = []
        for key, value in expected.items():
            child = path + "." + key
            result += differences(value, actual[key], child) if key in actual else [child + ": missing"]
        return result
    if isinstance(expected, list):
        if not isinstance(actual, list) or len(expected) != len(actual):
            return [path + ": list length/type changed"]
        return [item for index, value in enumerate(expected)
                for item in differences(value, actual[index], f"{path}[{index}]")]
    # Do not conflate a Boolean preference with a numeric value.
    if type(expected) is not type(actual) or expected != actual:
        return [path + ": value/type changed"]
    return []


def compare(before: dict[str, Any], after: dict[str, Any], expected_state: Any = None) -> list[str]:
    if before.get("schema") != 2 or after.get("schema") != 2:
        raise ValueError("Unsupported receipt schema")
    if before["application"]["payload_identity"] != after["application"]["payload_identity"]:
        raise ValueError("Incompatible executable identity methods")
    if before["application"]["payload_sha256"] == after["application"]["payload_sha256"]:
        raise ValueError("Same executable payload: version bumps/re-signing are not a historical-package upgrade")
    if before["package"]["sha256"] == after["package"]["sha256"]:
        raise ValueError("Same package: supply two distinct historical/candidate artifacts")
    if not before["state"].get("preferences") or not before["state"].get("sessions"):
        raise ValueError("Missing populated baseline state")
    result = differences(before["state"], after["state"])
    if expected_state is not None:
        result += differences(expected_state, after["state"], "expected_state")
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    record = commands.add_parser("snapshot")
    record.add_argument("--app", type=Path, required=True)
    record.add_argument("--package", type=Path, required=True)
    record.add_argument("--preferences", action="append", required=True, metavar="NAME=PLIST")
    record.add_argument("--session", action="append", required=True, metavar="NAME=JSON")
    record.add_argument("--output", type=Path, required=True)
    check = commands.add_parser("compare")
    check.add_argument("--before", type=Path, required=True)
    check.add_argument("--after", type=Path, required=True)
    check.add_argument("--expected-state", type=Path, help="Additional expected current-domain/migrated state projection")
    args = parser.parse_args(argv)
    try:
        if args.command == "snapshot":
            receipt = snapshot(args.app, args.package, named_paths(args.preferences), named_paths(args.session))
            # Never silently overwrite evidence from a previous step.
            with args.output.open("x") as output:
                json.dump(receipt, output, indent=2, sort_keys=True, allow_nan=False)
                output.write("\n")
            print("Recorded exported state and package/executable identities; UI qualification remains separate.")
            return 0
        expected = json.loads(args.expected_state.read_bytes()) if args.expected_state else None
        failures = compare(json.loads(args.before.read_bytes()), json.loads(args.after.read_bytes()), expected)
        if failures:
            print("FAIL: exported state differs (investigate; this alone does not establish data loss).")
            print("\n".join(failures))
            return 1
        print("PASS: compared exported state preserved across distinct artifacts; not a full installed-app qualification.")
        return 0
    except (OSError, ValueError, KeyError, TypeError, plistlib.InvalidFileException, subprocess.TimeoutExpired) as error:
        print(f"Cannot qualify: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
