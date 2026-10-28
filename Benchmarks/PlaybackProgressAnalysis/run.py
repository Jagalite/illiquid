#!/usr/bin/env python3
"""Measure exact production progress analysis against a pinned source oracle."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import statistics
import subprocess
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
ANALYZER = "Sources/IlliquidPlaybackStateSpace/PlaybackProgressAnalyzer.swift"
BASELINE_BLOB = "1f6ac16c9cdb5a7ff5dd8063db1e063e842b1c71"
MODELS = ["seek", "eof-drain", "recovery", "track-subtitles", "stop-shutdown", "preroll-buffering"]
CASES = [f"{operation}/{model}/5" for operation in ["analyze", "scc"] for model in MODELS]
CASES += ["scc/empty/0", "scc/isolated/4096", "scc/cycles/4096", "scc/dense/256"]

MANIFEST = """// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "PlaybackProgressAnalysis",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "ProgressAnalysisBenchmark", targets: ["ProgressAnalysisBenchmark"])],
    targets: [
        .target(name: "IlliquidCore"),
        .target(name: "IlliquidPlaybackCore", dependencies: ["IlliquidCore"]),
        .target(name: "IlliquidPlaybackStateSpace", dependencies: ["IlliquidPlaybackCore"]),
        .executableTarget(name: "ProgressAnalysisBenchmark", dependencies: ["IlliquidPlaybackStateSpace"]),
        .testTarget(name: "IlliquidPlaybackStateSpaceTests",
                    dependencies: ["IlliquidPlaybackCore", "IlliquidPlaybackStateSpace"]),
    ],
    swiftLanguageModes: [.v6]
)
"""


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def save(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def git(*arguments: str) -> bytes:
    return subprocess.check_output(["git", "-C", str(ROOT), *arguments])


def execute(arguments: list, output: Path, name: str, timeout: int = 900) -> str:
    arguments = list(map(str, arguments))
    environment = os.environ.copy()
    environment.update(
        CLANG_MODULE_CACHE_PATH=str(output / "module-cache"),
        SWIFTPM_MODULECACHE_OVERRIDE=str(output / "module-cache"),
        TERM="dumb", NO_COLOR="1",
    )
    started = time.monotonic()
    completed = subprocess.run(
        arguments, cwd=ROOT, env=environment, capture_output=True, text=True, timeout=timeout
    )
    (output / f"{name}.log").write_text(completed.stdout + completed.stderr)
    with (output / "commands.jsonl").open("a") as stream:
        stream.write(json.dumps({
            "argv": arguments, "returncode": completed.returncode,
            "seconds": time.monotonic() - started, "log": f"{name}.log",
        }) + "\n")
    if completed.returncode:
        raise RuntimeError(f"{name} failed:\n{completed.stdout}\n{completed.stderr}")
    return completed.stdout


def stage(output: Path, original: bytes, variant: str) -> dict:
    package = output / variant
    package.mkdir()
    receipts = {}

    def copy(relative: str, destination: str | None = None, data: bytes | None = None) -> None:
        source = (ROOT / relative).read_bytes() if data is None else data
        target = package / (destination or relative)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(source)
        receipts[str(target.relative_to(package))] = sha256(source)

    # Same minimal, actual-source dependency as the existing completed-effect
    # benchmark: MediaTrack is the playback core's only IlliquidCore dependency.
    copy("Sources/IlliquidCore/Player/MediaTrack.swift")
    for directory in ["Sources/IlliquidPlaybackCore", "Sources/IlliquidPlaybackStateSpace",
                      "Tests/IlliquidPlaybackStateSpaceTests"]:
        for source in sorted((ROOT / directory).glob("*.swift")):
            relative = str(source.relative_to(ROOT))
            copy(relative, data=original if variant == "baseline" and relative == ANALYZER else None)
    copy("Benchmarks/PlaybackProgressAnalysis/Harness.swift",
         "Sources/ProgressAnalysisBenchmark/Harness.swift")

    # Preserve the exact baseline implementation. Only its enum name changes;
    # both copies use the production report and graph types in the same module.
    declaration = b"public enum PlaybackProgressAnalyzer {"
    if original.count(declaration) != 1:
        raise ValueError("Baseline analyzer declaration moved")
    reference = b"import IlliquidPlaybackCore\n\n" + original[original.index(declaration):].replace(
        declaration, b"public enum ReferencePlaybackProgressAnalyzer {", 1
    )
    copy(ANALYZER, "Sources/IlliquidPlaybackStateSpace/ReferencePlaybackProgressAnalyzer.swift",
         data=reference)
    (package / "Package.swift").write_text(MANIFEST)
    receipts["Package.swift"] = sha256(MANIFEST.encode())
    save(output / f"{variant}-sources.json", receipts)
    return receipts


def swift_command(swift: str, package: Path, output: Path, operation: str, configuration: str) -> list:
    arguments = [
        swift, operation, "--package-path", package, "--configuration", configuration,
        "--jobs", "2", "--cache-path", output / "cache", "--config-path", output / "config",
        "--security-path", output / "security", "-Xswiftc", "-enable-testing",
        "-Xswiftc", "-warnings-as-errors",
    ]
    if operation == "test":
        arguments.append("--no-parallel")
    return arguments


def summarize(rows: list[dict]) -> list[dict]:
    summaries = []
    for case in dict.fromkeys(row["case"] for row in rows):
        selected = [row for row in rows if row["case"] == case]
        summary = {"case": case, "pairs": len(selected) // 2, "variants": {}, "paired_reduction_percent": {}}
        for variant in ["baseline", "candidate"]:
            values = [row for row in selected if row["variant"] == variant]
            summary["variants"][variant] = {}
            for metric in ["elapsed_ns", "cpu_ns"]:
                samples = [row[metric] / row["iterations"] for row in values]
                summary["variants"][variant][metric] = {
                    "median": statistics.median(samples), "minimum": min(samples), "maximum": max(samples)
                }
        for metric in ["elapsed_ns", "cpu_ns"]:
            reductions = []
            for pair in range(summary["pairs"]):
                values = {row["variant"]: row[metric] / row["iterations"]
                          for row in selected if row["pair"] == pair}
                reductions.append(100 * (1 - values["candidate"] / values["baseline"]))
            summary["paired_reduction_percent"][metric] = {
                "median": statistics.median(reductions), "all": reductions,
                "candidate_faster_pairs": sum(value > 0 for value in reductions),
            }
        summaries.append(summary)
    return summaries


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--swift", default=shutil.which("swift"))
    parser.add_argument("--pairs", type=int, default=8)
    parser.add_argument("--target-ms", type=float, default=150)
    parser.add_argument("--case", action="append", choices=CASES)
    parser.add_argument("--tests-only", action="store_true")
    args = parser.parse_args()
    if not args.swift:
        parser.error("Swift 6.1+ with bundled Testing is required")
    if args.pairs < 2 or args.pairs > 20 or args.pairs % 2:
        parser.error("--pairs must be even and in 2...20")
    if not 1 <= args.target_ms <= 1000:
        parser.error("--target-ms must be in 1...1000")
    if args.case and len(args.case) != len(set(args.case)):
        parser.error("--case values must be unique")
    output = args.output.resolve()
    if output.exists():
        parser.error("Output directory must be new; prior evidence is never overwritten")
    output.mkdir(parents=True)
    original = git("show", f"{BASELINE}:{ANALYZER}")
    original_blob = hashlib.sha1(
        b"blob " + str(len(original)).encode() + b"\0" + original
    ).hexdigest()
    if original_blob != BASELINE_BLOB:
        raise ValueError("Pinned production analyzer blob does not match")

    manifest = {
        "started_utc": datetime.now(timezone.utc).isoformat(),
        "platform": platform.platform(), "machine": platform.machine(),
        "compiler": execute([args.swift, "--version"], output, "compiler").strip(),
        "baseline_commit": BASELINE, "baseline_blob": original_blob,
        "candidate_commit": git("rev-parse", "HEAD").decode().strip(),
        "candidate_analyzer_sha256": sha256((ROOT / ANALYZER).read_bytes()),
        "baseline_analyzer_sha256": sha256(original),
        "pairs": args.pairs, "target_ms": args.target_ms,
        "tests_only": args.tests_only, "cases": args.case or CASES,
        "method": "one fresh process per case; same-process balanced AB/BA; optimized actual Swift",
        "scope": "progress analysis after graph construction; not exploration, playback, RSS or energy",
        "harness_sha256": sha256((HERE / "Harness.swift").read_bytes()),
        "runner_sha256": sha256(Path(__file__).read_bytes()),
    }
    save(output / "manifest.json", manifest)
    source_receipts = {variant: stage(output, original, variant) for variant in ["baseline", "candidate"]}
    changed = [path for path in source_receipts["candidate"]
               if source_receipts["baseline"].get(path) != source_receipts["candidate"][path]]
    if changed != [ANALYZER]:
        raise ValueError(f"Expected only the production analyzer to differ: {changed}")

    tests = []
    for variant in ["baseline", "candidate"]:
        for configuration in ["debug", "release"]:
            name = f"{variant}-{configuration}-tests"
            execute(swift_command(args.swift, output / variant, output, "test", configuration),
                    output, name)
            log = (output / f"{name}.log").read_text()
            counts = re.findall(r"Test run with (\d+) tests?\b", log)
            if not counts or int(counts[-1]) == 0:
                raise RuntimeError(f"No completed Swift Testing tests in {name}")
            receipt = {"variant": variant, "configuration": configuration, "tests": int(counts[-1])}
            tests.append(receipt)
            print("TEST", json.dumps(receipt), flush=True)
    save(output / "tests.json", tests)
    if args.tests_only:
        save(output / "completion.json", {"complete": True, "tests_only": True, "tests": tests})
        return

    package = output / "candidate"
    execute(swift_command(args.swift, package, output, "build", "release")
            + ["--product", "ProgressAnalysisBenchmark"], output, "benchmark-build")
    binary_directory = execute(
        [args.swift, "build", "--package-path", package, "-c", "release", "--show-bin-path"],
        output, "binary-path").strip()
    binary = Path(binary_directory) / "ProgressAnalysisBenchmark"
    manifest["binary_sha256"] = sha256(binary.read_bytes())
    save(output / "manifest.json", manifest)

    rows, fixtures, calibrations = [], [], []
    for case in manifest["cases"]:
        log = execute([binary, case, str(args.pairs), str(args.target_ms)], output,
                      case.replace("/", "-"), timeout=600)
        records = [json.loads(line) for line in log.splitlines() if line.strip()]
        fixture = [row for row in records if row["kind"] == "fixture"]
        calibration = [row for row in records if row["kind"] == "calibration"]
        measured = [row for row in records if row["kind"] == "measurement"]
        if len(fixture) != 1 or len(calibration) != 1 or len(measured) != args.pairs * 2:
            raise RuntimeError(f"Incomplete case: {case}")
        for pair in range(args.pairs):
            actual = [row for row in measured if row["pair"] == pair]
            expected_order = ["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]
            if [row["variant"] for row in actual] != expected_order or [row["sequence"] for row in actual] != [0, 1]:
                raise RuntimeError(f"Unbalanced or duplicate pair: {case}/{pair}")
            for field in ["case", "iterations", "checksum", "fingerprint", "oracle_equal"]:
                if actual[0][field] != actual[1][field]:
                    raise RuntimeError(f"Parity mismatch: {case}/{pair}/{field}")
            if not actual[0]["oracle_equal"] or actual[0]["iterations"] < 1:
                raise RuntimeError(f"Invalid receipt: {case}/{pair}")
        rows.extend(measured)
        fixtures.extend(fixture)
        calibrations.extend(calibration)
        with (output / "measurements.jsonl").open("a") as stream:
            for row in measured:
                stream.write(json.dumps(row, sort_keys=True) + "\n")
        save(output / "fixtures.json", fixtures)
        save(output / "calibration.json", calibrations)
        summaries = summarize(rows)
        save(output / "summary.json", summaries)
        summary = summaries[-1]
        print("RESULT", case, json.dumps({
            "baseline_ms": summary["variants"]["baseline"]["elapsed_ns"]["median"] / 1_000_000,
            "candidate_ms": summary["variants"]["candidate"]["elapsed_ns"]["median"] / 1_000_000,
            "paired_reduction_percent": summary["paired_reduction_percent"]["elapsed_ns"]["median"],
        }), flush=True)

    completion = {"complete": True, "cases": len(fixtures), "measurements": len(rows),
                  "parity": True, "balanced_order": True}
    save(output / "completion.json", completion)
    # The artifact retains all files. This compact log receipt also permits
    # auditing measurements through the GitHub connector without a local unzip.
    print("PROGRESS_MANIFEST_JSON=" + json.dumps(manifest, sort_keys=True), flush=True)
    for category, values in [("TEST", tests), ("FIXTURE", fixtures), ("CALIBRATION", calibrations),
                             ("MEASUREMENT", rows), ("SUMMARY", summarize(rows))]:
        for value in values:
            print(f"PROGRESS_{category}_JSON=" + json.dumps(value, sort_keys=True), flush=True)
    print("PROGRESS_COMPLETION_JSON=" + json.dumps(completion, sort_keys=True), flush=True)


if __name__ == "__main__":
    main()
