#!/usr/bin/env python3
"""Build and test the actual relative-seek driver without the native app graph.

Production Swift files are copied byte for byte. Linux-only modules supply unused
AppKit surface types, reexport Foundation geometry as CoreGraphics, and suppress
OSLog output. Foundation, Task, ContinuousClock, and all playback logic are real.
No dependencies are fetched and no application or media file is opened.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import platform
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
DRIVER = "Sources/IlliquidPlayer/Player/PlaybackRuntimeDriver.swift"
TEST = "Tests/IlliquidPlayerTests/RelativeSeekEffectLifetimeTests.swift"
HARNESS = "Benchmarks/RelativeSeekCoalescing/Harness.swift"
CORE = [
    "Persistence/MediaContentVersion.swift",
    "Persistence/MediaPlaybackSettings.swift",
    "Player/MediaSource.swift",
    "Player/MediaTrack.swift",
    "Player/PictureInPictureState.swift",
    "Player/PlaybackCommand.swift",
    "Player/PlaybackModels.swift",
    "Player/PlaybackPhase.swift",
    "Player/SubtitleFallbackEncoding.swift",
    "Player/TrackSelectionPreferences.swift",
    "Player/VideoColorSample.swift",
    "Player/VideoPresentationGeometry.swift",
    "Playlist/FolderPlaylist.swift",
    "Playlist/PlaylistMutation.swift",
    "Utilities/NaturalFilenameOrdering.swift",
    "Utilities/NormalizedFileURL.swift",
]
PLAYBACK = [
    "Module.swift",
    "PlaybackCapabilities.swift",
    "PlaybackRuntime.swift",
    "PlaybackRuntimeEvent.swift",
    "PlaybackSurfaceHost.swift",
]
LINUX_MODULES = ["AppKit", "CoreGraphics", "OSLog"]
PRODUCT = "RelativeSeekBenchmark"


def git(*arguments: str) -> bytes:
    return subprocess.check_output(["git", "-C", str(ROOT), *arguments])


def identities(data: bytes) -> dict[str, str]:
    header = f"blob {len(data)}\0".encode()
    return {
        "sha256": hashlib.sha256(data).hexdigest(),
        "git_blob": hashlib.sha1(header + data).hexdigest(),
    }


def save_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2) + "\n")


def execute(
    command: list[str | Path], output: Path, *, timeout: int = 600,
    transcript: str | None = None
) -> str:
    arguments = [str(value) for value in command]
    started = datetime.now(timezone.utc).isoformat()
    try:
        result = subprocess.run(
            arguments, capture_output=True, text=True, timeout=timeout, check=False
        )
        record = {
            "command": arguments,
            "started_utc": started,
            "returncode": result.returncode,
            "stdout": result.stdout,
            "stderr": result.stderr,
        }
    except subprocess.TimeoutExpired as error:
        record = {
            "command": arguments,
            "started_utc": started,
            "timeout_seconds": timeout,
            "stdout": (error.stdout or b"").decode(errors="replace"),
            "stderr": (error.stderr or b"").decode(errors="replace"),
        }
        with (output / "commands.jsonl").open("a") as stream:
            stream.write(json.dumps(record) + "\n")
        raise
    with (output / "commands.jsonl").open("a") as stream:
        stream.write(json.dumps(record) + "\n")
    if transcript:
        (output / transcript).write_text(result.stdout + result.stderr)
    if result.returncode:
        raise RuntimeError(
            f"Command failed ({result.returncode}): {' '.join(arguments)}\n"
            + result.stdout + result.stderr
        )
    return result.stdout


def production_bytes(path: str, revision: str | None) -> bytes:
    return git("show", f"{revision}:{path}") if revision else (ROOT / path).read_bytes()


def stage_package(
    package: Path, revision: str | None, *, include_tests: bool, include_harness: bool
) -> dict[str, dict[str, str]]:
    """Copy complete production sources; never rewrite the measured driver."""
    if revision:
        model_paths = git(
            "ls-tree", "-r", "--name-only", revision, "--", "Sources/IlliquidPlaybackCore"
        ).decode().splitlines()
        model_paths = [path for path in model_paths if path.endswith(".swift")]
    else:
        model_paths = [
            str(path.relative_to(ROOT))
            for path in sorted((ROOT / "Sources/IlliquidPlaybackCore").rglob("*.swift"))
        ]
    if not model_paths:
        raise ValueError("No production IlliquidPlaybackCore sources found")
    paths = [
        *(f"Sources/IlliquidCore/{name}" for name in CORE),
        *model_paths,
        *(f"Sources/IlliquidPlayback/{name}" for name in PLAYBACK),
        DRIVER,
    ]
    receipts: dict[str, dict[str, str]] = {}

    def copy(path: str, destination: Path, data: bytes, role: str) -> None:
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(data)
        if destination.read_bytes() != data:
            raise ValueError(f"Source copy did not preserve bytes: {path}")
        receipts[path] = {
            **identities(data), "role": role,
            "package_path": str(destination.relative_to(package)),
            "transformation": "none",
        }

    for path in paths:
        copy(path, package / path, production_bytes(path, revision), "production")

    if platform.system() == "Linux":
        for module in LINUX_MODULES:
            path = f"Benchmarks/RelativeSeekCoalescing/Support/{module}.swift"
            copy(path, package / "Sources" / module / f"{module}.swift",
                 (ROOT / path).read_bytes(), "Linux platform support")
    if include_tests:
        copy(TEST, package / TEST, (ROOT / TEST).read_bytes(), "current regression tests")
    if include_harness:
        copy(HARNESS, package / "Sources" / PRODUCT / "Harness.swift",
             (ROOT / HARNESS).read_bytes(), "current benchmark harness")

    linux = platform.system() == "Linux"
    targets = []
    if linux:
        targets += [f'.target(name: "{name}")' for name in LINUX_MODULES]

    def target(name: str, dependencies: list[str], kind: str = "target") -> str:
        encoded = ", ".join(json.dumps(item) for item in dependencies)
        return f'.{kind}(name: "{name}", dependencies: [{encoded}])'

    targets += [
        target("IlliquidCore", ["CoreGraphics"] if linux else []),
        target("IlliquidPlaybackCore", ["IlliquidCore"]),
        target("IlliquidPlayback", ["IlliquidCore", "IlliquidPlaybackCore"]
               + (["AppKit"] if linux else [])),
        target("IlliquidPlayer", ["IlliquidCore", "IlliquidPlaybackCore", "IlliquidPlayback"]
               + (["OSLog"] if linux else [])),
    ]
    if include_tests:
        targets.append(target("IlliquidPlayerTests", [
            "IlliquidCore", "IlliquidPlaybackCore", "IlliquidPlayback", "IlliquidPlayer"
        ], "testTarget"))
    if include_harness:
        targets.append(target(PRODUCT, [
            "IlliquidCore", "IlliquidPlaybackCore", "IlliquidPlayback", "IlliquidPlayer"
        ], "executableTarget"))
    manifest = (
        '// swift-tools-version: 6.1\nimport PackageDescription\n'
        'let package = Package(name: "RelativeSeekCoalescing", '
        'platforms: [.macOS("26.0")], targets: [\n    '
        + ",\n    ".join(targets) + "\n])\n"
    )
    (package / "Package.swift").write_text(manifest)
    receipts["generated:Package.swift"] = {
        **identities(manifest.encode()), "role": "generated package manifest",
        "package_path": "Package.swift", "transformation": "generated",
    }
    return receipts


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["test", "build", "benchmark"])
    parser.add_argument("--source-ref", help="Pinned Git revision for production sources")
    parser.add_argument("--configuration", choices=["debug", "release"], default="release")
    parser.add_argument("--output", required=True, type=Path, help="New or empty evidence directory")
    parser.add_argument("--filter", help="Swift test filter; test command only")
    parser.add_argument("--swift", default="swift", help="Swift executable, default from PATH")
    # Everything after a literal -- belongs to Harness.swift, not to this builder.
    arguments = sys.argv[1:]
    if "--" in arguments:
        split = arguments.index("--")
        builder_arguments, harness_arguments = arguments[:split], arguments[split + 1:]
    else:
        builder_arguments, harness_arguments = arguments, []
    args = parser.parse_args(builder_arguments)
    if args.command != "benchmark" and harness_arguments:
        parser.error("arguments after -- require the benchmark command")
    if args.command != "test" and args.filter:
        parser.error("--filter requires the test command")
    if args.command != "test" and args.configuration != "release":
        parser.error("benchmark executables require release; debug is for tests")
    if platform.system() not in ["Linux", "Darwin"]:
        parser.error("supported platforms are Linux and macOS")
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("--output must be new or empty; evidence is never overwritten")
    output.mkdir(parents=True, exist_ok=True)
    revision = (
        git("rev-parse", "--verify", "--end-of-options", f"{args.source_ref}^{{commit}}").decode().strip()
        if args.source_ref else None
    )
    manifest = {
        "source_ref": args.source_ref,
        "production_source": "git revision" if revision else "working tree",
        "resolved_source_revision": revision,
        "checkout_head": git("rev-parse", "HEAD").decode().strip(),
        "platform": platform.platform(),
        "python": sys.version,
        "configuration": args.configuration,
        "command": args.command,
        "compiler": execute([args.swift, "--version"], output).strip(),
        "builder": identities(Path(__file__).read_bytes()),
        "limitations": [
            "Selected components only; no native app build, decoder, or presentation pipeline",
            "Fake runtime in tests/harness; production driver, model, core, and event types are unmodified",
            "Real Foundation, concurrency, Task, and ContinuousClock on the selected host",
            "Linux AppKit classes are unused surface-type placeholders; CoreGraphics reexports Foundation geometry",
            "Linux OSLog support discards log messages; macOS uses real OSLog",
            "Benchmark entry module uses @testable access to the actual internal driver",
        ],
    }
    save_json(output / "manifest.json", manifest)
    try:
        with tempfile.TemporaryDirectory(prefix="illiquid-relative-seek-") as temporary:
            package = Path(temporary)
            manifest["sources"] = stage_package(
                package, revision, include_tests=args.command == "test",
                include_harness=args.command != "test"
            )
            save_json(output / "manifest.json", manifest)
            common = [
                "--package-path", package,
                "--scratch-path", package / ".build",
                "--cache-path", package / "cache",
                "--config-path", package / "config",
                "--security-path", package / "security",
                "-c", args.configuration, "--jobs", "1",
                "-Xswiftc", "-warnings-as-errors",
                "-Xswiftc", "-enable-testing",
            ]
            if args.command == "test":
                flags = ["--filter", args.filter] if args.filter else []
                text = execute([args.swift, "test", *common, *flags], output, transcript="tests.txt")
                print(text, end="", flush=True)
            else:
                execute([args.swift, "build", *common, "--product", PRODUCT], output)
                binary_directory = execute([
                    args.swift, "build", *common, "--show-bin-path"
                ], output).strip()
                executable = output / PRODUCT
                shutil.copy2(Path(binary_directory) / PRODUCT, executable)
                manifest["executable"] = {
                    "path": str(executable),
                    "sha256": hashlib.sha256(executable.read_bytes()).hexdigest(),
                }
                print(executable, flush=True)
                if args.command == "benchmark":
                    text = execute([executable, *harness_arguments], output)
                    # Preserve the exact harness output; no postprocessing or unit conversion.
                    (output / "benchmark.json").write_text(text)
                    json.loads(text)
                    print(text, end="", flush=True)
            manifest["status"] = "passed"
    except Exception as error:
        manifest["status"] = "failed"
        manifest["error"] = str(error)
        raise
    finally:
        save_json(output / "manifest.json", manifest)


if __name__ == "__main__":
    main()
