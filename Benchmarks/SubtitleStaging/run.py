#!/usr/bin/env python3
"""Test and measure the production subtitle CPU packer without native SDKs.

Only complete declarations are extracted from the application sources. No
algorithm is translated and no Metal/libass behavior is simulated. The native
Swift test target remains the integration check for the full application graph.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import statistics
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parents[2]
BASELINE = "8c3cc3d4008d5d1b8d436bcf2d51d891382b6548"
PACKER = "Sources/IlliquidNativePlayback/Subtitles/MetalASSSubtitleCompositor.swift"
REGION = "Sources/IlliquidNativePlayback/Subtitles/LibassContext.swift"
BUDGET = "Sources/IlliquidNativePlayback/Subtitles/SubtitleMemoryBudget.swift"
TEST = "Tests/IlliquidNativePlaybackTests/SubtitleStagingReuseTests.swift"
DRIVER = Path(__file__).with_name("Main.swift")


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def source(path: str, ref: str | None) -> str:
    if ref is None:
        return (ROOT / path).read_text()
    return subprocess.check_output(
        ["git", "-C", str(ROOT), "show", f"{ref}:{path}"], text=True
    )


def between(text: str, start: str, end: str) -> str:
    if text.count(start) != 1 or text.count(end) != 1:
        raise ValueError(f"Source extraction boundary changed: {start!r}, {end!r}")
    first, last = text.index(start), text.index(end)
    if first >= last:
        raise ValueError("Source extraction boundaries are out of order")
    return text[first:last]


def extract(destination: Path, ref: str | None) -> dict:
    destination.mkdir(parents=True, exist_ok=True)
    originals = {path: source(path, ref) for path in (PACKER, REGION, BUDGET)}
    # Foundation supplies CGRect/CGSize on Linux. On macOS also import their
    # original CoreGraphics module; all extracted declarations are verbatim.
    imports = (
        "import Foundation\nimport Synchronization\n"
        "#if canImport(CoreGraphics)\nimport CoreGraphics\n#endif\n\n"
    )
    generated = {
        "SubtitleFramePacker.swift": imports
        + between(originals[PACKER], "enum SubtitleCompositionStrategy:", "enum MetalASSFailureReason:")
        + between(originals[PACKER], "struct ASSAtlasQuad:", "@MainActor\nfinal class MetalASSSubtitleRenderer"),
        "SubtitleRenderedRegion.swift": imports
        + between(originals[REGION], "struct ASSRenderedRegion:", "struct ASSRenderResult:"),
        "SubtitleMemoryBudget.swift": originals[BUDGET],
    }
    for name, contents in generated.items():
        (destination / name).write_text(contents)
    return {
        "source_ref": ref or "working-tree",
        "source_sha256": {p: sha256(s.encode()) for p, s in originals.items()},
        "generated_sha256": {p: sha256(s.encode()) for p, s in generated.items()},
    }


def execute(command: list[str], output: Path, name: str, env: dict) -> str:
    completed = subprocess.run(command, text=True, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, env=env)
    (output / f"{name}.log").write_text(completed.stdout)
    with (output / "commands.jsonl").open("a") as log:
        log.write(json.dumps({"command": command, "returncode": completed.returncode,
                              "log": f"{name}.log"}) + "\n")
    if completed.returncode:
        raise RuntimeError(f"Command failed ({completed.returncode}); see {output / (name + '.log')}\n"
                           + completed.stdout[-12000:])
    return completed.stdout


def test(args: argparse.Namespace, output: Path, env: dict, swift: str) -> None:
    package = output / "package"
    manifest = extract(package / "Sources/IlliquidNativePlayback", args.source_ref)
    tests = package / "Tests/IlliquidNativePlaybackTests"
    tests.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(ROOT / TEST, tests / Path(TEST).name)
    manifest["test_sha256"] = sha256((ROOT / TEST).read_bytes())
    (package / "Package.swift").write_text('''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "SubtitleStagingRegressions", platforms: [.macOS("26.0")], targets: [
    .target(name: "IlliquidNativePlayback"),
    .testTarget(name: "IlliquidNativePlaybackTests", dependencies: ["IlliquidNativePlayback"])
])
''')
    write_json(output / "manifest.json", manifest)
    command = [swift, "test", "--package-path", str(package),
               "--cache-path", str(output / "pm-cache"),
               "--config-path", str(output / "pm-config"),
               "--security-path", str(output / "pm-security"),
               "--jobs", "2", "-c", args.configuration]
    if args.filter:
        command += ["--filter", args.filter]
    result = execute(command, output, "tests", env)
    print(result[-12000:])


def build_binary(name: str, ref: str | None, output: Path, env: dict,
                 swiftc: str) -> tuple[Path, dict]:
    build = output / name
    manifest = extract(build, ref)
    binary = build / "subtitle-staging"
    command = [swiftc, "-O", "-whole-module-optimization", "-swift-version", "6", "-parse-as-library",
               "-module-cache-path", str(output / "module-cache"),
               *[str(build / p) for p in sorted(manifest["generated_sha256"])],
               str(DRIVER), "-o", str(binary)]
    if platform.system() == "Darwin":
        command += ["-target", f"{platform.machine()}-apple-macosx26.0"]
    execute(command, output, f"build-{name}", env)
    manifest.update(driver_sha256=sha256(DRIVER.read_bytes()),
                    binary_sha256=sha256(binary.read_bytes()), build_command=command)
    return binary, manifest


def benchmark(args: argparse.Namespace, output: Path, env: dict, swift: str) -> None:
    swiftc = str(Path(swift).with_name("swiftc"))
    if not Path(swiftc).is_file():
        raise RuntimeError("swiftc must be alongside the selected swift executable")
    pinned_baseline = subprocess.check_output(
        ["git", "-C", str(ROOT), "rev-parse", "--verify", args.baseline_ref + "^{commit}"], text=True
    ).strip()
    binaries, manifests = {}, {}
    for name, ref in (("baseline", pinned_baseline), ("candidate", None)):
        binaries[name], manifests[name] = build_binary(name, ref, output, env, swiftc)
    write_json(output / "manifests.json", manifests)

    # The comparison covers complete historical Data snapshots, geometry,
    # upload/copy work and source retirement. Clear accounting intentionally
    # changes; the verification receipt excludes that one diagnostic metric.
    receipts = {}
    for name, binary in binaries.items():
        receipt = json.loads(execute([str(binary), "verify"], output, f"verify-{name}", env))
        receipts[name] = receipt
        write_json(output / f"verify-{name}.json", receipt)
    if receipts["baseline"] != receipts["candidate"]:
        raise RuntimeError("Full-frame verification receipts differ; inspect verify-*.json")

    available = json.loads(execute([str(binaries["candidate"]), "list"], output, "cases", env))
    cases = available if not args.case else [c for c in available if c["case"] in args.case]
    if not cases or (args.case and len(cases) != len(set(args.case))):
        raise ValueError("Unknown or empty benchmark case selection")
    observations = []
    summaries = []
    for case_index, case in enumerate(cases):
        for repetition in range(args.repetitions):
            order = ["baseline", "candidate"] if (case_index + repetition) % 2 == 0 else ["candidate", "baseline"]
            pair = {}
            for order_index, name in enumerate(order):
                command = [str(binaries[name]), "benchmark", case["case"],
                           str(case["iterations"]), str(case["held_count"])]
                result = json.loads(execute(command, output,
                    f"timing-{case['case']}-{repetition}-{name}", env))
                result.update(variant=name, repetition=repetition, order_index=order_index)
                observations.append(result)
                pair[name] = result
            for key in ("checksum", "active_bytes", "retained_bytes", "iterations", "held_count"):
                if pair["baseline"][key] != pair["candidate"][key]:
                    raise RuntimeError(f"Timed receipt mismatch: {case['case']} {key}")
        values = {name: [r["ns_per_frame"] for r in observations
                        if r["case"] == case["case"] and r["variant"] == name]
                  for name in binaries}
        baseline = statistics.median(values["baseline"])
        candidate = statistics.median(values["candidate"])
        summary = {**case, "baseline_median_ns": baseline, "candidate_median_ns": candidate,
                   "change_percent": (candidate / baseline - 1) * 100,
                   "baseline_range_ns": [min(values["baseline"]), max(values["baseline"])],
                   "candidate_range_ns": [min(values["candidate"]), max(values["candidate"])]}
        summaries.append(summary)
        print(f"{case['case']}: {baseline / 1000:.3f} -> {candidate / 1000:.3f} us/frame "
              f"({summary['change_percent']:+.1f}%)", flush=True)
        # Keep a reproducible checkpoint even if a later case fails.
        write_json(output / "RESULTS.json", {
            "baseline_ref": pinned_baseline, "repetitions": args.repetitions,
            "environment": json.loads((output / "environment.json").read_text()),
            "manifests": manifests, "summary": summaries, "observations": observations,
            "verification_receipt_sha256": sha256(json.dumps(receipts["baseline"], sort_keys=True).encode()),
            "verification": receipts["baseline"],
        })


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("test", "benchmark"))
    parser.add_argument("--output", type=Path)
    parser.add_argument("--swift", default=shutil.which("swift"))
    parser.add_argument("--source-ref", help="Test a historical source with current regression tests")
    parser.add_argument("--configuration", choices=("debug", "release"), default="debug")
    parser.add_argument("--filter", help="Swift test filter")
    parser.add_argument("--baseline-ref", default=BASELINE)
    parser.add_argument("--repetitions", type=int, default=10)
    parser.add_argument("--case", action="append")
    args = parser.parse_args()
    if args.swift is None:
        parser.error("swift was not found; put the Swift toolchain on PATH or use --swift")
    if args.repetitions < 1:
        parser.error("--repetitions must be positive")
    output = (args.output or Path(tempfile.mkdtemp(prefix="illiquid-subtitle-staging-"))).absolute()
    output.mkdir(parents=True, exist_ok=True)
    # Refuse to overwrite a previous evidence run.
    if (output / "environment.json").exists():
        parser.error(f"Output already contains a run: {output}")
    env = dict(os.environ)
    env["SWIFTPM_MODULECACHE_OVERRIDE"] = str(output / "module-cache")
    env["CLANG_MODULE_CACHE_PATH"] = str(output / "module-cache")
    version = subprocess.check_output([args.swift, "--version"], text=True, env=env).strip()
    write_json(output / "environment.json", {
        "platform": platform.platform(), "machine": platform.machine(),
        "compiler": version, "timestamp_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "runner_sha256": sha256(Path(__file__).read_bytes()),
    })
    print(f"Evidence: {output}", flush=True)
    if args.mode == "test":
        test(args, output, env, args.swift)
    else:
        benchmark(args, output, env, args.swift)


if __name__ == "__main__":
    main()
