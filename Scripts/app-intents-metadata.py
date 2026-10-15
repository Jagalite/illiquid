#!/usr/bin/env python3
"""Produce and verify real compiler/Apple-generated Shortcuts metadata.

No fallback metadata is manufactured and extractor failures are fatal. The
normal packaging script invokes this before codesigning, never after signing.
"""
from __future__ import annotations
import argparse
import json
import re
import subprocess
from pathlib import Path

INTENTS = frozenset({"OpenMediaAtTimeIntent", "EnqueueOrderedMediaIntent",
                     "GetPlaybackReferenceIntent", "OpenPlaybackReferenceIntent"})
PROTOCOLS = ["AppIntent", "AppEntity", "AppEnum", "AppShortcutsProvider", "EntityQuery",
             "AppIntentsPackage", "DynamicOptionsProvider", "IntentValueQuery"]


def prepare(directory: Path) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "protocols.json").write_text(json.dumps(PROTOCOLS) + "\n", encoding="utf-8")
    # A reused scratch directory must not validate yesterday's declarations.
    (directory / "IlliquidApp.swiftconstvalues").unlink(missing_ok=True)


def strings(value: object):
    if isinstance(value, str):
        yield value
    elif isinstance(value, list):
        for item in value:
            yield from strings(item)
    elif isinstance(value, dict):
        for key, item in value.items():
            yield key
            yield from strings(item)


def require_intents(value: object, label: str) -> None:
    # The schema includes both qualified Swift names and identifier keys.
    names = {part for text in strings(value) for part in re.findall(r"[A-Za-z_][A-Za-z0-9_]*", text)}
    missing = INTENTS - names
    if missing:
        raise ValueError(f"{label} is missing actions: {', '.join(sorted(missing))}")


def validate_constants(path: Path) -> None:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, list) or not value:
        raise ValueError("Compiler constant metadata is empty or malformed")
    require_intents(value, "Compiler metadata")


def validate_resources(resources: Path) -> dict:
    metadata = resources / "Metadata.appintents"
    actions = sorted(metadata.rglob("*.actionsdata")) if metadata.is_dir() else []
    if not actions:
        raise ValueError("Apple's Metadata.appintents action catalog is missing")
    records = []
    for path in actions:
        if path.is_symlink() or path.stat().st_size > 16 * 1024 * 1024:
            raise ValueError("Invalid action catalog")
        records.append(json.loads(path.read_text(encoding="utf-8")))
    require_intents(records, "Packaged action catalog")
    return {"actions": sorted(INTENTS), "files": [str(p.relative_to(resources)) for p in actions]}


def capture(*command: str) -> str:
    return subprocess.check_output(command, text=True).strip()


def extract(directory: Path, repository: Path, resources: Path, deployment: str, architecture: str) -> None:
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", deployment):
        raise ValueError("Invalid deployment target")
    if architecture not in {"arm64", "x86_64"}:
        raise ValueError("Unsupported architecture")
    constants = directory / "IlliquidApp.swiftconstvalues"
    validate_constants(constants)
    sources = sorted((repository / "Sources/IlliquidApp").rglob("*.swift"))
    if not sources:
        raise ValueError("App sources are missing")
    source_list, constants_list = directory / "sources.txt", directory / "constants.txt"
    source_list.write_text("".join(str(p.resolve()) + "\n" for p in sources), encoding="utf-8")
    constants_list.write_text(str(constants.resolve()) + "\n", encoding="utf-8")
    developer = Path(capture("xcode-select", "-p"))
    # xcrun honors DEVELOPER_DIR even when the global xcode-select differs.
    compiler = Path(capture("xcrun", "--find", "swiftc")).resolve()
    toolchain = next((p for p in compiler.parents if p.name.endswith(".xctoolchain")),
                     developer / "Toolchains/XcodeDefault.xctoolchain")
    version = capture("xcodebuild", "-version")
    match = re.search(r"^Build version (\S+)$", version, re.M)
    if not match:
        raise ValueError("Xcode build version is unavailable")
    resources.mkdir(parents=True, exist_ok=True)
    if (resources / "Metadata.appintents").exists():
        raise ValueError("Refusing to validate or overwrite stale packaged intent metadata")
    subprocess.run(["xcrun", "appintentsmetadataprocessor",
                    "--toolchain-dir", str(toolchain), "--module-name", "IlliquidApp",
                    "--output", str(resources), "--sdk-root", capture("xcrun", "--sdk", "macosx", "--show-sdk-path"),
                    "--xcode-version", match[1], "--platform-family", "macOS",
                    "--deployment-target", deployment, "--target-triple", f"{architecture}-apple-macosx{deployment}",
                    "--source-file-list", str(source_list), "--swift-const-vals-list", str(constants_list),
                    "--no-app-shortcuts-localization"], check=True)
    report = validate_resources(resources)
    (directory / "validation.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("prepare").add_argument("directory", type=Path)
    validator = sub.add_parser("validate")
    validator.add_argument("resources", type=Path)
    extractor = sub.add_parser("extract")
    extractor.add_argument("--build-directory", required=True, type=Path)
    extractor.add_argument("--repository", required=True, type=Path)
    extractor.add_argument("--resources", required=True, type=Path)
    extractor.add_argument("--deployment-target", required=True)
    extractor.add_argument("--architecture", required=True)
    args = parser.parse_args()
    if args.command == "prepare":
        prepare(args.directory)
    elif args.command == "validate":
        print(json.dumps(validate_resources(args.resources)))
    else:
        extract(args.build_directory, args.repository, args.resources, args.deployment_target, args.architecture)


if __name__ == "__main__":
    main()
