#!/usr/bin/env python3
"""Compare actual bitmap subtitle region projection against a pinned baseline."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import shutil
import statistics
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
VARIANTS = ("baseline", "candidate")
TIMELINE = "Sources/IlliquidNativePlayback/Subtitles/BitmapSubtitleTimeline.swift"
BUDGET = "Sources/IlliquidNativePlayback/Subtitles/SubtitleMemoryBudget.swift"
REGIONS = "Sources/IlliquidNativePlayback/Subtitles/LibassContext.swift"
TESTS = ["BitmapSubtitleProjectionTests.swift", "BitmapSubtitleTimelineOrderingTests.swift",
         "SubtitleMemoryBudgetAccountingTests.swift"]

FLAGS = ["-O", "-whole-module-optimization", "-swift-version", "6", "-warnings-as-errors"]


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def file_digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def save(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


class Run:
    def __init__(self, output: Path):
        self.output = output
        self.number = 0
        self.environment = dict(os.environ)
        for key, directory in {
            "CLANG_MODULE_CACHE_PATH": output / "cache/clang",
            "SWIFTPM_MODULECACHE_OVERRIDE": output / "cache/swift",
            "XDG_CACHE_HOME": output / "cache/xdg",
            "TMPDIR": output / "cache/tmp",
        }.items():
            directory.mkdir(parents=True, exist_ok=True)
            self.environment[key] = str(directory)
        (output / "logs").mkdir()

    def append(self, name: str, value: object) -> None:
        with (self.output / name).open("a") as stream:
            stream.write(json.dumps(value, sort_keys=True) + "\n")

    def command(self, args: list, label: str) -> str:
        args = [str(arg) for arg in args]
        self.number += 1
        log = self.output / "logs" / f"{self.number:04d}-{label}.log"
        started = time.time()
        result = subprocess.run(args, cwd=ROOT, env=self.environment, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        log.write_text(result.stdout)
        self.append("commands.jsonl", {
            "command": args, "cwd": str(ROOT), "started_unix": started,
            "elapsed_seconds": time.time() - started, "exit_code": result.returncode,
            "log": str(log.relative_to(self.output)), "log_sha256": digest(result.stdout.encode()),
        })
        if result.returncode:
            raise RuntimeError(f"{label} failed ({result.returncode}); see {log}\n{result.stdout[-6000:]}")
        return result.stdout


def executable(choice: str | None, name: str) -> str:
    found = shutil.which(choice or name)
    if found is None:
        raise RuntimeError(f"{name} is required; set {name.upper()} or add it to PATH")
    # The swift/swiftc symlink spelling selects the driver's behavior.
    return str(Path(found).absolute())


def portable(data: bytes) -> bytes:
    # Foundation exports its real geometry types on Linux. No geometry, Data,
    # budget, or projection behavior is substituted by this import-only adapter.
    return data if sys.platform == "darwin" else data.replace(b"import CoreGraphics\n", b"")


REVIEWED_SUPPORT = {'Sources/IlliquidNativePlayback/Subtitles/LibassContext.swift': '3f54f4ef38c30191538aa0edfc4f3ad704d9078ec4edf73ee5a2601e153abdae', 'Sources/IlliquidNativePlayback/Subtitles/SubtitleMemoryBudget.swift': '9ed5a5969fe23ae90df38aea7987f5a61feeb10d7aa1ffafbcf0c05917974cac'}


def snapshot(run: Run, regression: bool = False) -> tuple[dict, dict[str, list[Path]]]:
    pinned = json.loads((HERE / "baseline/manifest.json").read_text())
    inputs = run.output / "inputs"
    inputs.mkdir()
    sources, hashes = {}, {}
    originals = {}
    for path, expected in pinned["files"].items():
        baseline = (HERE / "baseline/BitmapSubtitleTimeline.swift" if path == TIMELINE
                    else ROOT / path).read_bytes()
        blob = hashlib.sha1(f"blob {len(baseline)}\0".encode() + baseline).hexdigest()
        if regression and path in REVIEWED_SUPPORT:
            valid = digest(baseline) == REVIEWED_SUPPORT[path]
        else:
            valid = digest(baseline) == expected["sha256"] and blob == expected["git_blob"]
        if not valid:
            raise RuntimeError(f"Pinned source changed: {path}; requalify the baseline")
        originals[path] = baseline
    for variant in VARIANTS:
        folder = inputs / variant
        folder.mkdir()
        sources[variant] = []
        for path, baseline in originals.items():
            original = (ROOT / path).read_bytes() if path == TIMELINE and variant == "candidate" else baseline
            data = original
            name = Path(path).name
            if path == REGIONS:
                start = b"struct ASSRenderedRegion: Sendable {"
                end = (b"/// Identity belongs to the render stream," if regression
                       else b"struct ASSRenderResult: Sendable {")
                if data.count(start) != 1 or data.count(end) != 1:
                    raise RuntimeError("ASSRenderedRegion extraction boundaries changed")
                data = b"import Foundation\nimport CoreGraphics\n\n" + data[data.index(start):data.index(end)]
                name = "ASSRenderedRegion.swift"
            data = portable(data)
            destination = folder / name
            destination.write_bytes(data)
            sources[variant].append(destination)
            hashes[str(destination.relative_to(inputs))] = {
                "repository_path": path, "full_sha256": digest(original), "compiled_sha256": digest(data),
            }
    for path in [HERE / "Harness.swift", Path(__file__), HERE / "baseline/manifest.json",
                 *(ROOT / "Tests/IlliquidNativePlaybackTests" / name for name in TESTS)]:
        destination = inputs / path.name
        original = path.read_bytes()
        data = portable(original) if path.suffix == ".swift" else original
        destination.write_bytes(data)
        hashes[destination.name] = {"full_sha256": digest(original), "compiled_sha256": digest(data)}
    manifest = {
        "baseline": pinned, "input_sha256": hashes,
        "support_policy": "reviewed-current-correctness" if regression else "historical-strict",
        "reviewed_support": REVIEWED_SUPPORT if regression else None,
        "reviewed_merge_tree": "9f3d7728ea7488242bbfcd7c474b7be1e9c3ee1c" if regression else None,
        "candidate_head": run.command(["git", "rev-parse", "HEAD"], "head").strip(),
        "candidate_status": run.command(["git", "status", "--short"], "status").strip(),
        "platform": platform.platform(), "machine": platform.machine(),
        "python": sys.version, "flags": FLAGS,
        "extraction": "Complete timeline and budget; exact ASSRenderedRegion declaration with Foundation/CoreGraphics imports.",
        "linux_adapter": "Remove only import CoreGraphics; use real Foundation geometry. Native inputs are unchanged.",
        "scope": "Complete NativeBitmapSubtitleComposition.renderedRegions call, result consumption and release; fixture preparation excluded.",
        "linkage": "Separately optimized production IlliquidNativePlayback module and driver; no cross-module optimization.",
    }
    return manifest, sources


def compiler(run: Run) -> tuple[dict, list[str]]:
    choice = os.environ.get("SWIFTC")
    native = sys.platform == "darwin"
    if native and choice is None:
        choice = run.command(["xcrun", "--find", "swiftc"], "compiler-path").strip()
    swiftc = executable(choice, "swiftc")
    swift = executable(os.environ.get("SWIFT") or str(Path(swiftc).parent / "swift"), "swift")
    metadata = {
        "swiftc": swiftc, "swift": swift,
        "version": run.command([swiftc, "--version"], "compiler-version").strip(),
        "swiftc_binary_sha256": file_digest(Path(swiftc).resolve()),
    }
    frontend = Path(swiftc).parent / "swift-frontend"
    if frontend.exists():
        metadata["frontend_binary_sha256"] = file_digest(frontend.resolve())
    target = []
    if native:
        sdk = run.command(["xcrun", "--sdk", "macosx", "--show-sdk-path"], "sdk").strip()
        target = ["-target", f"{platform.machine()}-apple-macosx26.0", "-sdk", sdk]
        metadata.update({
            "sdk": sdk, "macos": run.command(["sw_vers"], "macos").strip(),
            "xcode": run.command(["xcodebuild", "-version"], "xcode").strip(),
            "cpu": run.command(["sysctl", "-n", "machdep.cpu.brand_string"], "cpu").strip(),
        })
    else:
        metadata["cpu"] = next((line.split(":", 1)[1].strip() for line in
                                Path("/proc/cpuinfo").read_text().splitlines()
                                if line.startswith("model name")), "unknown")
    return metadata, target


def tests(run: Run, sources: dict[str, list[Path]], toolchain: dict, summary: dict) -> None:
    for variant in VARIANTS:
        package = run.output / "build" / f"tests-{variant}"
        source_dir = package / "Sources/IlliquidNativePlayback"
        test_dir = package / "Tests/IlliquidNativePlaybackTests"
        source_dir.mkdir(parents=True)
        test_dir.mkdir(parents=True)
        for path in sources[variant]:
            shutil.copyfile(path, source_dir / path.name)
        for name in TESTS:
            shutil.copyfile(run.output / "inputs" / name, test_dir / name)
        (package / "Package.swift").write_text('''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "BitmapProjectionQualification", platforms: [.macOS("26.0")], targets: [
    .target(name: "IlliquidNativePlayback"),
    .testTarget(name: "IlliquidNativePlaybackTests", dependencies: ["IlliquidNativePlayback"]),
])
''')
        for configuration in ["debug", "release"]:
            command = [toolchain["swift"], "test", "--package-path", package,
                       "--scratch-path", package / "build", "--cache-path", package / "cache",
                       "--config-path", package / "config", "--security-path", package / "security",
                       "--configuration", configuration, "--jobs", "2", "--no-parallel",
                       "-Xswiftc", "-warnings-as-errors"]
            if sys.platform != "darwin":
                command.append("--use-integrated-swift-driver")
            output = run.command(command, f"tests-{variant}-{configuration}")
            summary["tests"].append({"variant": variant, "configuration": configuration, "passed": True})
            save(run.output / "summary.json", summary)
            print(f"PASS {variant} {configuration}: " + "\n".join(output.splitlines()[-3:]), flush=True)


def build(run: Run, sources: dict[str, list[Path]], toolchain: dict,
          target: list[str], manifest: dict) -> dict[str, Path]:
    extension = "dylib" if sys.platform == "darwin" else "so"
    flags = [*FLAGS, *target, "-module-cache-path", run.output / "cache/modules"]
    manifest["build_sha256"] = {}
    binaries = {}
    for variant in VARIANTS:
        folder = run.output / "build" / variant
        folder.mkdir(parents=True)
        module = folder / f"libIlliquidNativePlayback.{extension}"
        run.command([toolchain["swiftc"], *flags, "-enable-testing", "-emit-library", "-emit-module",
                     "-module-name", "IlliquidNativePlayback", "-emit-module-path", folder / "IlliquidNativePlayback.swiftmodule",
                     *sources[variant], "-o", module], f"build-{variant}-module")
        binary = folder / "bitmap-projection"
        run.command([toolchain["swiftc"], *flags, "-parse-as-library",
                     "-I", folder, "-L", folder, "-lIlliquidNativePlayback", "-Xlinker", "-rpath", "-Xlinker", folder,
                     run.output / "inputs/Harness.swift", "-o", binary], f"build-{variant}-driver")
        binaries[variant] = binary
        manifest["build_sha256"][variant] = {"module": file_digest(module), "driver": file_digest(binary)}
    save(run.output / "manifest.json", manifest)
    return binaries


def parity(run: Run, binaries: dict[str, Path], summary: dict) -> list[str]:
    outputs, names = {}, {}
    for variant in VARIANTS:
        outputs[variant] = json.loads(run.command([binaries[variant], "verify"], f"verify-{variant}"))
        save(run.output / f"verification-{variant}.json", outputs[variant])
        names[variant] = json.loads(run.command([binaries[variant], "list"], f"list-{variant}"))
    if outputs["baseline"] != outputs["candidate"] or names["baseline"] != names["candidate"]:
        raise RuntimeError("Complete input/output receipts or workloads differ")
    summary["verification"] = {"complete_output_parity": True, "fixtures": len(outputs["baseline"]),
                               "receipt_sha256": file_digest(run.output / "verification-baseline.json")}
    save(run.output / "summary.json", summary)
    save(run.output / "workloads.json", names["baseline"])
    print("PARITY " + json.dumps(summary["verification"]), flush=True)
    return names["baseline"]


def measure(run: Run, binaries: dict[str, Path], workloads: list[str], args: argparse.Namespace, summary: dict) -> None:
    counts, calibration = {}, {}
    for name in workloads:
        iterations = 4
        for attempt in range(12):
            probes = []
            for variant in VARIANTS:
                row = json.loads(run.command([binaries[variant], name, iterations], f"calibrate-{name}-{attempt}-{variant}"))
                row.update(variant=variant, attempt=attempt)
                run.append("calibration.jsonl", row)
                probes.append(row)
            fastest = min(row["cpu_ns"] for row in probes)
            if fastest >= args.target_ms * 1_000_000 * 0.9:
                stop = "target_reached"
                break
            if iterations >= 10_000_000:
                stop = "iteration_cap"
                break
            if attempt == 11:
                stop = "attempt_cap"
                break
            iterations = min(10_000_000, max(iterations + 1,
                             math.ceil(iterations * args.target_ms * 1_000_000 / max(fastest, 1))))
        counts[name] = iterations
        calibration[name] = {"iterations": iterations, "fastest_cpu_ns": fastest,
                             "attempts": attempt + 1, "stop_reason": stop}
    save(run.output / "iteration-counts.json", counts)
    save(run.output / "calibration-summary.json", calibration)
    rows = []
    # Interleave workloads across rounds; no observations are trimmed or discarded.
    for pair in range(args.pairs):
        for name in workloads:
            values = {}
            order = VARIANTS if pair % 2 == 0 else tuple(reversed(VARIANTS))
            for position, variant in enumerate(order):
                row = json.loads(run.command([binaries[variant], name, counts[name]], f"measure-{name}-{pair}-{variant}"))
                row.update(variant=variant, pair=pair, position_in_pair=position)
                values[variant] = row
                rows.append(row)
                run.append("observations.jsonl", row)
            for key in ["workload", "iterations", "checksum", "warmup_checksum", "warmup_iterations", "input_region_count"]:
                if values["baseline"][key] != values["candidate"][key]:
                    raise RuntimeError(f"Paired output mismatch: {name}, {key}")
        print(f"Completed paired round {pair + 1}/{args.pairs}", flush=True)
    for name in workloads:
        selected = [row for row in rows if row["workload"] == name]
        result = {"workload": name, "iterations": counts[name], "pairs": args.pairs}
        for metric in ["cpu", "wall"]:
            values = {variant: [row[f"{metric}_ns_per_projection"] for row in selected if row["variant"] == variant]
                      for variant in VARIANTS}
            ratios = [candidate / baseline for baseline, candidate in zip(values["baseline"], values["candidate"])]
            result[metric] = {
                "baseline_median_ns": statistics.median(values["baseline"]),
                "candidate_median_ns": statistics.median(values["candidate"]),
                "paired_reduction_percent": 100 * (1 - statistics.median(ratios)),
                "paired_ratios": ratios, "candidate_faster_pairs": sum(ratio < 1 for ratio in ratios),
            }
        summary["workloads"].append(result)
        print(json.dumps(result), flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=["all", "test", "benchmark", "regression"], default="all")
    parser.add_argument("--pairs", type=int, default=10)
    parser.add_argument("--target-ms", type=float, default=150)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2 or not math.isfinite(args.target_ms) or args.target_ms <= 0:
        parser.error("--pairs must be positive and even (at least 2); --target-ms must be finite and positive")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        parser.error("--output must be a new or empty directory; preserve earlier receipts")
    run = Run(output)
    summary = {"status": "running", "mode": args.mode, "pairs": args.pairs,
               "target_ms": args.target_ms, "tests": [], "workloads": []}
    save(output / "summary.json", summary)
    try:
        manifest, sources = snapshot(run, regression=args.mode == "regression")
        toolchain, target = compiler(run)
        manifest["compiler"] = toolchain
        manifest["protocol"] = {
            "pairs": args.pairs, "target_cpu_ms": args.target_ms,
            "order": "Fresh processes, alternating baseline/candidate and candidate/baseline; all workloads interleaved across rounds.",
            "calibration": "Target >=90% requested CPU interval in both variants, capped at 12 probes/10 million iterations; stop reasons recorded; identical fixed iterations per workload; all probes retained.",
        }
        save(output / "manifest.json", manifest)
        if args.mode in ["all", "test", "regression"]:
            tests(run, sources, toolchain, summary)
        binaries = build(run, sources, toolchain, target, manifest)
        workloads = parity(run, binaries, summary)
        if args.mode in ["all", "benchmark"]:
            measure(run, binaries, workloads, args, summary)
        summary["status"] = "passed"
    except Exception as error:
        summary.update(status="failed", error=str(error))
        raise
    finally:
        save(output / "summary.json", summary)


if __name__ == "__main__":
    main()
