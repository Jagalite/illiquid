#!/usr/bin/env python3
"""Compare the complete NativeScreenshot PNG path on the same native macOS host."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
BASELINE = "7f9ba073394b77a908e0589447c6edc8d10b832c"
SCREENSHOT = "Sources/IlliquidNativePlayback/Presentation/NativeScreenshot.swift"
GEOMETRY = "Sources/IlliquidCore/Player/VideoPresentationGeometry.swift"
MODELS = "Sources/IlliquidCore/Player/PlaybackModels.swift"
LIBASS = "Sources/IlliquidNativePlayback/Subtitles/LibassContext.swift"
BUDGET = "Sources/IlliquidNativePlayback/Subtitles/SubtitleMemoryBudget.swift"
PRESENTER = "Sources/IlliquidNativePlayback/Presentation/SampleBufferVideoPresenter.swift"
SCENARIOS = ["bgra-1080p", "nv12-1080p", "p010-1080p", "bgra-4k", "subtitle-1080p"]


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def section(source: str, start: str, end: str) -> str:
    if source.count(start) != 1 or source.count(end) != 1:
        raise RuntimeError(f"Source extraction anchors changed: {start!r}; review the harness")
    first, last = source.index(start), source.index(end)
    if last <= first:
        raise RuntimeError("Source extraction boundaries are reversed")
    return source[first:last].rstrip() + "\n"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--iterations", type=int, default=6)
    parser.add_argument("--prepare-only", action="store_true")
    args = parser.parse_args()
    if not 2 <= args.pairs <= 12 or args.pairs % 2 or not 1 <= args.iterations <= 30:
        parser.error("pairs must be even in 2...12; iterations must be 1...30")
    if not args.prepare_only and sys.platform != "darwin":
        parser.error("Run on native macOS; --prepare-only stages sources without compiling")
    out = args.output.resolve()
    if out.exists() and any(out.iterdir()):
        parser.error("Use a new or empty output directory to preserve previous evidence")
    out.mkdir(parents=True, exist_ok=True)
    (out / "driver").mkdir()
    for name in ["run.py", "Harness.swift"]:
        (out / "driver" / name).write_bytes((HERE / name).read_bytes())
    environment = os.environ.copy()
    environment["CLANG_MODULE_CACHE_PATH"] = str(out / "module-cache")

    def run(argv: list[str | Path], log: Path | None = None, timeout: int = 600) -> str:
        command = [str(item) for item in argv]
        result = subprocess.run(command, cwd=ROOT, env=environment, capture_output=True,
                                text=True, timeout=timeout)
        if log:
            log.write_text(json.dumps(command) + "\n\n" + result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError(f"Command failed: {command!r}\n{result.stdout[-2000:]}\n{result.stderr[-6000:]}")
        return result.stdout

    receipt: dict = {
        "baseline_revision": BASELINE,
        "candidate_revision": run(["git", "rev-parse", "HEAD"]).strip(),
        "working_tree": run(["git", "status", "--short"]),
        "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "runner_sha256": sha256(Path(__file__).read_bytes()),
        "harness_sha256": sha256((HERE / "Harness.swift").read_bytes()),
        "pairs": args.pairs, "warm_iterations": args.iterations,
        "scenarios": SCENARIOS, "sources": {},
    }
    for variant in ["baseline", "candidate"]:
        folder = out / variant
        (folder / "sources/core").mkdir(parents=True)
        (folder / "sources/native").mkdir(parents=True)
        paths = [SCREENSHOT, GEOMETRY, MODELS, LIBASS, BUDGET, PRESENTER]
        sources = {path: run(["git", "show", f"{BASELINE}:{path}"])
                   if variant == "baseline" else (ROOT / path).read_text() for path in paths}
        adjustments = section(sources[MODELS], "public struct VideoAdjustmentState:",
                              "/// Curated, product-level filters")
        regions = section(sources[LIBASS], "struct ASSRenderedRegion:", "\nstruct ASSRenderResult:")
        error = section(sources[PRESENTER], "struct PresentationError:", "\nfunc checkOSStatus(")
        generated = {
            "sources/core/VideoPresentationGeometry.swift": sources[GEOMETRY],
            "sources/core/VideoAdjustmentState.swift": "import Foundation\n\n" + adjustments,
            "sources/native/NativeScreenshot.swift": sources[SCREENSHOT],
            "sources/native/SubtitleMemoryBudget.swift": sources[BUDGET],
            "sources/native/ScreenshotSupport.swift": "import Foundation\nimport CoreGraphics\n\n" + regions + "\n" + error,
        }
        for path, value in generated.items():
            (folder / path).write_text(value)
        receipt["sources"][variant] = {
            "input_sha256": {path: sha256(value.encode()) for path, value in sources.items()},
            "staged_sha256": {path: sha256(value.encode()) for path, value in generated.items()},
        }
    write_json(out / "receipt.json", receipt)
    if args.prepare_only:
        write_json(out / "completion.json", {"prepared": True, "compiled": False, "qualified": False})
        print("Source extraction prepared. Swift compilation and native execution were not run.", flush=True)
        return

    swiftc = run(["xcrun", "--find", "swiftc"]).strip()
    sdk = run(["xcrun", "--sdk", "macosx", "--show-sdk-path"]).strip()
    native_environment = {
        "platform": platform.platform(), "architecture": platform.machine(),
        "macos": run(["sw_vers"]).strip(), "compiler": run([swiftc, "--version"]).strip(),
        "cpu": run(["sysctl", "-n", "machdep.cpu.brand_string"]).strip(), "sdk": sdk,
        "developer_dir": environment.get("DEVELOPER_DIR"),
        "scope": "Complete offscreen PNG screenshot component, not interactive latency or playback CPU",
        "memory_scope": "Darwin process RSS; GPU/device allocations and long-term cache residence are not comprehensive",
    }
    write_json(out / "environment.json", native_environment)
    flags = ["-swift-version", "6", "-O", "-whole-module-optimization", "-parse-as-library",
             "-warnings-as-errors", "-module-cache-path", out / "module-cache",
             "-target", f"{platform.machine()}-apple-macosx26.0", "-sdk", sdk]
    receipt["compiler_flags"] = [str(value) for value in flags]
    binaries = {}
    for variant in ["baseline", "candidate"]:
        print(f"Compiling {variant}", flush=True)
        folder = out / variant
        core = sorted((folder / "sources/core").glob("*.swift"))
        native = sorted((folder / "sources/native").glob("*.swift"))
        run([swiftc, *flags, "-module-name", "IlliquidCore", "-emit-module", "-emit-module-path", folder / "IlliquidCore.swiftmodule",
             "-emit-object", *core, "-o", folder / "IlliquidCore.o"], folder / "compile-core.log")
        binary = folder / "screenshot-benchmark"
        run([swiftc, *flags, "-I", folder, "-module-name", "ScreenshotContextQualification",
             *native, HERE / "Harness.swift", folder / "IlliquidCore.o", "-o", binary], folder / "compile-harness.log")
        binaries[variant] = binary
        receipt["sources"][variant]["binary_sha256"] = sha256(binary.read_bytes())
    write_json(out / "receipt.json", receipt)

    decoded, verification_receipts = {}, {}
    for variant, binary in binaries.items():
        folder = out / variant / "verification"
        folder.mkdir()
        run([binary, "--verify", folder], out / f"verification-{variant}.log", timeout=180)
        verification_receipts[variant] = json.loads((folder / "verification.json").read_text())
        native_receipt = verification_receipts[variant]
        if (not native_receipt.get("cases") or not native_receipt.get("mixed_sequence_replay_equal")
                or native_receipt.get("concurrent_captures") != len(native_receipt["cases"])
                or not all(case.get("concurrent_equal") for case in native_receipt["cases"])):
            raise RuntimeError("Native sequential/concurrent verification did not complete")
        decoded[variant] = {str(path.relative_to(folder)): path for path in sorted(folder.rglob("*.bin"))}
        if len(decoded[variant]) != len(native_receipt["cases"]):
            raise RuntimeError("Decoded RGBA inventory does not match native verification receipt")
        for index, case in enumerate(native_receipt["cases"]):
            frame = decoded[variant].get(f"{index}-{case['case']}.bin")
            if frame is None:
                raise RuntimeError("Missing decoded RGBA frame from verification receipt")
            pixels = frame.read_bytes()
            if (len(pixels) != case["width"] * case["height"] * 4
                    or sha256(pixels) != case["rgba_sha256"]):
                raise RuntimeError("Decoded RGBA dimensions/hash do not match native verification receipt")
    if verification_receipts["baseline"] != verification_receipts["candidate"]:
        raise RuntimeError("Baseline/candidate decoded dimensions, metadata or verification receipts differ")
    if decoded["baseline"].keys() != decoded["candidate"].keys():
        raise RuntimeError("Baseline/candidate decoded frame inventories differ")
    verified = []
    for name, path in decoded["baseline"].items():
        baseline, candidate = path.read_bytes(), decoded["candidate"][name].read_bytes()
        if not baseline or baseline != candidate:
            raise RuntimeError(f"Decoded RGBA mismatch: {name}")
        verified.append({"file": name, "bytes": len(baseline), "sha256": sha256(baseline)})
    verification = {"passed": True, "frames": verified,
                    "comparison": "Exact decoded canonical RGBA bytes, dimensions, color metadata and concurrent/replay receipts",
                    "native_receipt": verification_receipts["candidate"]}
    write_json(out / "verification.json", verification)
    print(f"Exact decoded-output parity: {len(verified)} frames", flush=True)

    rows, summaries = [], []
    for mode in ["first", "warm"]:
        for scenario in SCENARIOS:
            current, wall_ratios, cpu_ratios = [], [], []
            for pair in range(args.pairs):
                order = ["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]
                paired = {}
                for position, variant in enumerate(order):
                    count = 1 if mode == "first" else args.iterations
                    command = [binaries[variant], f"--{mode}", scenario]
                    if mode == "warm":
                        command.append(str(count))
                    row = json.loads(run(command, timeout=180))
                    if (row.get("scenario") != scenario or row.get("mode") != mode
                            or row.get("operation_count") != count
                            or row.get("wall_ns", 0) <= 0 or row.get("cpu_ns", 0) <= 0
                            or len(row.get("png_sizes", [])) != count
                            or any(not isinstance(value, int) or value <= 0 for value in row["png_sizes"])
                            or "checksum" not in row):
                        raise RuntimeError(f"Invalid measurement: {row!r}")
                    row.update(variant=variant, pair=pair, position=position, sequence=len(rows))
                    paired[variant] = row
                    current.append(row)
                    rows.append(row)
                    with (out / "measurements.jsonl").open("a") as stream:
                        stream.write(json.dumps(row, sort_keys=True) + "\n")
                if paired["baseline"]["png_sizes"] != paired["candidate"]["png_sizes"]:
                    raise RuntimeError(f"Timed PNG lengths differ for {mode}/{scenario}")
                if paired["baseline"]["checksum"] != paired["candidate"]["checksum"]:
                    raise RuntimeError(f"Timed result checksums differ for {mode}/{scenario}")
                wall_ratios.append(paired["candidate"]["wall_ns"] / paired["baseline"]["wall_ns"])
                cpu_ratios.append(paired["candidate"]["cpu_ns"] / paired["baseline"]["cpu_ns"])
            result = {"scenario": scenario, "mode": mode, "pairs": args.pairs,
                      "operation_count": 1 if mode == "first" else args.iterations,
                      "wall_reduction_percent": 100 * (1 - statistics.median(wall_ratios)),
                      "cpu_reduction_percent": 100 * (1 - statistics.median(cpu_ratios))}
            for variant in binaries:
                observations = [row for row in current if row["variant"] == variant]
                result[variant] = {}
                for metric in ["wall_ns", "cpu_ns"]:
                    values = [row[metric] / row["operation_count"] for row in observations]
                    result[variant][metric + "_per_capture"] = {
                        "median": statistics.median(values), "min": min(values), "max": max(values),
                    }
                # Harness memory fields are kept raw. Aggregate any numeric RSS
                # field without implying that peak/current/device metrics agree.
                for key in sorted(observations[0]):
                    if ("rss" in key or "resident" in key) and all(isinstance(row[key], (int, float)) for row in observations):
                        result[variant][key + "_median"] = statistics.median(row[key] for row in observations)
            result["wall_saved_ms"] = (result["baseline"]["wall_ns_per_capture"]["median"]
                                       - result["candidate"]["wall_ns_per_capture"]["median"]) / 1e6
            summaries.append(result)
            write_json(out / "summary.json", summaries)
            print(f"{mode}/{scenario}: wall {result['wall_reduction_percent']:.1f}%, "
                  f"CPU {result['cpu_reduction_percent']:.1f}%, {result['wall_saved_ms']:.3f} ms saved", flush=True)
    completion = {"completed_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                  "compiled": True, "exact_output_parity": True, "benchmark_complete": True,
                  "observations": len(rows), "timed_wall_seconds": sum(row["wall_ns"] for row in rows) / 1e9,
                  "performance_acceptance": "Review against predeclared README criteria; no timing assertion in CI"}
    write_json(out / "completion.json", completion)
    print(f"Complete: {len(rows)} fresh-process observations", flush=True)


if __name__ == "__main__":
    main()
