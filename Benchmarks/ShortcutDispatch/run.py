#!/usr/bin/env python3
"""Build and qualify the real shortcut dispatcher in isolation from the player.

On macOS this uses AppKit/SwiftUI and the unmodified production declarations.
Linux uses small platform value stubs, retaining Foundation and Observation.
Timing binaries link a separately optimized production module so the harness
cannot inline or hoist the dispatcher across repeated synthetic key events.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import shutil
import statistics
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BINDINGS = Path("Sources/IlliquidApp/App/PlayerShortcutBindings.swift")
APP_MODEL = Path("Sources/IlliquidApp/App/AppModel.swift")
TESTS = ("PlayerShortcutBindingsTests.swift", "PlayerShortcutDispatchTests.swift")
NATIVE = sys.platform == "darwin"
# Scale short paths so optimized candidate intervals are typically >= 10 ms.
# Both variants execute the same count; --iterations is the base count.
ITERATION_FACTORS = {
    "head-hit": 30, "seek-repeat": 8, "late-hit": 2, "unmatched": 2,
    "fallback": 3, "modifiers": 4, "question-layout": 3,
    "mixed": 1, "cached-remap": 1, "construction": 1,
}


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def command(args: list[str], log: Path, *, cwd: Path | None = None) -> str:
    log.parent.mkdir(parents=True, exist_ok=True)
    environment = dict(os.environ)
    # SwiftPM manifests also compile C shims. Keep their caches writable without
    # changing HOME or depending on a pre-existing toolchain cache.
    environment.setdefault("CLANG_MODULE_CACHE_PATH", str(log.parent / "module-cache"))
    environment.setdefault("SWIFTPM_MODULECACHE_OVERRIDE", str(log.parent / "module-cache"))
    result = subprocess.run(args, cwd=cwd, text=True, capture_output=True, env=environment)
    log.write_text(json.dumps(args) + "\n\n" + result.stdout + result.stderr)
    if result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}); see {log}\n{result.stderr[-6000:]}")
    return result.stdout


def portable(text: str) -> str:
    if NATIVE:
        return text
    return text.replace("import AppKit\n", "import Foundation\n").replace("import SwiftUI\n", "")


def action_declaration(app_model: str) -> str:
    start = "enum PlayerKeyboardAction: Equatable {"
    end = "\nenum PlayerKeyboardRouting {"
    if app_model.count(start) != 1 or app_model.count(end) != 1:
        raise RuntimeError("Action extraction anchors changed; review the isolated harness")
    return "import Foundation\nimport AppKit\n\n" + app_model[
        app_model.index(start):app_model.index(end)
    ]


def source_inputs(variant: str) -> dict[str, bytes]:
    manifest = json.loads((HERE / "baseline/manifest.json").read_text())
    baseline = (HERE / "baseline/PlayerShortcutBindings.swift").read_bytes()
    actions = (HERE / "baseline/PlayerKeyboardAction.swift").read_bytes()
    if digest(baseline) != manifest["bindings_sha256"] or digest(actions) != manifest["actions_sha256"]:
        raise RuntimeError("Pinned baseline source does not match its manifest")
    current_actions = action_declaration((ROOT / APP_MODEL).read_text()).encode()
    if current_actions != actions:
        raise RuntimeError("PlayerKeyboardAction changed since the baseline; requalify this comparison")
    return {
        "PlayerShortcutBindings.swift": baseline if variant == "baseline" else (ROOT / BINDINGS).read_bytes(),
        "PlayerKeyboardAction.swift": actions,
        "PlatformStubs.swift": (HERE / "PlatformStubs.swift").read_bytes(),
    }


def prepare(variant: str, directory: Path) -> dict[str, object]:
    directory.mkdir(parents=True, exist_ok=True)
    inputs = source_inputs(variant)
    receipt = {"variant": variant, "platform": "native-appkit" if NATIVE else "linux-value-stubs", "sources": {}}
    for name, data in inputs.items():
        portable_source = portable(data.decode())
        generated = portable_source
        if name == "PlayerShortcutBindings.swift":
            # This component has no app/session preference context. Tests and
            # benchmarks inject their own store; retain the legacy default for
            # the extracted initializer without changing dispatch logic.
            generated = generated.replace(
                "init(defaults: UserDefaults = AppPreferences.defaults)",
                "init(defaults: UserDefaults = .standard)")
        preference_adaptation = generated != portable_source
        generated = generated.encode()
        (directory / name).write_bytes(generated)
        receipt["sources"][name] = {
            "input_sha256": digest(data), "compiled_sha256": digest(generated),
            "import_adaptation": data.decode() != portable_source,
            "preference_default_adaptation": preference_adaptation,
        }
    return receipt


def compiler() -> str:
    selected = os.environ.get("SWIFTC") or shutil.which("swiftc")
    if not selected:
        raise RuntimeError("swiftc is required; set SWIFTC or put the Swift toolchain on PATH")
    return selected


def swift_tool() -> str:
    selected = os.environ.get("SWIFT") or shutil.which("swift")
    if not selected:
        candidate = Path(compiler()).parent / "swift"
        if candidate.exists():
            selected = str(candidate)
    if not selected:
        raise RuntimeError("swift is required for component tests")
    return selected


def build(variant: str, out: Path) -> Path:
    folder = out / variant
    sources = folder / "sources"
    receipt = prepare(variant, sources)
    compiler_path = compiler()
    extension = "dylib" if NATIVE else "so"
    library = folder / f"libIlliquidApp.{extension}"
    flags = ["-swift-version", "6", "-O", "-whole-module-optimization",
             "-warnings-as-errors", "-module-cache-path", str(out / "module-cache")]
    if NATIVE:
        flags += ["-target", f"{platform.machine()}-apple-macosx26.0"]
    module_args = [compiler_path, *flags, "-emit-library", "-emit-module", "-enable-testing",
                   "-module-name", "IlliquidApp", "-emit-module-path", str(folder / "IlliquidApp.swiftmodule"),
                   "-o", str(library), *map(str, sorted(sources.glob("*.swift")))]
    command(module_args, folder / "build-module.log")
    executable = folder / "shortcut-dispatch"
    driver_args = [compiler_path, *flags, "-parse-as-library", "-I", str(folder), "-L", str(folder),
                   "-lIlliquidApp", "-Xlinker", "-rpath", "-Xlinker", str(folder),
                   str(HERE / "Harness.swift"), "-o", str(executable)]
    command(driver_args, folder / "build-harness.log")
    receipt.update({
        "compiler": command([compiler_path, "--version"], folder / "compiler.log").strip(),
        "module_command": module_args, "harness_command": driver_args,
        "harness_sha256": digest((HERE / "Harness.swift").read_bytes()),
        "runner_sha256": digest(Path(__file__).read_bytes()),
        "library_sha256": digest(library.read_bytes()),
        "executable_sha256": digest(executable.read_bytes()),
    })
    write_json(folder / "manifest.json", receipt)
    return executable


def test(variant: str, configuration: str, out: Path) -> None:
    folder = out / f"{variant}-{configuration}"
    sources = folder / "Sources/IlliquidApp"
    receipt = prepare(variant, sources)
    tests = folder / "Tests/IlliquidAppTests"
    tests.mkdir(parents=True, exist_ok=True)
    for name in TESTS:
        data = (ROOT / "Tests/IlliquidAppTests" / name).read_bytes()
        generated = portable(data.decode()).encode()
        (tests / name).write_bytes(generated)
        receipt["sources"][name] = {"input_sha256": digest(data), "compiled_sha256": digest(generated)}
    (folder / "Package.swift").write_text('''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "ShortcutDispatchQualification", platforms: [.macOS("26.0")], targets: [
    .target(name: "IlliquidApp"),
    .testTarget(name: "IlliquidAppTests", dependencies: ["IlliquidApp"])
])
''')
    args = [swift_tool(), "test", "--package-path", str(folder), "--configuration", configuration,
            "--jobs", "2", "--cache-path", str(out / "package-cache"),
            "--config-path", str(out / "package-config"), "--security-path", str(out / "package-security"),
            "-Xswiftc", "-warnings-as-errors"]
    if not NATIVE:
        # Avoid the standalone driver's child-process statistics path, which
        # fails in restricted Linux PID namespaces. Compiler/test logic is unchanged.
        args.append("--use-integrated-swift-driver")
    log = folder / "tests.log"
    command(args, log)
    receipt["test_command"] = args
    receipt["test_log_sha256"] = digest(log.read_bytes())
    write_json(folder / "manifest.json", receipt)
    print(f"PASS {variant} {configuration}: {log}", flush=True)


def summarize(rows: list[dict[str, object]]) -> list[dict[str, object]]:
    summaries = []
    for workload in dict.fromkeys(row["workload"] for row in rows):
        selected = [row for row in rows if row["workload"] == workload]
        values = {}
        for variant in ("baseline", "candidate"):
            samples = [row["elapsed_ns"] / row["operations"] for row in selected if row["variant"] == variant]
            values[variant] = {"median_ns": statistics.median(samples), "min_ns": min(samples),
                               "max_ns": max(samples), "samples": len(samples)}
        ratios = []
        for round_index in sorted({row["round"] for row in selected}):
            pair = {row["variant"]: row for row in selected if row["round"] == round_index}
            a, b = pair["baseline"], pair["candidate"]
            if a["operations"] != b["operations"] or a["checksum"] != b["checksum"]:
                raise RuntimeError(f"Timing receipt differs for {workload} round {round_index}")
            ratios.append((b["elapsed_ns"] / b["operations"]) / (a["elapsed_ns"] / a["operations"]))
        values.update({"workload": workload, "change_percent":
                       (values["candidate"]["median_ns"] / values["baseline"]["median_ns"] - 1) * 100,
                       "paired_ratio_median": statistics.median(ratios), "paired_ratios": ratios})
        summaries.append(values)
    return summaries


def benchmark(out: Path, rounds: int, iterations: int) -> None:
    binaries = {variant: build(variant, out / "build") for variant in ("baseline", "candidate")}
    verification = {}
    workloads = None
    for variant, executable in binaries.items():
        verification[variant] = json.loads(command([str(executable), "verify"], out / f"verify-{variant}.log"))
        listed = json.loads(command([str(executable), "list"], out / f"list-{variant}.log"))["workloads"]
        if workloads is not None and listed != workloads:
            raise RuntimeError("Baseline and candidate workloads differ")
        workloads = listed
    if verification["baseline"] != verification["candidate"]:
        raise RuntimeError("Baseline and candidate differential receipts differ; inspect verify logs")
    write_json(out / "verification.json", verification["candidate"])
    rows = []
    with (out / "measurements.jsonl").open("w") as receipt_file:
        for round_index in range(rounds):
            for index, workload in enumerate(workloads):
                # Each workload gets equal AB/BA pairs with the default even round count.
                order = ("baseline", "candidate") if (round_index + index) % 2 == 0 else ("candidate", "baseline")
                pair = []
                for variant in order:
                    count = min(iterations, 500) if workload.startswith("construct") else iterations * ITERATION_FACTORS[workload]
                    log = out / "processes" / f"{round_index:02d}-{workload}-{variant}.log"
                    args = [str(binaries[variant]), "benchmark", workload, str(count)]
                    row = json.loads(command(args, log))
                    if row["workload"] != workload or row["operations"] <= 0 or row["elapsed_ns"] <= 0:
                        raise RuntimeError(f"Invalid benchmark receipt: {row}")
                    row.update({"variant": variant, "round": round_index, "order": list(order),
                                "command": args, "process_log_sha256": digest(log.read_bytes())})
                    receipt_file.write(json.dumps(row, sort_keys=True) + "\n")
                    receipt_file.flush()
                    rows.append(row)
                    pair.append(row)
                if pair[0]["operations"] != pair[1]["operations"] or pair[0]["checksum"] != pair[1]["checksum"]:
                    raise RuntimeError(f"Mismatched result in timing pair: {workload}")
            print(f"Completed paired round {round_index + 1}/{rounds}", flush=True)
    summary = summarize(rows)
    write_json(out / "summary.json", summary)
    write_json(out / "environment.json", {
        "recorded_utc": datetime.now(timezone.utc).isoformat(), "platform": platform.platform(),
        "machine": platform.machine(), "cpu_count": os.cpu_count(), "python": sys.version,
        "native_appkit": NATIVE, "rounds": rounds, "iterations": iterations,
        "iteration_factors": ITERATION_FACTORS,
        "observations": len(rows), "workloads": workloads, "baseline_commit":
            json.loads((HERE / "baseline/manifest.json").read_text())["commit"],
        "runner_sha256": digest(Path(__file__).read_bytes()),
        "note": "Fresh process per timed row; setup and warm-up outside measured interval; serial AB/BA pairs.",
    })
    for item in summary:
        print(f"{item['workload']}: {item['baseline']['median_ns']:.1f} -> "
              f"{item['candidate']['median_ns']:.1f} ns/op ({item['change_percent']:+.2f}%)", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("test", "benchmark", "summarize"))
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--configuration", choices=("debug", "release"), default="debug")
    parser.add_argument("--variant", choices=("baseline", "candidate", "both"), default="both")
    parser.add_argument("--rounds", type=int, default=10)
    parser.add_argument("--iterations", type=int, default=10000)
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    if args.rounds < 2 or args.rounds % 2 or args.iterations <= 0:
        parser.error("Use an even --rounds >= 2 and positive --iterations")
    if args.mode == "test":
        for variant in ("baseline", "candidate") if args.variant == "both" else (args.variant,):
            test(variant, args.configuration, out)
    elif args.mode == "benchmark":
        benchmark(out, args.rounds, args.iterations)
    else:
        rows = [json.loads(line) for line in (out / "measurements.jsonl").read_text().splitlines()]
        write_json(out / "summary.json", summarize(rows))


if __name__ == "__main__":
    main()
