#!/usr/bin/env python3
"""Compare the real CoreVideo sampler with its pinned pre-change implementation."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import shutil
import statistics
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
SAMPLER = "Sources/IlliquidNativePlayback/Presentation/VideoFrameColorSampler.swift"
CORE = "Sources/IlliquidCore/Player/VideoColorSample.swift"
MAPPING = "Sources/IlliquidNativePlayback/Presentation/PiPVideoMapping.swift"
TESTS = [
    "Tests/IlliquidNativePlaybackTests/VideoFrameColorSamplerTests.swift",
    "Tests/IlliquidNativePlaybackTests/VideoFrameColorSamplerLayoutTests.swift",
]
BASELINE_COMMIT = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
BASELINE_BLOB = "4ff4ebfd1b23235bf8843ee87eb2b9de4f0af574"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pairs", type=int, default=8)
    parser.add_argument("--target-ms", type=float, default=150)
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("Requires macOS and real CoreVideo; no substituted APIs are supported")
    if args.pairs < 2 or args.pairs % 2 or not math.isfinite(args.target_ms) or args.target_ms <= 0:
        parser.error("Use an even --pairs >= 2 and a finite positive --target-ms")
    out = args.output.resolve()
    if out.exists() and (not out.is_dir() or any(out.iterdir())):
        parser.error("Use an empty or nonexistent output directory")
    out.mkdir(parents=True, exist_ok=True)
    for name in ("logs", "sources", "build", "packages"):
        (out / name).mkdir()
    manifest = {
        "schema_version": 1, "baseline_commit": BASELINE_COMMIT,
        "baseline_blob": BASELINE_BLOB, "production_path": SAMPLER,
        "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "host": platform.platform(), "machine": platform.machine(),
        "commands": [], "tests": [], "files": {}, "status": "running",
        "protocol": {
            "pairs": args.pairs, "target_ms": args.target_ms,
            "fresh_process_per_observation": True, "balanced_order": "AB/BA",
            "timed_operation": "one sample() or sampleIfNeeded() call, including a lightweight result checksum",
            "excluded": ["fixture allocation and filling", "warmup", "full output verification"],
            "scope": "warm CPU-accessible IOSurface buffers; not end-to-end playback or GPU synchronization",
        },
    }

    def command(argv, name, cwd=ROOT):
        result = subprocess.run([str(value) for value in argv], cwd=cwd,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        log = out / "logs" / (name + ".log")
        log.write_bytes(result.stdout)
        manifest["commands"].append({
            "argv": [str(value) for value in argv], "cwd": str(cwd),
            "exit_code": result.returncode, "log": str(log.relative_to(out)),
            "log_sha256": digest(result.stdout),
        })
        write_json(out / "manifest.json", manifest)
        if result.returncode:
            raise RuntimeError(f"{name} failed ({result.returncode}):\n"
                               + result.stdout.decode(errors="replace")[-8000:])
        return result.stdout

    def stage(name, data):
        path = out / "sources" / name
        path.write_bytes(data)
        manifest["files"][str(path.relative_to(out))] = digest(data)
        return path

    try:
        manifest["candidate_head"] = command(["git", "rev-parse", "HEAD"], "git-head").decode().strip()
        manifest["worktree_status"] = command(["git", "status", "--porcelain"], "git-status").decode()
        manifest["swift_version"] = command(["swift", "--version"], "swift-version").decode().strip()
        manifest["cpu"] = command(["sysctl", "-n", "machdep.cpu.brand_string"], "cpu").decode().strip()
        manifest["macos"] = command(["sw_vers"], "macos").decode().strip()
        sdk = command(["xcrun", "--sdk", "macosx", "--show-sdk-path"], "sdk").decode().strip()
        native_flags = ["-target", platform.machine() + "-apple-macosx26.0", "-sdk", sdk]
        kyoto = Path("/Volumes/seed1/Projects/kyoto/kyoto.py")
        manifest["kyoto_available"] = kyoto.exists()
        if not kyoto.exists():
            print("Kyoto is unavailable on this host; compiling directly and serially.", flush=True)
        elif os.environ.get("ILLIQUID_SAMPLER_QUEUED") != "1":
            raise RuntimeError("Kyoto is available. Submit this entire command through Kyoto with "
                               "env ILLIQUID_SAMPLER_QUEUED=1, then inspect show/logs/wait for the job.")

        baseline_bytes = (HERE / "baseline/VideoFrameColorSampler.swift").read_bytes()
        blob_hash = hashlib.sha1(b"blob " + str(len(baseline_bytes)).encode() + b"\0" + baseline_bytes).hexdigest()
        if blob_hash != BASELINE_BLOB:
            raise RuntimeError("Pinned baseline no longer matches the original Git blob")
        tracked = [ROOT / SAMPLER, ROOT / CORE, ROOT / MAPPING,
                   HERE / "baseline/VideoFrameColorSampler.swift",
                   HERE / "Harness.swift", Path(__file__).resolve()] + [ROOT / path for path in TESTS]
        input_hashes = {str(path.relative_to(ROOT)): digest(path.read_bytes()) for path in tracked}
        manifest["input_sha256"] = input_hashes
        core = stage("VideoColorSample.swift", (ROOT / CORE).read_bytes())
        mapping = stage("PiPVideoMapping.swift", (ROOT / MAPPING).read_bytes())
        harness = stage("Harness.swift", (HERE / "Harness.swift").read_bytes())
        stage("run.py", Path(__file__).read_bytes())
        test_sources = [stage(Path(path).name, (ROOT / path).read_bytes()) for path in TESTS]
        variants = {
            "baseline": stage("baseline-VideoFrameColorSampler.swift", baseline_bytes),
            "candidate": stage("candidate-VideoFrameColorSampler.swift", (ROOT / SAMPLER).read_bytes()),
        }
        package_text = '''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "VideoFrameColorSampling", platforms: [.macOS("26.0")], targets: [
    .target(name: "IlliquidCore"),
    .target(name: "IlliquidNativePlayback", dependencies: ["IlliquidCore"]),
    .testTarget(name: "SamplerTests", dependencies: ["IlliquidCore", "IlliquidNativePlayback"])
])
'''
        executables = {}
        for variant, source in variants.items():
            package = out / "packages" / variant
            core_dir = package / "Sources/IlliquidCore"
            native_dir = package / "Sources/IlliquidNativePlayback"
            test_dir = package / "Tests/SamplerTests"
            for directory in (core_dir, native_dir, test_dir):
                directory.mkdir(parents=True)
            (package / "Package.swift").write_text(package_text)
            shutil.copyfile(core, core_dir / core.name)
            shutil.copyfile(mapping, native_dir / mapping.name)
            shutil.copyfile(source, native_dir / "VideoFrameColorSampler.swift")
            for test_source in test_sources:
                shutil.copyfile(test_source, test_dir / test_source.name)
            for configuration in ("debug", "release"):
                log = command(["swift", "test", "--package-path", package, "-c", configuration,
                               "--jobs", "2", "--no-parallel", "-Xswiftc", "-warnings-as-errors"],
                              variant + "-" + configuration + "-tests").decode(errors="replace")
                counts = re.findall(r"Test run with (\d+) tests? (?:in \d+ suites? )?passed", log)
                if not counts or int(counts[-1]) == 0:
                    raise RuntimeError("No successful Swift Testing count in " + variant + "-" + configuration)
                manifest["tests"].append({"variant": variant, "configuration": configuration,
                                          "passed": int(counts[-1])})
            build = out / "build" / variant
            build.mkdir()
            flags = ["-swift-version", "6", "-O", "-whole-module-optimization", "-warnings-as-errors"] + native_flags
            core_library = build / "libIlliquidCore.dylib"
            native_library = build / "libIlliquidNativePlayback.dylib"
            command(["swiftc", *flags, "-parse-as-library", "-module-name", "IlliquidCore",
                     "-emit-library", "-emit-module", "-emit-module-path", build / "IlliquidCore.swiftmodule",
                     core, "-o", core_library], variant + "-core-library")
            link = ["-I", build, "-L", build, "-lIlliquidCore", "-Xlinker", "-rpath", "-Xlinker", build]
            command(["swiftc", *flags, "-parse-as-library", "-enable-testing", "-module-name",
                     "IlliquidNativePlayback", "-emit-library", "-emit-module", "-emit-module-path",
                     build / "IlliquidNativePlayback.swiftmodule", source, mapping, *link,
                     "-o", native_library], variant + "-native-library")
            executable = build / "sampler-benchmark"
            command(["swiftc", *flags, "-parse-as-library", harness, *link,
                     "-lIlliquidNativePlayback", "-o", executable], variant + "-harness")
            executables[variant] = executable
            for binary in (core_library, native_library, executable):
                manifest["files"][str(binary.relative_to(out))] = digest(binary.read_bytes())

        if len({entry["passed"] for entry in manifest["tests"]}) != 1:
            raise RuntimeError("Baseline/candidate or debug/release test counts differ")
        receipts = {}
        for variant, executable in executables.items():
            receipts[variant] = json.loads(command([executable, "verify"], variant + "-verify"))
            write_json(out / (variant + "-verify.json"), receipts[variant])
        if receipts["baseline"] != receipts["candidate"]:
            raise RuntimeError("Full sampled-color/temporal output parity failed")
        verification = {
            "matched": True,
            "baseline_sha256": digest((out / "baseline-verify.json").read_bytes()),
            "candidate_sha256": digest((out / "candidate-verify.json").read_bytes()),
            "coverage": "Every RGB Double bit pattern in fixture and temporal receipts; see verify JSON files.",
        }
        write_json(out / "verification.json", verification)
        manifest["output_parity"] = verification
        cases = json.loads(command([executables["candidate"], "list"], "workload-list"))
        if not isinstance(cases, list) or not cases or not all(isinstance(case, str) for case in cases):
            raise RuntimeError("Invalid workload list")
        observations, calibrations, summary = [], [], []
        for case in cases:
            expects_samples = case not in ("unsupported-argb", "throttled-bgra")
            probes = {}
            for variant, executable in executables.items():
                row = json.loads(command([executable, "bench", case, "4096"], variant + "-calibrate-" + case))
                if (row["workload"] != case or row["iterations"] != 4096
                        or row["sampled_count"] != (4096 if expects_samples else 0)
                        or row["warmup_sampled_count"] != (row["warmup_iterations"] if expects_samples else 0)):
                    raise RuntimeError("Invalid calibration output: " + case)
                row["variant"] = variant
                calibrations.append(row)
                probes[variant] = row["elapsed_ns"] / row["iterations"]
            if min(probes.values()) <= 0:
                raise RuntimeError("Nonpositive calibration")
            count = max(64, min(math.ceil(args.target_ms * 1e6 / min(probes.values())),
                                int(1500e6 / max(probes.values())), 5_000_000))
            paired = []
            for pair in range(args.pairs):
                rows = {}
                order = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
                for position, variant in enumerate(order):
                    row = json.loads(command([executables[variant], "bench", case, str(count)],
                                             f"{case}-pair-{pair}-{variant}"))
                    if (row["workload"] != case or row["iterations"] != count
                            or row["sampled_count"] != (count if expects_samples else 0)
                            or row["warmup_sampled_count"] != (row["warmup_iterations"] if expects_samples else 0)
                            or row["elapsed_ns"] <= 0 or row["cpu_ns"] <= 0):
                        raise RuntimeError("Invalid measurement: " + case)
                    row.update(variant=variant, pair=pair, order=position)
                    observations.append(row)
                    rows[variant] = row
                if rows["baseline"]["checksum"] != rows["candidate"]["checksum"]:
                    raise RuntimeError("Timed output checksum mismatch: " + case)
                paired.append(rows)
                write_json(out / "observations.json", observations)
            item = {"workload": case, "iterations_per_observation": count, "pairs": args.pairs}
            for metric in ("elapsed_ns", "cpu_ns"):
                changes = [100 * (p["candidate"][metric] / p["baseline"][metric] - 1) for p in paired]
                item[metric] = {
                    "baseline_median_per_operation": statistics.median(p["baseline"][metric] / count for p in paired),
                    "candidate_median_per_operation": statistics.median(p["candidate"][metric] / count for p in paired),
                    "median_paired_change_percent": statistics.median(changes),
                    "faster_pairs": sum(change < 0 for change in changes),
                    "paired_changes_percent": changes,
                }
            summary.append(item)
            print(json.dumps(item, sort_keys=True), flush=True)
            write_json(out / "summary.json", summary)
        write_json(out / "calibrations.json", calibrations)
        write_json(out / "observations.json", observations)
        write_json(out / "summary.json", summary)
        if any(digest((ROOT / path).read_bytes()) != expected for path, expected in input_hashes.items()):
            raise RuntimeError("An input changed during qualification")
        manifest["status"] = "passed"
        print("Full output parity and all component tests passed.", flush=True)
    except Exception as error:
        manifest["status"] = "failed"
        manifest["error"] = str(error)
        raise
    finally:
        manifest["finished_utc"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        write_json(out / "manifest.json", manifest)


if __name__ == "__main__":
    main()
