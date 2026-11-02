#!/usr/bin/env python3
"""Qualify the exact batch-open selection computation in separate Swift modules."""
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
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
CONTROLLER = "Sources/IlliquidPlayer/Player/PlaybackController.swift"
SOURCES = (
    "Sources/IlliquidCore/Playlist/FolderPlaylist.swift",
    "Sources/IlliquidCore/Playlist/PlaylistMutation.swift",
    "Sources/IlliquidCore/Utilities/NormalizedFileURL.swift",
    "Sources/IlliquidCore/Utilities/NaturalFilenameOrdering.swift",
)
VARIANTS = ("baseline", "candidate")
MAX_ITERATIONS = 10_000_000
BLOCK_START = "        let selectedIndex = PlaylistMutation.indexPreservingCurrentIdentity("
BLOCK_END = "        // Stop/window-close retains playlist metadata"
METHOD = "    private func applyOpenPlan("


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_json(path: Path, value) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def append_json(path: Path, value) -> None:
    with path.open("a") as handle:
        handle.write(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n")


def extract(source: bytes, variant: str) -> tuple[bytes, dict]:
    text = source.decode("utf-8")
    if text.count(METHOD) != 1:
        raise RuntimeError(f"{variant}: applyOpenPlan marker is not unique")
    method = text.index(METHOD)
    following = text.find("\n    private func ", method + len(METHOD))
    region = text[method:following if following != -1 else len(text)]
    if region.count(BLOCK_START) != 1 or region.count(BLOCK_END) != 1:
        raise RuntimeError(f"{variant}: selection block markers are not unique")
    start, end = region.index(BLOCK_START), region.index(BLOCK_END)
    if end <= start:
        raise RuntimeError(f"{variant}: invalid selection block boundaries")
    body = region[start:end]
    symbol = "preservedCurrent" if variant == "baseline" else "preservesCurrent"
    if body.count(f"let {symbol} =") != 1:
        raise RuntimeError(f"{variant}: expected preservation result was not found")
    expression = "preservedCurrent != nil" if variant == "baseline" else "preservesCurrent"
    prefix = """import Foundation

public struct BatchOpenSelectionResult: Equatable {
    public let selectedIndex: Int?
    public let preservesCurrent: Bool
}

public enum BatchOpenSelection {
    @inline(never)
    public static func select(
        currentURL: URL?, items: [FolderPlaylistItem]
    ) -> BatchOpenSelectionResult {
"""
    suffix = (
        "        return BatchOpenSelectionResult(\n"
        f"            selectedIndex: selectedIndex, preservesCurrent: {expression}\n"
        "        )\n    }\n}\n"
    )
    return (prefix + body + suffix).encode(), {
        "first_line": text.count("\n", 0, method + start) + 1,
        "last_line": text.count("\n", 0, method + end),
        "body_sha256": sha(body.encode()),
        "body": body,
    }


def select_sources(baseline: dict, current: dict, regression_only: bool) -> dict:
    """Keep the historical focal block; share one captured support snapshot."""
    if not regression_only:
        for path in SOURCES:
            if current[path] != baseline[path]:
                raise RuntimeError(f"Shared dependency changed since baseline: {path}")
    return {
        "baseline": {**(current if regression_only else baseline),
                     CONTROLLER: baseline[CONTROLLER]},
        "candidate": dict(current),
    }


def validate_verification(value: dict) -> None:
    records = value.get("results")
    if (value.get("status") != "passed" or value.get("checks") != 2102
            or not isinstance(records, list) or len(records) != 2102
            or len({record["label"] for record in records}) != 2102):
        raise RuntimeError("Incomplete verification corpus")
    checksum = 0
    for record in records:
        index = record["selectedIndex"]
        if (index is not None and (type(index) is not int or index < 0)
                or type(record["preservesCurrent"]) is not bool):
            raise RuntimeError("Malformed verification result")
        checksum += ((0 if index is None else index + 1) << 1) | int(record["preservesCurrent"])
    if value.get("checksum") != checksum:
        raise RuntimeError("Verification checksum disagrees with exact output")


def negative_source(wrapper: bytes, field: str) -> bytes:
    before, after = {
        "selectedIndex": (b"selectedIndex: selectedIndex,", b"selectedIndex: nil,"),
        "preservesCurrent": (b"preservesCurrent: preservesCurrent\n",
                             b"preservesCurrent: false\n"),
    }[field]
    if wrapper.count(before) != 1:
        raise RuntimeError(f"Negative control marker is not unique: {field}")
    return wrapper.replace(before, after)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--regression-only", action="store_true",
                        help="Historical selection oracle with identical current support; no timings")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--pairs", type=int, default=8)
    parser.add_argument("--target-ms", type=float, default=50)
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2:
        parser.error("--pairs must be positive and even, with at least two pairs")
    if not math.isfinite(args.target_ms) or args.target_ms <= 0:
        parser.error("--target-ms must be finite and positive")
    if Path("/Volumes/seed1/Projects/kyoto/kyoto.py").is_file():
        parser.error(
            "Kyoto is available; submit builds through the shared queue. "
            "This direct-build runner is intended for isolated CI."
        )
    print(
        "Kyoto is unavailable; compiling serially in this isolated checkout.",
        flush=True,
    )
    swift = shutil.which("swiftc")
    if not swift:
        parser.error("swiftc was not found")
    output = args.output.resolve()
    if output.exists() and (not output.is_dir() or any(output.iterdir())):
        parser.error("--output must be a new or empty directory")
    output.mkdir(parents=True, exist_ok=True)
    logs = output / "logs"
    logs.mkdir()
    state = {
        "status": "running",
        "mode": "current-source-regression" if args.regression_only else "historical-performance",
        "timings_collected": False,
        "negative_controls": {},
        **({} if args.regression_only else {"pairs": args.pairs, "target_ms": args.target_ms}),
        "verification": {},
        "summaries": [],
        "full_controller_compiled": False,
        "ui_qualified": False,
    }

    def run(command, name: str, timeout: int = 600, *, expect_rejection: bool = False) -> bytes:
        argv = list(map(str, command))
        started = time.monotonic()
        process = subprocess.Popen(
            argv, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE
        )
        timed_out = False
        try:
            stdout, stderr = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            process.kill()
            stdout, stderr = process.communicate()
        (logs / f"{name}.log").write_bytes(stdout + stderr)
        append_json(output / "commands.jsonl", {
            "name": name, "command": argv, "cwd": str(ROOT), "pid": process.pid,
            "exit_code": process.returncode, "timed_out": timed_out,
            **({} if args.regression_only else {"wall_seconds": time.monotonic() - started}),
        })
        if expect_rejection:
            if timed_out or process.returncode == 0 or b"incorrectResult" not in stdout + stderr:
                raise RuntimeError(f"{name}: control was not rejected by the correctness oracle")
            return stdout + stderr
        if timed_out or process.returncode:
            print((stdout + stderr).decode(errors="replace")[-20_000:], flush=True)
            raise RuntimeError(f"{name} failed; see logs/{name}.log")
        return stdout

    def run_json(command, name: str):
        return json.loads(run(command, name))

    def observe(binary: Path, workload: dict, iterations: int, name: str) -> dict:
        value = run_json([binary, "measure", workload["id"], iterations], name)
        if (value.get("workload") != workload
                or value.get("iterations") != iterations
                or type(value.get("preservesCurrent")) is not bool
                or type(value.get("checksum")) is not int
                or value["checksum"] < 0
                or type(value.get("wall_ns")) is not int
                or value["wall_ns"] <= 0):
            raise RuntimeError(f"{name}: malformed measurement")
        selected = value.get("selectedIndex")
        if selected is not None and type(selected) is not int:
            raise RuntimeError(f"{name}: malformed selected index")
        return value

    try:
        manifest = {
            "baseline_commit": BASELINE,
            "mode": state["mode"],
            "support_policy": "identical-current" if args.regression_only else "historical-byte-identical",
            "candidate_commit": run(["git", "rev-parse", "HEAD"], "head").decode().strip(),
            "candidate_status": run(["git", "status", "--short"], "status").decode(),
            "swift": run([swift, "--version"], "swift-version").decode().strip(),
            "platform": platform.uname()._asdict(),
            "python": sys.version,
            "environment": {key: os.environ.get(key) for key in (
                "DEVELOPER_DIR", "LANG", "LC_ALL", "LC_COLLATE",
                "SWIFT_DETERMINISTIC_HASHING",
            )},
            "scope": "Exact extracted selection-plus-preservation computation",
            "module_policy": "Separate dynamic production module; no cross-module optimization",
            "process_policy": ("Fresh process for each verification" if args.regression_only else
                               "Fresh process for each verification, calibration and timed sample"),
            "full_controller_compiled": False, "ui_qualified": False,
            "sources": {}, "builds": {},
        }
        if sys.platform == "darwin":
            manifest["macos"] = run(["sw_vers"], "macos-version").decode().strip()
            manifest["xcode"] = run(["xcodebuild", "-version"], "xcode-version").decode().strip()
            manifest["cpu"] = run(
                ["sysctl", "-n", "machdep.cpu.brand_string"], "cpu"
            ).decode().strip()
        support = output / "sources" / "qualification"
        support.mkdir(parents=True)
        for filename in ("Harness.swift", "run.py"):
            data = (HERE / filename).read_bytes()
            (support / filename).write_bytes(data)
            manifest["sources"][f"qualification/{filename}"] = {"sha256": sha(data)}

        baseline_sources = {}
        for index, path in enumerate((*SOURCES, CONTROLLER)):
            baseline_sources[path] = run(
                ["git", "show", f"{BASELINE}:{path}"], f"baseline-source-{index}"
            )
        current_sources = {path: (ROOT / path).read_bytes() for path in (*SOURCES, CONTROLLER)}
        selected_sources = select_sources(baseline_sources, current_sources, args.regression_only)
        manifest["historical_support_sha256"] = {
            path: sha(baseline_sources[path]) for path in SOURCES
        }

        snapshots = {}
        for variant in VARIANTS:
            folder = output / "sources" / variant
            folder.mkdir(parents=True)
            snapshots[variant] = []
            for path in (*SOURCES, CONTROLLER):
                data = selected_sources[variant][path]
                target = folder / Path(path).name
                target.write_bytes(data)
                manifest["sources"][f"{variant}/{target.name}"] = {
                    "path": path, "sha256": sha(data),
                    "origin": (BASELINE if variant == "baseline"
                               and (path == CONTROLLER or not args.regression_only) else "working-tree"),
                }
                if path in SOURCES:
                    snapshots[variant].append(target)
            wrapper, extraction = extract((folder / "PlaybackController.swift").read_bytes(), variant)
            (folder / "SelectionBody.swift.txt").write_text(extraction.pop("body"))
            generated = folder / "BatchOpenSelection.swift"
            generated.write_bytes(wrapper)
            snapshots[variant].append(generated)
            manifest["sources"][f"{variant}/BatchOpenSelection.swift"] = {
                "sha256": sha(wrapper), "extraction": extraction,
            }
        write_json(output / "manifest.json", manifest)

        binaries = {}
        expected_verification = None
        for configuration in ("debug", "release"):
            for variant in VARIANTS:
                label = f"{variant}-{configuration}"
                build = output / "build" / label
                build.mkdir(parents=True)
                cache = build / "module-cache"
                flags = ["-swift-version", "6", "-module-cache-path", str(cache)]
                flags += ["-Onone"] if configuration == "debug" else ["-O", "-whole-module-optimization"]
                extension = "dylib" if sys.platform == "darwin" else "so"
                library = build / f"libBatchOpenComponent.{extension}"
                module_command = [
                    swift, *flags, "-emit-module", "-emit-library",
                    "-module-name", "BatchOpenComponent", "-emit-module-path",
                    build / "BatchOpenComponent.swiftmodule", *snapshots[variant],
                    "-o", library,
                ]
                if sys.platform == "darwin":
                    module_command += [
                        "-Xlinker", "-install_name", "-Xlinker",
                        "@rpath/libBatchOpenComponent.dylib",
                    ]
                run(module_command, f"{label}-module")
                binary = build / "benchmark"
                rpath = "@loader_path" if sys.platform == "darwin" else "$ORIGIN"
                run([
                    swift, *flags, "-parse-as-library", "-I", build, "-L", build,
                    "-lBatchOpenComponent", "-Xlinker", "-rpath", "-Xlinker", rpath,
                    support / "Harness.swift", "-o", binary,
                ], f"{label}-driver")
                manifest["builds"][label] = {
                    "flags": flags, "binary_sha256": sha(binary.read_bytes()),
                    "library_sha256": sha(library.read_bytes()),
                }
                write_json(output / "manifest.json", manifest)
                verification = run_json([binary, "verify"], f"{label}-verify")
                validate_verification(verification)
                write_json(output / f"verification-{label}.json", verification)
                if expected_verification is None:
                    expected_verification = verification
                elif verification != expected_verification:
                    raise RuntimeError(f"{label}: verification output differs")
                state["verification"][label] = verification
                write_json(output / "summary.json", state)
                print("VERIFY_RESULT " + json.dumps({"build": label, **verification}), flush=True)
                if configuration == "release":
                    binaries[variant] = binary

                    if variant == "candidate":
                        for field in ("selectedIndex", "preservesCurrent"):
                            control = output / "negative-controls" / field
                            control.mkdir(parents=True)
                            source = control / "BatchOpenSelection.swift"
                            source.write_bytes(negative_source(snapshots[variant][-1].read_bytes(), field))
                            control_command = [
                                str(part).replace(str(build), str(control))
                                if str(part).startswith(str(build)) else str(part)
                                for part in module_command
                            ]
                            control_command[control_command.index(str(snapshots[variant][-1]))] = str(source)
                            run(control_command, f"negative-{field}-module")
                            control_binary = control / "benchmark"
                            run([
                                swift, *flags, "-parse-as-library", "-I", control, "-L", control,
                                "-lBatchOpenComponent", "-Xlinker", "-rpath", "-Xlinker", rpath,
                                support / "Harness.swift", "-o", control_binary,
                            ], f"negative-{field}-driver")
                            rejection = run([control_binary, "verify"], f"negative-{field}-verify",
                                            expect_rejection=True)
                            state["negative_controls"][field] = {
                                "status": "rejected", "source_sha256": sha(source.read_bytes()),
                                "binary_sha256": sha(control_binary.read_bytes()),
                                "library_sha256": sha((control / library.name).read_bytes()),
                                "rejection_sha256": sha(rejection),
                            }

        workloads = run_json([binaries["baseline"], "list"], "baseline-workloads")
        if (not isinstance(workloads, list) or not workloads
                or len({case["id"] for case in workloads}) != len(workloads)
                or workloads != run_json([binaries["candidate"], "list"], "candidate-workloads")):
            raise RuntimeError("Workload definitions are missing or inconsistent")
        write_json(output / "workloads.json", workloads)

        if len(workloads) != 20:
            raise RuntimeError("Workload corpus count changed")
        if args.regression_only:
            state["status"] = "passed"
            state["workloads"] = len(workloads)
            print("REGRESSION_PASS " + json.dumps({
                "configurations_verified": len(state["verification"]),
                "checks_per_configuration": expected_verification["checks"],
                "workloads": len(workloads), "negative_controls": state["negative_controls"],
                "timings_collected": False,
            }), flush=True)
            return

        state["timings_collected"] = True
        for case_index, case in enumerate(workloads):
            per_call = {}
            order = VARIANTS if case_index % 2 == 0 else tuple(reversed(VARIANTS))
            for variant in order:
                iterations = 1
                attempt = 0
                while True:
                    name = f"calibrate-{case_index}-{variant}-{attempt}"
                    result = observe(binaries[variant], case, iterations, name)
                    append_json(output / "calibration.jsonl", {
                        "variant": variant, "attempt": attempt, **result,
                    })
                    if result["wall_ns"] >= 10_000_000 or iterations == MAX_ITERATIONS:
                        per_call[variant] = result["wall_ns"] / iterations
                        break
                    iterations = min(MAX_ITERATIONS, max(
                        iterations + 1, math.ceil(iterations * 10_000_000 / result["wall_ns"])
                    ))
                    attempt += 1
            iterations = min(MAX_ITERATIONS, max(1, math.ceil(
                args.target_ms * 1_000_000 / statistics.mean(per_call.values())
            )))
            samples = {variant: [] for variant in VARIANTS}
            for pair in range(args.pairs):
                order = VARIANTS if pair % 2 == 0 else tuple(reversed(VARIANTS))
                observed = {}
                for position, variant in enumerate(order):
                    result = observe(
                        binaries[variant], case, iterations,
                        f"measure-{case_index}-{pair}-{variant}",
                    )
                    observed[variant] = result
                    samples[variant].append(result["wall_ns"] / iterations)
                    append_json(output / "measurements.jsonl", {
                        "variant": variant, "pair": pair, "position": position,
                        "order": "AB" if pair % 2 == 0 else "BA", **result,
                    })
                fields = ("selectedIndex", "preservesCurrent", "checksum")
                if any(observed["baseline"].get(key) != observed["candidate"].get(key) for key in fields):
                    raise RuntimeError(f"Timed output mismatch: {case['id']}, pair {pair}")
            baseline_ns = statistics.median(samples["baseline"])
            candidate_ns = statistics.median(samples["candidate"])
            paired = [a / b for a, b in zip(samples["baseline"], samples["candidate"])]
            summary = {
                "workload": case, "pairs": args.pairs, "iterations": iterations,
                "baseline_ms_per_call": baseline_ns / 1_000_000,
                "candidate_ms_per_call": candidate_ns / 1_000_000,
                "paired_speedup_median": statistics.median(paired),
                "paired_speedup_range": [min(paired), max(paired)],
                "reduction_percent": 100 * (1 - candidate_ns / baseline_ns),
            }
            state["summaries"].append(summary)
            write_json(output / "summary.json", state)
            print("BENCHMARK_RESULT " + json.dumps(summary, separators=(",", ":")), flush=True)
        state["status"] = "passed"
        print("QUALIFICATION_PASS " + json.dumps({
            "configurations_verified": len(state["verification"]),
            "checks_per_configuration": expected_verification["checks"],
            "workloads": len(workloads), "pairs": args.pairs,
            "full_controller_compiled": False, "ui_qualified": False,
        }), flush=True)
    except BaseException as error:
        state["status"] = "failed"
        state["error"] = f"{type(error).__name__}: {error}"
        raise
    finally:
        write_json(output / "summary.json", state)


if __name__ == "__main__":
    main()
