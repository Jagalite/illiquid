#!/usr/bin/env python3
"""Qualify and measure actual playback progress analysis against a pinned Git revision."""

from __future__ import annotations

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
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
ANALYZER = Path("Sources/IlliquidPlaybackStateSpace/PlaybackProgressAnalyzer.swift")
CORE = Path("Sources/IlliquidCore/Player/MediaTrack.swift")
PLAYBACK = Path("Sources/IlliquidPlaybackCore")
STATE_SPACE = Path("Sources/IlliquidPlaybackStateSpace")
TESTS = Path("Tests/IlliquidPlaybackStateSpaceTests")
KYOTO = Path("/Volumes/seed1/Projects/kyoto/kyoto.py")
NATIVE = sys.platform == "darwin"
VARIANTS = ("baseline", "candidate")
# Regression pins describe the reviewed integrated source cohort, not a new timing baseline.
REGRESSION_BASELINE = '4077f8ad538dd8ed911b38c9b300a98c787c5135'
REGRESSION_BASELINE_FOCAL_SHA256 = '094a9145b4faec7e13dfc5a964ad922a4e9c6d27ea1e04589ab3e195acf6137e'
# Integrated analyzer: main SCC reuse/dense bookkeeping plus PR229's three
# predecessor-indexing edits. Historical performance sources remain unchanged.
REGRESSION_CANDIDATE_FOCAL_SHA256 = 'ca3976b19fce3e96c5fa93edfa9ed54f6487609aa2190de1917eafce55e8e8de'
REGRESSION_SUPPORT_SHA256 = {'Sources/IlliquidPlaybackStateSpace/PlaybackPartialOrderReducer.swift': 'a3a4f5010135e55ef6564365aa7bb42a203033baae1c4fd9ed39d81dcabfaf3a', 'Sources/IlliquidPlaybackStateSpace/PlaybackStateSpaceExplorer.swift': '13f04caf1abb97c2d6543094e8e854da09ce98678ea70ff9cf6b4744c18f4905'}
RESULT_FIELDS = (
    "schema_version", "mode", "workload", "iterations", "operations",
    "checksum", "produced_count", "warmup_iterations",
    "warmup_checksum", "warmup_produced_count", "graph_metadata", "timing_scope",
)

def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def file_digest(path: Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def git_blob(data: bytes) -> str:
    return hashlib.sha1(f"blob {len(data)}\0".encode() + data).hexdigest()


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def environment(out: Path) -> tuple[dict[str, str], dict[str, str]]:
    overrides = {}
    for key, directory in {
        "CLANG_MODULE_CACHE_PATH": out / "cache/clang",
        "SWIFTPM_MODULECACHE_OVERRIDE": out / "cache/swift",
        "XDG_CACHE_HOME": out / "cache/xdg",
        "TMPDIR": out / "cache/tmp",
    }.items():
        directory.mkdir(parents=True, exist_ok=True)
        overrides[key] = str(directory)
    # Preserve the chosen SDK/toolchain when the build is executed by Kyoto.
    for key in ("DEVELOPER_DIR", "SDKROOT", "PATH"):
        if key in os.environ:
            overrides[key] = os.environ[key]
    return {**os.environ, **overrides}, overrides


def command(args: list[str], log: Path, out: Path, *, build: bool = False) -> bytes:
    log.parent.mkdir(parents=True, exist_ok=True)
    env, overrides = environment(out)
    if build and KYOTO.is_file():
        # The queue owns the complete original command. Do not change its policy
        # or treat submission as a successful compilation.
        prefix = log.with_suffix("")
        submission = command(
            [sys.executable, str(KYOTO), "submit", "--", "/usr/bin/env",
             *(f"{key}={value}" for key, value in overrides.items()), *args],
            Path(str(prefix) + "-kyoto-submit.log"), out,
        )
        job = json.loads(submission)["id"]
        if not isinstance(job, str) or not re.fullmatch(r"[A-Za-z0-9_-]+", job):
            raise RuntimeError("Kyoto submission did not return a valid job ID")
        command([sys.executable, str(KYOTO), "show", job],
                Path(str(prefix) + "-kyoto-show-before.log"), out)
        failure = None
        try:
            command([sys.executable, str(KYOTO), "wait", job],
                    Path(str(prefix) + "-kyoto-wait.log"), out)
        except RuntimeError as error:
            failure = error
        finally:
            output = command([sys.executable, str(KYOTO), "logs", job],
                             Path(str(prefix) + "-kyoto-logs.log"), out)
            command([sys.executable, str(KYOTO), "show", job],
                    Path(str(prefix) + "-kyoto-show-after.log"), out)
            log.write_bytes(json.dumps({"command": args, "kyoto_job": job}).encode()
                            + b"\n\n" + output)
        if failure is not None:
            raise failure
        return output

    start = time.monotonic()
    result = subprocess.run(args, cwd=ROOT, capture_output=True, env=env)
    receipt = {
        "command": args, "cwd": str(ROOT), "returncode": result.returncode,
        "elapsed_seconds": time.monotonic() - start,
        "log": str(log.relative_to(out)),
        "execution": "direct-serialized-build" if build else "direct",
    }
    log.write_bytes(json.dumps(receipt, sort_keys=True).encode()
                    + b"\n\nSTDOUT\n" + result.stdout + b"\n\nSTDERR\n" + result.stderr)
    receipt["log_sha256"] = digest(log.read_bytes())
    with (out / "commands.jsonl").open("a") as stream:
        stream.write(json.dumps(receipt, sort_keys=True) + "\n")
    if result.returncode:
        stderr = result.stderr.decode(errors="replace")
        raise RuntimeError(f"Command failed ({result.returncode}); see {log}\n{stderr[-6000:]}")
    return result.stdout


def git(args: list[str], log: str, out: Path) -> bytes:
    return command(["git", *args], out / "provenance" / log, out)


def validate_sources(commit: str, originals: dict[Path, bytes], current: dict[Path, bytes], mode: str) -> None:
    if originals.keys() != current.keys() or ANALYZER not in originals:
        raise RuntimeError("Production source file sets differ from the baseline")
    if mode == "regression":
        if commit != REGRESSION_BASELINE or digest(originals[ANALYZER]) != REGRESSION_BASELINE_FOCAL_SHA256:
            raise RuntimeError("Regression requires the exact historical baseline and focal source")
        if digest(current[ANALYZER]) != REGRESSION_CANDIDATE_FOCAL_SHA256 or current[ANALYZER] == originals[ANALYZER]:
            raise RuntimeError("Regression requires the exact reviewed candidate focal source, distinct from baseline")
        for path, expected in REGRESSION_SUPPORT_SHA256.items():
            if Path(path) not in current or digest(current[Path(path)]) != expected:
                raise RuntimeError(f"Reviewed regression support pin mismatch: {path}")
    for path, original in originals.items():
        if path != ANALYZER and current[path] != original:
            if mode != "regression" or str(path) not in REGRESSION_SUPPORT_SHA256:
                raise RuntimeError(f"Dependency {path} changed from the baseline; requalify it explicitly")


def validate_mode(mode: str, options: list[str]) -> None:
    if mode == "regression" and any(option.split("=", 1)[0] in {
        "--rounds", "--iterations", "--target-ms", "--configuration", "--variant"
    } for option in options):
        raise RuntimeError("Regression runs both variants and configurations with no timing options")


def snapshot(out: Path, args: argparse.Namespace) -> dict[str, object]:
    commit = git(["rev-parse", "--verify", "--end-of-options", args.baseline_ref + "^{commit}"],
                 "baseline-commit.log", out).decode().strip()
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise RuntimeError("Baseline must resolve to a full Git commit SHA")
    revision = git(["rev-parse", "HEAD"], "candidate-commit.log", out).decode().strip()
    listed = git(["ls-tree", "-r", "--name-only", commit, "--", str(PLAYBACK), str(STATE_SPACE)],
                 "baseline-source-list.log", out).decode().splitlines()
    baseline_paths = sorted([CORE, *(Path(path) for path in listed if path.endswith(".swift"))])
    current_paths = sorted([
        CORE, *(ROOT / PLAYBACK).rglob("*.swift"), *(ROOT / STATE_SPACE).rglob("*.swift"),
    ], key=str)
    current_paths = sorted(path.relative_to(ROOT) if path.is_absolute() else path for path in current_paths)
    if baseline_paths != current_paths or ANALYZER not in baseline_paths:
        raise RuntimeError("Production source file sets differ from the baseline; requalify dependencies explicitly")
    tracked = [str(CORE), str(PLAYBACK), str(STATE_SPACE), str(TESTS), str(HERE.relative_to(ROOT))]
    status = git(["status", "--porcelain=v1", "--", *tracked], "status.log", out).decode()
    patch = git(["diff", "--binary", "HEAD", "--", *tracked], "diff.log", out)
    (out / "provenance/working-tree.patch").write_bytes(patch)
    inputs = {"Harness.swift": (HERE / "Harness.swift").read_bytes(), "run.py": Path(__file__).read_bytes()}
    pinned = {"commit": commit, "sources": {}}
    originals, captured = {}, {}
    for path in baseline_paths:
        original = git(["show", f"{commit}:{path.as_posix()}"],
                       "baseline-" + path.as_posix().replace("/", "__") + ".log", out)
        current = (ROOT / path).read_bytes()
        originals[path], captured[path] = original, current
    validate_sources(commit, originals, captured, args.mode)
    for path in baseline_paths:
        original, current = originals[path], captured[path]
        pinned["sources"][str(path)] = {"git_blob": git_blob(original), "sha256": digest(original)}
        if path == CORE:
            inputs["shared/IlliquidCore/" + path.name] = current
        elif path.is_relative_to(PLAYBACK):
            inputs["shared/IlliquidPlaybackCore/" + str(path.relative_to(PLAYBACK))] = current
        else:
            relative = "IlliquidPlaybackStateSpace/" + str(path.relative_to(STATE_SPACE))
            inputs["baseline/" + relative] = (current if args.mode == "regression" and path != ANALYZER else original)
            inputs["candidate/" + relative] = current
    if args.mode in ("test", "regression"):
        tests = sorted((ROOT / TESTS).rglob("*.swift"))
        if not tests:
            raise RuntimeError("No state-space regression tests found")
        for path in tests:
            inputs["tests/" + str(path.relative_to(ROOT / TESTS))] = path.read_bytes()
    inputs["baseline-manifest.json"] = (json.dumps(pinned, indent=2, sort_keys=True) + "\n").encode()
    hashes = {}
    for name, data in inputs.items():
        destination = out / "inputs" / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(data)
        hashes[name] = digest(destination.read_bytes())
    return {
        "source_policy": "reviewed-current-support" if args.mode == "regression" else "strict-historical-support",
        "performance_qualified": False,
        "captured_production_sha256": {str(path): digest(data) for path, data in captured.items()},
        "baseline_commit": commit, "candidate_commit": revision,
        "relevant_working_tree_status": status, "working_tree_patch_sha256": digest(patch),
        "baseline": pinned, "input_sha256": hashes,
    }

def executable(value: str | None, name: str) -> str:
    found = shutil.which(value or name)
    if not found:
        raise RuntimeError(f"Cannot find {value or name}; supply --{name} or {name.upper()}")
    # Do not resolve away the swift/swiftc driver name.
    return str(Path(found).absolute())


def toolchain(args: argparse.Namespace, out: Path) -> dict[str, str]:
    swiftc_choice = args.swiftc or os.environ.get("SWIFTC")
    if NATIVE and swiftc_choice is None:
        swiftc_choice = command(["xcrun", "--find", "swiftc"], out / "compiler-path.log", out).decode().strip()
    swiftc = executable(swiftc_choice, "swiftc")
    sibling = Path(swiftc).parent / "swift"
    swift_choice = args.swift or os.environ.get("SWIFT") or (str(sibling) if sibling.exists() else None)
    swift = executable(swift_choice, "swift")
    receipt = {
        "swiftc": swiftc, "swift": swift,
        "version": command([swiftc, "--version"], out / "compiler.log", out).decode().strip(),
        "swiftc_binary_sha256": file_digest(Path(swiftc).resolve()),
        "swift_binary_sha256": file_digest(Path(swift).resolve()),
    }
    frontend = Path(swiftc).parent / "swift-frontend"
    if frontend.exists():
        receipt["swift_frontend"] = str(frontend)
        receipt["swift_frontend_sha256"] = file_digest(frontend.resolve())
    command(["uname", "-a"], out / "host-uname.log", out)
    if NATIVE:
        receipt.update({
            "macos_sdk_path": command(["xcrun", "--sdk", "macosx", "--show-sdk-path"],
                                      out / "sdk-path.log", out).decode().strip(),
            "macos_sdk_version": command(["xcrun", "--sdk", "macosx", "--show-sdk-version"],
                                         out / "sdk-version.log", out).decode().strip(),
        })
        command(["sw_vers"], out / "host-macos.log", out)
        command(["sysctl", "-n", "machdep.cpu.brand_string"], out / "host-cpu.log", out)
    return receipt


def compiler_flags(out: Path, compiler: dict[str, str]) -> list[str]:
    flags = ["-swift-version", "6", "-O", "-whole-module-optimization",
             "-enable-testing", "-warnings-as-errors",
             "-module-cache-path", str(out / "cache/modules")]
    if NATIVE:
        flags += ["-target", f"{platform.machine()}-apple-macosx26.0", "-sdk", compiler["macos_sdk_path"]]
    return flags


def search_flags(folder: Path) -> list[str]:
    return ["-I", str(folder), "-L", str(folder), "-Xlinker", "-rpath", "-Xlinker", str(folder)]


def library_path(folder: Path, module: str) -> Path:
    return folder / ("lib" + module + (".dylib" if NATIVE else ".so"))


def build_dependencies(out: Path, compiler: dict[str, str]) -> Path:
    folder = out / "build/shared"
    folder.mkdir(parents=True, exist_ok=True)
    receipts = {}
    for module in ("IlliquidCore", "IlliquidPlaybackCore"):
        sources = sorted((out / "inputs/shared" / module).rglob("*.swift"))
        if not sources:
            raise RuntimeError(f"Missing staged sources for {module}")
        library = library_path(folder, module)
        args = [
            compiler["swiftc"], *compiler_flags(out, compiler),
            "-emit-library", "-emit-module", "-module-name", module,
            "-emit-module-path", str(folder / (module + ".swiftmodule")),
            *(search_flags(folder) + ["-lIlliquidCore"] if module == "IlliquidPlaybackCore" else []),
            *map(str, sources), "-o", str(library),
        ]
        command(args, folder / f"build-{module}.log", out, build=True)
        receipts[module] = {
            "command": args,
            "sources_sha256": {str(path.relative_to(out)): file_digest(path) for path in sources},
            "library_sha256": file_digest(library),
            "swiftmodule_sha256": file_digest(folder / (module + ".swiftmodule")),
        }
    write_json(folder / "manifest.json", {"compiler": compiler, "modules": receipts})
    return folder


def build(variant: str, out: Path, compiler: dict[str, str], shared: Path) -> Path:
    folder = out / "build" / variant
    folder.mkdir(parents=True, exist_ok=True)
    module = "IlliquidPlaybackStateSpace"
    sources = sorted((out / "inputs" / variant / module).rglob("*.swift"))
    if not sources:
        raise RuntimeError(f"Missing staged sources for {variant} {module}")
    harness = out / "inputs/Harness.swift"
    library = library_path(folder, module)
    dependencies = [*search_flags(shared), "-lIlliquidPlaybackCore", "-lIlliquidCore"]
    module_args = [
        compiler["swiftc"], *compiler_flags(out, compiler),
        "-emit-library", "-emit-module", "-module-name", module,
        "-emit-module-path", str(folder / (module + ".swiftmodule")),
        *dependencies, *map(str, sources), "-o", str(library),
    ]
    command(module_args, folder / "build-module.log", out, build=True)
    binary = folder / "playback-progress"
    harness_args = [
        compiler["swiftc"], *compiler_flags(out, compiler), "-parse-as-library",
        *search_flags(folder), "-lIlliquidPlaybackStateSpace", *dependencies,
        str(harness), "-o", str(binary),
    ]
    command(harness_args, folder / "build-harness.log", out, build=True)
    write_json(folder / "manifest.json", {
        "variant": variant, "compiler": compiler,
        "commands": {"module": module_args, "harness": harness_args},
        "shared_build_manifest_sha256": file_digest(shared / "manifest.json"),
        "sources_sha256": {str(path.relative_to(out)): file_digest(path) for path in [*sources, harness]},
        "build_sha256": {path.name: file_digest(path) for path in [
            library, binary, folder / (module + ".swiftmodule"),
        ]},
    })
    return binary


def test(variant: str, configuration: str, out: Path, compiler: dict[str, str]) -> dict[str, object]:
    folder = out / f"{variant}-{configuration}"
    inputs = out / "inputs"
    files = {}
    for module in ("IlliquidCore", "IlliquidPlaybackCore", "IlliquidPlaybackStateSpace"):
        origin = inputs / ("shared" if module != "IlliquidPlaybackStateSpace" else variant) / module
        for path in sorted(origin.rglob("*.swift")):
            files["Sources/" + module + "/" + str(path.relative_to(origin))] = path
    for path in sorted((inputs / "tests").rglob("*.swift")):
        files["Tests/IlliquidPlaybackStateSpaceTests/" + str(path.relative_to(inputs / "tests"))] = path
    for relative, origin in files.items():
        destination = folder / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(origin, destination)
    package = folder / "Package.swift"
    package.write_text("""// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "PlaybackProgressQualification",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "IlliquidCore"),
        .target(name: "IlliquidPlaybackCore", dependencies: ["IlliquidCore"]),
        .target(name: "IlliquidPlaybackStateSpace", dependencies: ["IlliquidPlaybackCore"]),
        .testTarget(name: "IlliquidPlaybackStateSpaceTests",
                    dependencies: ["IlliquidCore", "IlliquidPlaybackCore", "IlliquidPlaybackStateSpace"])
    ]
)
""")
    args = [
        compiler["swift"], "test", "--package-path", str(folder), "--configuration", configuration,
        "--scratch-path", str(folder / "build"), "--jobs", "2", "--no-parallel",
        "--cache-path", str(out / "cache/packages"), "--config-path", str(out / "cache/config"),
        "--security-path", str(out / "cache/security"),
        "-Xswiftc", "-warnings-as-errors", "-Xswiftc", "-module-cache-path",
        "-Xswiftc", str(out / "cache/modules"),
    ]
    if not NATIVE:
        args.append("--use-integrated-swift-driver")
    log = folder / "tests.log"
    command(args, log, out, build=True)
    matches = re.findall(r"Test run with (\d+) tests?(?: in \d+ suites?)? passed", log.read_text())
    if not matches or int(matches[-1]) <= 0:
        raise RuntimeError(f"Missing successful nonzero Swift Testing summary: {log}")
    receipt = {
        "variant": variant, "configuration": configuration, "compiler": compiler, "test_command": args,
        "status": "passed", "test_count": int(matches[-1]),
        "sources_sha256": {relative: file_digest(folder / relative) for relative in [*files, "Package.swift"]},
        "test_log": str(log.relative_to(out)), "test_log_sha256": file_digest(log),
    }
    write_json(folder / "manifest.json", receipt)
    print(f"PASS {variant} {configuration}: {log}", flush=True)
    return receipt

def compare_pair(pair: list[dict[str, object]]) -> None:
    if len(pair) != 2 or {row["variant"] for row in pair} != set(VARIANTS):
        raise RuntimeError("Incomplete or duplicated measurement pair")
    for field in RESULT_FIELDS:
        if pair[0][field] != pair[1][field]:
            raise RuntimeError(f"Timing receipts differ in {field}: {pair[0]['workload']}")


def summarize(rows: list[dict[str, object]]) -> list[dict[str, object]]:
    if not rows:
        raise RuntimeError("No measurements to summarize")
    summaries = []
    for workload in dict.fromkeys(row["workload"] for row in rows):
        selected = [row for row in rows if row["workload"] == workload]
        rounds = sorted({row["round"] for row in selected})
        if len(rounds) < 2 or len(rounds) % 2 or rounds != list(range(len(rounds))):
            raise RuntimeError(f"Incomplete balanced rounds for {workload}")
        if len({row["iterations"] for row in selected}) != 1:
            raise RuntimeError(f"Iteration count changed within the final cohort: {workload}")
        ratios = []
        first_variants = []
        for round_index in rounds:
            pair = [row for row in selected if row["round"] == round_index]
            compare_pair(pair)
            if pair[0]["order"] != pair[1]["order"] or [row["variant"] for row in pair] != pair[0]["order"]:
                raise RuntimeError(f"Recorded pair order disagrees with observations: {workload}")
            first_variants.append(pair[0]["variant"])
            matched = {row["variant"]: row for row in pair}
            ratios.append(matched["candidate"]["elapsed_ns"] / matched["baseline"]["elapsed_ns"])
        if first_variants.count("baseline") != first_variants.count("candidate"):
            raise RuntimeError(f"AB/BA order is not balanced: {workload}")
        values = {}
        for variant in VARIANTS:
            samples = [row["elapsed_ns"] / row["operations"] for row in selected if row["variant"] == variant]
            values[variant] = {"median_ns": statistics.median(samples), "min_ns": min(samples),
                               "max_ns": max(samples), "samples": len(samples)}
        baseline, candidate = values["baseline"]["median_ns"], values["candidate"]["median_ns"]
        values.update({
            "workload": workload, "change_percent": (candidate / baseline - 1) * 100,
            "saved_ns": baseline - candidate, "paired_ratio_median": statistics.median(ratios),
            "paired_ratios": ratios, "improved_pairs": sum(ratio < 1 for ratio in ratios),
            "iterations": selected[0]["iterations"], "operations_per_process": selected[0]["operations"],
        })
        summaries.append(values)
    return summaries


def benchmark(out: Path, args: argparse.Namespace, compiler: dict[str, str]) -> None:
    shared = build_dependencies(out, compiler)
    binaries = {variant: build(variant, out, compiler, shared) for variant in VARIANTS}
    verification, verification_bytes, workload_lists = {}, {}, {}
    for variant, binary in binaries.items():
        verification_bytes[variant] = command([str(binary), "verify"], out / f"verify-{variant}.log", out)
        verification[variant] = json.loads(verification_bytes[variant])
        workload_lists[variant] = json.loads(command(
            [str(binary), "list"], out / f"list-{variant}.log", out))["workloads"]
    if verification["baseline"] != verification["candidate"]:
        raise RuntimeError("Full normalized progress-report/graph receipts differ; inspect verification logs")
    if workload_lists["baseline"] != workload_lists["candidate"]:
        raise RuntimeError("Variant workload lists differ")
    workloads = workload_lists["candidate"]
    if not workloads or len(set(workloads)) != len(workloads) or any(
        not isinstance(name, str) or not re.fullmatch(r"[a-z0-9][a-z0-9-]*", name) for name in workloads
    ):
        raise RuntimeError("Harness workload list must contain unique nonempty lowercase names")
    write_json(out / "verification.json", verification["candidate"])
    proof = {
        "exact_match": True,
        "output_sha256": {variant: digest(data) for variant, data in verification_bytes.items()},
        "canonical_receipt_sha256": digest(json.dumps(verification["candidate"], sort_keys=True).encode()),
        "top_level_array_counts": {key: len(value) for key, value in verification["candidate"].items()
                                   if isinstance(value, list)},
        "workloads": workloads,
    }
    write_json(out / "verification-summary.json", proof)
    print("PASS full graph and progress-report differential: " + json.dumps(proof["top_level_array_counts"]), flush=True)

    if args.mode == "regression":
        return  # Full differential only: never calibrate or run timing workloads.

    def measure(variant: str, workload: str, iterations: int, label: str) -> dict[str, object]:
        log = out / "processes" / f"{label}-{workload}-{variant}.log"
        row = json.loads(command([str(binaries[variant]), "benchmark", workload, str(iterations)], log, out))
        if any(field not in row for field in (*RESULT_FIELDS, "elapsed_ns")):
            raise RuntimeError("Harness omitted required measurement fields")
        if (row["schema_version"] != 1 or row["mode"] != "benchmark"
                or row["workload"] != workload or row["iterations"] != iterations
                or type(row["operations"]) is not int or row["operations"] <= 0
                or type(row["elapsed_ns"]) is not int or row["elapsed_ns"] <= 0
                or type(row["produced_count"]) is not int or not 0 <= row["produced_count"] <= row["operations"]
                or not isinstance(row["graph_metadata"], dict)
                or not isinstance(row["checksum"], str)
                or not isinstance(row["warmup_checksum"], str)):
            raise RuntimeError(f"Invalid benchmark receipt: {row}")
        row.update({"variant": variant, "process_log": str(log.relative_to(out)),
                    "process_log_sha256": file_digest(log)})
        return row

    counts = {}
    with (out / "calibration.jsonl").open("w") as receipt:
        for index, workload in enumerate(workloads):
            count = args.iterations or 1
            if args.iterations is None:
                for attempt in range(8):
                    order = VARIANTS if (index + attempt) % 2 == 0 else tuple(reversed(VARIANTS))
                    pair = [measure(variant, workload, count, f"calibration-{attempt:02d}") for variant in order]
                    compare_pair(pair)
                    for row in pair:
                        row.update({"attempt": attempt, "order": list(order)})
                        receipt.write(json.dumps(row, sort_keys=True) + "\n")
                    receipt.flush()
                    fastest = min(row["elapsed_ns"] for row in pair)
                    if fastest >= args.target_ms * 1_000_000:
                        break
                    count = max(count + 1, math.ceil(count * args.target_ms * 1_000_000 / fastest * 1.1))
                else:
                    raise RuntimeError(f"Unable to calibrate {workload}; choose explicit --iterations")
            counts[workload] = count
    write_json(out / "iteration-counts.json", counts)
    rows = []
    with (out / "measurements.jsonl").open("w") as receipt:
        for round_index in range(args.rounds):
            for index, workload in enumerate(workloads):
                order = VARIANTS if (round_index + index) % 2 == 0 else tuple(reversed(VARIANTS))
                pair = []
                for variant in order:
                    row = measure(variant, workload, counts[workload], f"round-{round_index:02d}")
                    row.update({"round": round_index, "order": list(order)})
                    receipt.write(json.dumps(row, sort_keys=True) + "\n")
                    receipt.flush()
                    rows.append(row)
                    pair.append(row)
                compare_pair(pair)
            print(f"Completed paired round {round_index + 1}/{args.rounds}", flush=True)
    summary = summarize(rows)
    write_json(out / "summary.json", summary)
    for item in summary:
        print(f"{item['workload']}: {item['baseline']['median_ns']:.1f} -> "
              f"{item['candidate']['median_ns']:.1f} ns/call ({item['change_percent']:+.2f}%)", flush=True)


def print_receipt(out: Path) -> None:
    # This compact log copy permits independent retrieval without unpacking the
    # artifact. Full source snapshots, full parity output and process/build logs
    # remain in the output directory and should also be uploaded.
    value = {"schema_version": 1}
    for name, key in (
        ("manifest.json", "manifest"), ("verification-summary.json", "verification"),
        ("summary.json", "summary"), ("tests.json", "tests"), ("completion.json", "completion"),
    ):
        path = out / name
        if path.exists():
            value[key] = json.loads(path.read_text())
    measurements = out / "measurements.jsonl"
    if measurements.exists():
        value["measurements"] = [json.loads(line) for line in measurements.read_text().splitlines()]
    print("PLAYBACK_PROGRESS_RECEIPT_BEGIN", flush=True)
    print(json.dumps(value, sort_keys=True, separators=(",", ":")), flush=True)
    print("PLAYBACK_PROGRESS_RECEIPT_END", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("test", "benchmark", "summarize", "regression"))
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--baseline-ref", default=BASELINE)
    parser.add_argument("--configuration", choices=("debug", "release"), default="debug")
    parser.add_argument("--variant", choices=(*VARIANTS, "both"), default="both")
    parser.add_argument("--rounds", type=int, default=10)
    parser.add_argument("--iterations", type=int, help="Fixed iterations per workload; otherwise calibrate both variants")
    parser.add_argument("--target-ms", type=float, default=100.0, help="Pilot duration target for the faster variant")
    parser.add_argument("--swiftc")
    parser.add_argument("--swift")
    args = parser.parse_args()
    try:
        validate_mode(args.mode, sys.argv[1:])
    except RuntimeError as error:
        parser.error(str(error))
    if args.rounds < 2 or args.rounds % 2 or (args.iterations is not None and args.iterations <= 0) or not math.isfinite(args.target_ms) or args.target_ms <= 0:
        parser.error("Use even --rounds >= 2, positive --iterations, and finite positive --target-ms")
    out = args.output.resolve()
    if args.mode != "summarize" and out.exists() and (not out.is_dir() or any(out.iterdir())):
        parser.error("Use a fresh --output directory; existing evidence must not be overwritten")
    out.mkdir(parents=True, exist_ok=True)
    if args.mode == "summarize":
        rows = [json.loads(line) for line in (out / "measurements.jsonl").read_text().splitlines()]
        write_json(out / "summary.json", summarize(rows))
        print_receipt(out)
        return
    try:
        queue = {"available": KYOTO.is_file(), "path": str(KYOTO)}
        if queue["available"]:
            print("Builds will use Kyoto; completion, status and logs are checked before continuing.", flush=True)
        else:
            print("Kyoto is unavailable on this host; building directly and serially in isolated output directories.", flush=True)
        receipt = snapshot(out, args)
        compiler = toolchain(args, out)
        receipt.update({
            "schema_version": 1, "recorded_utc": datetime.now(timezone.utc).isoformat(),
            "platform": platform.platform(), "machine": platform.machine(), "cpu_count": os.cpu_count(),
            "python": sys.version, "compiler": compiler, "macos_target": "26.0" if NATIVE else None, "kyoto": queue,
            "ci_image": {key: os.environ[key] for key in ("ImageOS", "ImageVersion") if key in os.environ},
            "arguments": {key: str(value) if isinstance(value, Path) else value for key, value in vars(args).items()},
            "method": ("Regression only: exact historical/reviewed focal sources with identical captured reviewed current support; "
                      "both variants in debug/release plus complete graph/report differential; no timings."
                      if args.mode == "regression" else "Unmodified actual MediaTrack/playback-core/state-space sources; "
                      "separate optimized production shared modules and harness; "
                      "fresh-process serial balanced AB/BA pairs; complete normalized reports and graph receipts before timing."),
        })
        write_json(out / "manifest.json", receipt)
        if args.mode == "regression":
            results = [test(variant, configuration, out, compiler)
                       for configuration in ("debug", "release") for variant in VARIANTS]
            write_json(out / "tests.json", results)
            benchmark(out, args, compiler)
        elif args.mode == "test":
            results = [test(variant, args.configuration, out, compiler)
                       for variant in (VARIANTS if args.variant == "both" else (args.variant,))]
            write_json(out / "tests.json", results)
        else:
            benchmark(out, args, compiler)
        write_json(out / "completion.json", {"status": "passed", "mode": args.mode,
                   "completed_utc": datetime.now(timezone.utc).isoformat()})
    except Exception as error:
        write_json(out / "completion.json", {"status": "failed", "mode": args.mode,
                   "error": str(error), "recorded_utc": datetime.now(timezone.utc).isoformat()})
        raise
    finally:
        print_receipt(out)


if __name__ == "__main__":
    main()
