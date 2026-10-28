#!/usr/bin/env python3
"""Exact-source regional color averaging comparison for Swift on macOS/Linux."""
import argparse
import hashlib
import json
import math
import os
import platform
import re
import shutil
import statistics
import subprocess
import sys
import time
import traceback
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
SOURCE = "Sources/IlliquidCore/Player/VideoColorSample.swift"
TEST = "Tests/IlliquidCoreTests/VideoColorSampleAverageTests.swift"


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def save(path, data):
    path.write_text(json.dumps(data, indent=2, sort_keys=True, allow_nan=False) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pairs", type=int, default=8)
    parser.add_argument("--target-ms", type=float, default=150)
    parser.add_argument("--tests-only", action="store_true")
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2 or not math.isfinite(args.target_ms) or args.target_ms < 50:
        parser.error("Use an even pair count >= 2 and a finite target >= 50 ms.")
    if sys.platform not in ("darwin", "linux"):
        parser.error("Use macOS or Linux.")
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    for name in ("sources", "logs", "receipts"):
        (out / name).mkdir()
    commands = []
    manifest = {}
    linkage_records = {}
    loader_environment = dict(os.environ)
    loader_variables = ("LD_LIBRARY_PATH", "LD_PRELOAD", "DYLD_LIBRARY_PATH",
                        "DYLD_FALLBACK_LIBRARY_PATH", "DYLD_INSERT_LIBRARIES")
    removed_loader_variables = [name for name in loader_variables if loader_environment.pop(name, None)]
    swiftc = shutil.which(os.environ.get("SWIFTC", "swiftc"))
    swift = shutil.which("swift")
    if not swiftc or not swift:
        raise RuntimeError("A Swift 6 toolchain is required.")

    def run(argv, name, quiet=False, timeout=600):
        argv = [str(x) for x in argv]
        started = time.time()
        executable_is_probe = Path(argv[0]).name in ("measure", "ldd", "otool")
        result = subprocess.run(argv, cwd=ROOT, text=True, capture_output=True, timeout=timeout,
                                env=loader_environment if executable_is_probe else None)
        commands.append({"name": name, "argv": argv, "started_unix_seconds": started,
                         "elapsed_seconds": time.time() - started, "exit_code": result.returncode})
        save(out / "commands.json", commands)
        (out / "logs" / (name + ".log")).write_text(
            ("" if quiet and result.returncode == 0 else result.stdout) + result.stderr
        )
        if result.returncode:
            print((result.stdout + result.stderr)[-16000:], file=sys.stderr)
            result.check_returncode()
        return result.stdout

    try:
        baseline = (HERE / "baseline/VideoColorSample.swift").read_bytes()
        baseline_info = json.loads((HERE / "baseline/manifest.json").read_text())
        blob = hashlib.sha1(b"blob " + str(len(baseline)).encode() + b"\0" + baseline).hexdigest()
        if blob != baseline_info["git_blob_sha"]:
            raise RuntimeError("Frozen baseline Git blob mismatch.")
        paths = {
            "baseline.swift": HERE / "baseline/VideoColorSample.swift",
            "candidate.swift": ROOT / SOURCE,
            "Driver.swift": HERE / "Driver.swift",
            "VideoColorSampleAverageTests.swift": ROOT / TEST,
            "run.py": HERE / "run.py",
        }
        hashes = {}
        for name, path in paths.items():
            data = path.read_bytes()
            (out / "sources" / name).write_bytes(data)
            hashes[name] = {"path": str(path.relative_to(ROOT)), "sha256": sha256(data)}
        manifest = {
            "baseline": baseline_info, "sources": hashes,
            "git_head": run(["git", "rev-parse", "HEAD"], "head").strip(),
            "git_status": run(["git", "status", "--porcelain"], "status").strip(),
            "platform": platform.platform(), "machine": platform.machine(),
            "swift": run([swiftc, "--version"], "swift-version").strip(),
            "python": sys.version, "pairs": args.pairs, "target_ms": args.target_ms,
            "cleared_driver_loader_variables": removed_loader_variables,
            "scope": "Complete production average/region accessors on 12x8 samples; "
                     "no renderer, decoder, visible UI or whole-player performance measurement.",
            "method": "Separate production dynamic module and driver; no cross-module optimization; "
                      "fresh processes; common iteration count; rotating case order and balanced AB/BA pairs.",
        }
        if sys.platform == "darwin":
            manifest["host"] = run(["sw_vers"], "host").strip()
            manifest["cpu"] = run(["sysctl", "-n", "machdep.cpu.brand_string"], "cpu").strip()
        else:
            manifest["cpu"] = next((line.split(":", 1)[1].strip()
                                    for line in Path("/proc/cpuinfo").read_text().splitlines()
                                    if line.startswith("model name")), platform.processor())
        save(out / "manifest.json", manifest)
        binaries = {}
        binary_hashes = {}
        tests = []
        suffix = ".dylib" if sys.platform == "darwin" else ".so"
        for variant in ("baseline", "candidate"):
            package = out / "build" / ("tests-" + variant)
            (package / "Sources/IlliquidCore").mkdir(parents=True)
            (package / "Tests/IlliquidCoreTests").mkdir(parents=True)
            shutil.copyfile(out / "sources" / (variant + ".swift"),
                            package / "Sources/IlliquidCore/VideoColorSample.swift")
            shutil.copyfile(ROOT / TEST, package / "Tests/IlliquidCoreTests/VideoColorSampleAverageTests.swift")
            (package / "Package.swift").write_text(
                '// swift-tools-version: 6.1\nimport PackageDescription\n'
                'let package = Package(name: "ColorRegionChecks", targets: [\n'
                '  .target(name: "IlliquidCore"),\n'
                '  .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"])\n])\n'
            )
            for mode in ("debug", "release"):
                output = run([swift, "test", "--package-path", package,
                              "--scratch-path", package / ".build", "-c", mode, "--jobs", "2",
                              "--no-parallel", "-Xswiftc", "-warnings-as-errors"],
                             variant + "-" + mode + "-tests")
                # Swift Testing may write its summary to stderr; read the retained full log.
                log = (out / "logs" / (variant + "-" + mode + "-tests.log")).read_text()
                counts = re.findall(r"Test run with (\d+) tests?\b[^\n]*passed", log)
                if not counts or int(counts[-1]) < 7:
                    raise RuntimeError("Expected all seven exact-source regression tests to execute.")
                tests.append({"variant": variant, "configuration": mode, "passed": int(counts[-1])})
                save(out / "tests.json", tests)

                directory = out / "build" / (variant + "-" + mode)
                directory.mkdir()
                flags = ["-swift-version", "6", "-warnings-as-errors", "-parse-as-library",
                         "-module-cache-path", str(out / "module-cache")]
                flags += ["-O", "-whole-module-optimization"] if mode == "release" else ["-Onone"]
                library = directory / ("libIlliquidCore" + suffix)
                run([swiftc, *flags, "-emit-module", "-emit-library", "-module-name", "IlliquidCore",
                     "-emit-module-path", directory / "IlliquidCore.swiftmodule",
                     out / "sources" / (variant + ".swift"), "-o", library],
                    variant + "-" + mode + "-core-build")
                binary = directory / "measure"
                run([swiftc, *flags, "-I", directory, "-L", directory, "-lIlliquidCore",
                     "-Xlinker", "-rpath", "-Xlinker", directory,
                     out / "sources/Driver.swift", "-o", binary],
                    variant + "-" + mode + "-driver-build")
                linkage_tool = "otool" if sys.platform == "darwin" else "ldd"
                linkage_args = ["-L"] if sys.platform == "darwin" else []
                linkage = run([linkage_tool, *linkage_args, binary],
                              variant + "-" + mode + "-linkage")
                if str(library) not in linkage:
                    raise RuntimeError("The benchmark does not resolve its own production library.")
                linkage_records[variant + "-" + mode] = linkage
                save(out / "linkage.json", linkage_records)
                binaries[variant, mode] = binary
                for path in (library, binary):
                    binary_hashes[str(path.relative_to(out))] = sha256(path.read_bytes())
        manifest["binaries_sha256"] = binary_hashes
        save(out / "manifest.json", manifest)

        verification = {}
        for mode in ("debug", "release"):
            receipts = {}
            for variant in ("baseline", "candidate"):
                raw = run([binaries[variant, mode], "--verify"], variant + "-" + mode + "-verify", quiet=True)
                (out / "receipts" / (variant + "-" + mode + ".json")).write_text(raw)
                receipts[variant] = json.loads(raw)
            if receipts["baseline"] != receipts["candidate"]:
                raise RuntimeError("Exact Double bit-pattern receipts differ in " + mode)
            verification[mode] = {
                "equal": True, "rectangles": receipts["baseline"]["rectangles"],
                "receipt_sha256": {
                    variant: sha256((out / "receipts" / (variant + "-" + mode + ".json")).read_bytes())
                    for variant in ("baseline", "candidate")
                },
            }
        save(out / "verification.json", verification)
        if args.tests_only:
            save(out / "summary.json", {"timing": "not requested"})
            return
        cases = json.loads(run([binaries["baseline", "release"], "--cases"], "cases", quiet=True))
        save(out / "cases.json", cases)
        counts, calibration = {}, {}
        for name in cases:
            pilots = {}
            for variant in ("baseline", "candidate"):
                pilots[variant] = json.loads(run(
                    [binaries[variant, "release"], "--measure", name, "10000"],
                    "pilot-" + name + "-" + variant, quiet=True
                ))
            fastest = min(row["wallNanoseconds"] / row["iterations"] for row in pilots.values())
            counts[name] = min(100_000_000, max(128, math.ceil(args.target_ms * 1_000_000 / fastest)))
            calibration[name] = {"pilots": pilots, "iterations": counts[name]}
        save(out / "calibration.json", calibration)
        records = []
        with (out / "measurements.jsonl").open("w") as stream:
            for pair in range(args.pairs):
                ordered = cases[pair % len(cases):] + cases[:pair % len(cases)]
                variants = ["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]
                for name in ordered:
                    paired = {}
                    for variant in variants:
                        row = json.loads(run(
                            [binaries[variant, "release"], "--measure", name, str(counts[name])],
                            f"pair-{pair}-{name}-{variant}", quiet=True
                        ))
                        if row["name"] != name or row["iterations"] != counts[name]:
                            raise RuntimeError("Measurement identity mismatch.")
                        if not 0 < row["wallNanoseconds"] <= 3_000_000_000:
                            raise RuntimeError("Timing outside the allowed sample duration; retain and recalibrate.")
                        row.update({"pair": pair, "variant": variant, "order": variants, "sequence": len(records)})
                        records.append(row)
                        stream.write(json.dumps(row, sort_keys=True) + "\n")
                        stream.flush()
                        paired[variant] = row
                    if paired["baseline"]["checksum"] != paired["candidate"]["checksum"]:
                        raise RuntimeError("Timed checksum mismatch for " + name)
        summaries = {}
        for name in cases:
            selected = [row for row in records if row["name"] == name]
            summary = {"iterations": counts[name], "pairs": args.pairs}
            for metric, field in (("wall", "wallNanoseconds"), ("cpu", "cpuNanoseconds")):
                medians = {
                    variant: statistics.median(row[field] / row["iterations"]
                                               for row in selected if row["variant"] == variant)
                    for variant in ("baseline", "candidate")
                }
                ratios = [
                    next(row[field] for row in selected if row["pair"] == pair and row["variant"] == "candidate")
                    / next(row[field] for row in selected if row["pair"] == pair and row["variant"] == "baseline")
                    for pair in range(args.pairs)
                ]
                summary[metric] = {
                    "baseline_median_ns": medians["baseline"], "candidate_median_ns": medians["candidate"],
                    "paired_ratios": ratios, "paired_ratio_median": statistics.median(ratios),
                    "paired_ratio_min": min(ratios), "paired_ratio_max": max(ratios),
                }
            summaries[name] = summary
        save(out / "summary.json", summaries)
    except BaseException:
        save(out / "failure.json", {"traceback": traceback.format_exc()})
        raise
    finally:
        manifest["finished_unix_seconds"] = time.time()
        save(out / "manifest.json", manifest)


if __name__ == "__main__":
    main()
