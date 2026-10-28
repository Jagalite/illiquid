#!/usr/bin/env python3
"""Compare the actual file-identity and playlist sources in separate Swift modules."""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import platform
import shutil
import statistics
import subprocess
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
SOURCES = [
    "Sources/IlliquidCore/Utilities/NormalizedFileURL.swift",
    "Sources/IlliquidCore/Utilities/NaturalFilenameOrdering.swift",
    "Sources/IlliquidCore/Utilities/MediaFileSupport.swift",
    "Sources/IlliquidCore/Player/MediaSource.swift",
    "Sources/IlliquidCore/Playlist/FolderPlaylist.swift",
    "Sources/IlliquidCore/Playlist/PlaylistMutation.swift",
]
TESTS = [
    "NormalizedFileIdentityTests", "LocalMediaSourceValidationTests", "UtilitiesTests",
    "PlaylistIdentityLookupTests", "PlaylistDeduplicationTests", "PlaylistMutationTests",
    "PlaylistOrderRestorationTests", "FolderPlaylistTests", "NaturalFilenameOrderingTests",
    "PlaylistSortingTests",
]
VARIANTS = ("baseline", "candidate")


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def save(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--pairs", type=int, default=10)
    parser.add_argument("--target-ms", type=int, default=150)
    parser.add_argument("--tests-only", action="store_true")
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2 or args.target_ms < 20:
        parser.error("--pairs must be positive/even (at least 2); --target-ms must be at least 20")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        parser.error("--output must be new or empty")
    if Path("/Volumes/seed1/Projects/kyoto/kyoto.py").is_file():
        parser.error("Kyoto is available: submit the intended build through the shared queue.")
    print("Kyoto is unavailable on this isolated host; compiling serially.", flush=True)
    logs = output / "logs"
    logs.mkdir()
    commands = []
    observations = []
    calibrations = []
    completion = {"status": "running", "tests_only": args.tests_only}
    save(output / "completion.json", completion)

    def run(command: list[str], label: str) -> str:
        started = datetime.now(timezone.utc).isoformat()
        result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True)
        (logs / (label + ".log")).write_text(result.stdout + result.stderr)
        commands.append({"label": label, "command": command, "started_utc": started,
                         "exit_code": result.returncode})
        save(output / "commands.json", commands)
        if result.returncode:
            raise RuntimeError(f"{label} failed ({result.returncode}):\n{result.stderr[-6000:]}\n{result.stdout[-6000:]}")
        return result.stdout

    try:
        compiler = shutil.which("swiftc")
        swift = shutil.which("swift")
        if not compiler or not swift:
            raise RuntimeError("Swift and swiftc must be on PATH")
        flags = ["-O", "-whole-module-optimization", "-swift-version", "6", "-warnings-as-errors"]
        if platform.system() == "Darwin":
            sdk = run(["xcrun", "--sdk", "macosx", "--show-sdk-path"], "sdk").strip()
            flags += ["-sdk", sdk, "-target", f"{platform.machine()}-apple-macosx26.0"]
        manifest = {
            "baseline_commit": BASELINE,
            "candidate_commit": run(["git", "rev-parse", "HEAD"], "head").strip(),
            "candidate_status": run(["git", "status", "--porcelain"], "status").strip(),
            "platform": platform.platform(), "machine": platform.machine(),
            "swift": run([compiler, "--version"], "swift-version").strip(),
            "flags": flags, "cross_module_optimization": False,
            "pairs": args.pairs, "target_ms": args.target_ms,
            "created_utc": datetime.now(timezone.utc).isoformat(),
            "runner_sha256": sha(Path(__file__).read_bytes()),
            "harness_sha256": sha((HERE / "Harness.swift").read_bytes()),
            "sources": {}, "tests": {}, "binaries": {},
            "scope": "Warmed file-key generation and complete in-memory playlist operations; input construction/sorting excluded.",
        }
        if platform.system() == "Darwin":
            manifest["macos"] = run(["sw_vers"], "macos").strip()
            manifest["cpu"] = run(["sysctl", "-n", "machdep.cpu.brand_string"], "cpu").strip()
            manifest["xcode"] = run(["xcodebuild", "-version"], "xcode").strip()
        save(output / "manifest.json", manifest)
        for variant in VARIANTS:
            package = output / variant
            source_dir = package / "Sources/IlliquidCore"
            test_dir = package / "Tests/IlliquidCoreTests"
            source_dir.mkdir(parents=True)
            test_dir.mkdir(parents=True)
            for path in SOURCES:
                source = (run(["git", "show", f"{BASELINE}:{path}"], "baseline-" + Path(path).stem)
                          if variant == "baseline" else (ROOT / path).read_text())
                (source_dir / Path(path).name).write_text(source)
                manifest["sources"][variant + "/" + path] = sha(source.encode())
            for name in TESTS:
                path = ROOT / "Tests/IlliquidCoreTests" / (name + ".swift")
                shutil.copyfile(path, test_dir / path.name)
                manifest["tests"][path.name] = sha(path.read_bytes())
            (package / "Package.swift").write_text("""// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "FileIdentityQualification", platforms: [.macOS("26.0")], targets: [
    .target(name: "IlliquidCore"),
    .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"]),
])
""")
            save(output / "manifest.json", manifest)
            for configuration in ("debug", "release"):
                label = f"tests-{variant}-{configuration}"
                run([swift, "test", "--package-path", str(package), "-c", configuration,
                     "--jobs", "2", "--no-parallel", "-Xswiftc", "-warnings-as-errors"], label)
                print("PASS " + label, flush=True)
        save(output / "manifest.json", manifest)
        if args.tests_only:
            save(output / "completion.json", {"status": "complete", "tests_only": True})
            return

        executables = {}
        for variant in VARIANTS:
            folder = output / variant / "benchmark"
            folder.mkdir()
            sources = sorted((output / variant / "Sources/IlliquidCore").glob("*.swift"))
            suffix = "dylib" if platform.system() == "Darwin" else "so"
            library = folder / f"libIlliquidCore.{suffix}"
            run([compiler, *flags, "-parse-as-library", "-emit-library", "-emit-module",
                 "-enable-testing", "-module-name", "IlliquidCore",
                 "-emit-module-path", str(folder / "IlliquidCore.swiftmodule"),
                 *(str(path) for path in sources), "-o", str(library)], "build-" + variant)
            binary = folder / "identity"
            run([compiler, *flags, "-parse-as-library", "-I", str(folder), "-L", str(folder),
                 "-lIlliquidCore", "-Xlinker", "-rpath", "-Xlinker", str(folder),
                 str(HERE / "Harness.swift"), "-o", str(binary)], "driver-" + variant)
            executables[variant] = binary
            manifest["binaries"][variant] = {"library": sha(library.read_bytes()),
                                             "executable": sha(binary.read_bytes())}
        save(output / "manifest.json", manifest)
        definitions = {}
        verification = {}
        for variant in VARIANTS:
            definitions[variant] = json.loads(run([str(executables[variant]), "--list"], "list-" + variant))
            verification[variant] = json.loads(run([str(executables[variant]), "--verify"], "verify-" + variant))
        if definitions["baseline"] != definitions["candidate"] or verification["baseline"] != verification["candidate"]:
            raise RuntimeError("Baseline/candidate full-output or fixture parity failed; inspect verify logs")
        cases = definitions["candidate"]
        save(output / "cases.json", cases)
        save(output / "correctness.json", {
            "all_four_test_runs_passed": True, "full_output_parity_passed": True,
            "workloads": len(cases), "verification_sha256": sha(json.dumps(verification["baseline"], sort_keys=True).encode()),
            "note": "UTF-8 keys are compared as base64 bytes, not canonical-equivalence String equality.",
        })

        def measure(variant: str, case: dict, passes: int, label: str) -> dict:
            row = json.loads(run([str(executables[variant]), case["id"], str(passes)], label))
            units = case["count"] if case["operation"] == "keys" else 1
            expected = next(item["checksumPerPass"] for item in verification["baseline"] if item["id"] == case["id"])
            if (row["id"] != case["id"] or row["passes"] != passes
                    or row["operations"] != passes * units or row["checksum_per_pass"] != expected
                    or row["checksum"] != (expected * passes) % (1 << 64)
                    or row["wall_ns"] <= 0 or row["cpu_ns"] <= 0):
                raise RuntimeError("Invalid measurement receipt: " + label)
            return row

        passes_by_case = {}
        for case in cases:
            passes = 1
            for trial in range(8):
                rows = []
                for variant in VARIANTS:
                    row = measure(variant, case, passes, f"calibrate-{case['id']}-{trial}-{variant}")
                    row.update({"variant": variant, "trial": trial})
                    calibrations.append(row)
                    rows.append(row)
                fastest = min(row["wall_ns"] for row in rows)
                if fastest >= args.target_ms * 1_000_000:
                    break
                passes = max(passes + 1, math.ceil(passes * args.target_ms * 1_000_000 * 1.3 / fastest))
            else:
                raise RuntimeError("Calibration did not reach target: " + case["id"])
            passes_by_case[case["id"]] = passes
        save(output / "calibrations.json", calibrations)
        for pair in range(args.pairs):
            for case in (cases if pair % 2 == 0 else list(reversed(cases))):
                order = VARIANTS if pair % 2 == 0 else tuple(reversed(VARIANTS))
                for position, variant in enumerate(order):
                    row = measure(variant, case, passes_by_case[case["id"]],
                                  f"measure-{pair}-{case['id']}-{variant}")
                    row.update({"variant": variant, "pair": pair, "position_in_pair": position})
                    observations.append(row)
                    with (output / "observations.jsonl").open("a") as handle:
                        handle.write(json.dumps(row, sort_keys=True) + "\n")
            print(f"Completed pair {pair + 1}/{args.pairs}", flush=True)
        summary = []
        for case in cases:
            rows = [row for row in observations if row["id"] == case["id"]]
            entry = {"workload": case, "passes": passes_by_case[case["id"]], "metrics": {}}
            for metric in ("wall_ns_per_operation", "cpu_ns_per_operation"):
                old = [row[metric] for row in rows if row["variant"] == "baseline"]
                new = [row[metric] for row in rows if row["variant"] == "candidate"]
                ratios = [new[index] / old[index] for index in range(args.pairs)]
                entry["metrics"][metric] = {
                    "baseline_median": statistics.median(old), "candidate_median": statistics.median(new),
                    "reduction_percent": 100 * (1 - statistics.median(new) / statistics.median(old)),
                    "baseline_range": [min(old), max(old)], "candidate_range": [min(new), max(new)],
                    "paired_ratios": ratios, "candidate_faster_pairs": sum(value < 1 for value in ratios),
                }
            summary.append(entry)
        save(output / "summary.json", {"results": summary, "pairs": args.pairs,
             "observations": len(observations),
             "minimum_sample_ms": min(row["wall_ns"] for row in observations) / 1_000_000,
             "all_samples_retained": True})
        save(output / "completion.json", {"status": "complete", "tests_only": False,
                                          "observations": len(observations)})
        print(json.dumps(summary, indent=2), flush=True)
    except BaseException as error:
        save(output / "completion.json", {"status": "failed", "error": str(error)})
        raise


if __name__ == "__main__":
    main()
