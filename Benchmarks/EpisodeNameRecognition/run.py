#!/usr/bin/env python3
"""Qualify episode-folder parsing with exact production Swift and a pinned baseline."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import random
import re
import shutil
import statistics
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
SOURCE = ROOT / "Sources/IlliquidCore/MediaLibrary/MediaNameRecognition.swift"
BOUNDARY = HERE / "FoundationBoundary.swift"
# Exact corpus-generating block from Driver.swift blob b4716d684dfe61aee3dcd22d88abd439e77673b3.
CORPUS_GENERATOR_SHA256 = "885fe65a3d6b1752ad52ec9f0d939fc7d5768942f5b74fee0fe46b47f713875c"
ORDERED_CORPUS_SHA256 = "4ba3d2fa05c889357779254a4de619d41210f143a715335f77c14f22e65ef38b"
FLAGS = ["-O", "-whole-module-optimization", "-swift-version", "6", "-parse-as-library", "-j", "2"]
TESTS = ["MediaNameRecognitionTests.swift", "EpisodeNameRecognitionRegressionTests.swift"]
SCENARIOS = [
    "named-episode-no-year", "named-episode-with-year", "bare-season-episode",
    "bare-parent-year-episode", "unclassified-bare-episode", "mixed-library", "movie-controls",
]
PACKAGE = '''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "EpisodeNameRecognitionQualification", targets: [
    .target(name: "IlliquidCore"),
    .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"]),
])
'''


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def run(command: list[str], output: Path, label: str) -> str:
    with (output / "commands.jsonl").open("a", encoding="utf-8") as log:
        log.write(json.dumps({"label": label, "command": command, "cwd": str(ROOT)}) + "\n")
    result = subprocess.run(command, cwd=ROOT, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT)
    (output / f"{label}.log").write_text(result.stdout, encoding="utf-8")
    if result.returncode:
        print(result.stdout, flush=True)
        raise RuntimeError(f"{label} exited {result.returncode}; see {output / (label + '.log')}")
    return result.stdout


def environment(output: Path, reference: str) -> dict:
    driver = (HERE / "Driver.swift").read_bytes()
    corpus_generator = driver[driver.index(b"private let scenarios ="):driver.index(b"\nprivate func emit(")]
    if hashlib.sha256(corpus_generator).hexdigest() != CORPUS_GENERATOR_SHA256:
        raise RuntimeError("Original ordered corpus generator changed; review its receipt before qualification")
    reference_directory = HERE / ("baseline" if reference == "main" else "folder-reuse")
    reference_source = reference_directory / "MediaNameRecognition.swift"
    manifest = json.loads((reference_directory / "manifest.json").read_text())
    if sha256(reference_source) != manifest["sha256"]:
        raise RuntimeError("Pinned baseline failed its SHA-256 receipt")
    swift = shutil.which("swift")
    swiftc = shutil.which("swiftc")
    if not swift or not swiftc:
        raise RuntimeError("Swift 6.1+ must be installed and on PATH")
    result = {
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "platform": platform.platform(), "machine": platform.machine(),
        "processor": platform.processor(), "cpu_count": os.cpu_count(),
        "swift": swift, "swiftc": swiftc,
        "toolchain": run([swiftc, "--version"], output, "toolchain").strip(),
        "revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "baseline": manifest,
        "reference_name": reference,
        "reference_source": str(reference_source.relative_to(ROOT)),
        "source_sha256": {
            str(path.relative_to(ROOT)): sha256(path)
            for path in [SOURCE, reference_source, HERE / "Driver.swift", BOUNDARY, Path(__file__).resolve()]
        },
        "corpus_generator_sha256": CORPUS_GENERATOR_SHA256,
    }
    if platform.system() == "Darwin":
        result["hardware"] = run(["sysctl", "-n", "machdep.cpu.brand_string"], output, "hardware").strip()
        result["os_version"] = run(["sw_vers"], output, "os-version").strip()
    return result


def test(args: argparse.Namespace, metadata: dict) -> None:
    original = ROOT / metadata["reference_source"] if args.implementation == "baseline" else SOURCE
    with tempfile.TemporaryDirectory(prefix="episode-recognition-tests-", dir=args.output) as work:
        package = Path(work)
        (package / "Package.swift").write_text(PACKAGE, encoding="utf-8")
        sources = package / "Sources/IlliquidCore"
        tests = package / "Tests/IlliquidCoreTests"
        sources.mkdir(parents=True)
        tests.mkdir(parents=True)
        shutil.copyfile(original, sources / "MediaNameRecognition.swift")
        for name in TESTS:
            shutil.copyfile(ROOT / "Tests/IlliquidCoreTests" / name, tests / name)
        command = [metadata["swift"], "test", "--package-path", str(package),
                   "--configuration", args.configuration, "--no-parallel", "--jobs", "2"]
        text = run(command, args.output, "tests")
        print(text, end="", flush=True)
        write_json(args.output / "receipt.json", {
            "environment": metadata, "implementation": args.implementation,
            "configuration": args.configuration, "exit_code": 0,
            "compiled_source_sha256": sha256(original),
            "test_sha256": {name: sha256(tests / name) for name in TESTS},
            "source_adaptations": [],
        })


def transform_source(source: bytes, prefix: str, adapted: bool) -> tuple[bytes, dict]:
    """Only symbol renames and the one reviewed parent-path expression may change."""
    text = source.decode("utf-8")
    renames = {}
    if prefix:
        for name in ["RecognizedMediaName", "MediaNameRecognition"]:
            text, count = re.subn(r"\b" + name + r"\b", prefix + name, text)
            if count == 0:
                raise RuntimeError(f"Missing symbol to rename: {name}")
            renames[name] = count
    replacements = 0
    if adapted:
        expression = "path.deletingLastPathComponent"
        if text.count(expression) != 1 or text.count(".deletingLastPathComponent") != 1:
            raise RuntimeError("Expected exactly one unambiguous parent-path expression")
        text = text.replace(expression, "benchmarkParentPath(path)")
        replacements = 1
    return text.encode("utf-8"), {"type_renames": renames, "parent_path_replacements": replacements}


def generated_source(original: Path, destination: Path, prefix: str, adapted: bool) -> dict:
    generated, transformations = transform_source(original.read_bytes(), prefix, adapted)
    destination.write_bytes(generated)
    return {"original_source": str(original), "original_sha256": sha256(original),
            "generated_source": str(destination), "generated_sha256": sha256(destination),
            **transformations}


def compile_driver(args: argparse.Namespace, metadata: dict, build: Path, role: str) -> Path:
    proof = role == "foundation-proof"
    adapted = role == "adapted-differential"
    if proof and platform.system() != "Darwin":
        raise RuntimeError("foundation-proof requires native macOS Foundation")
    if adapted and platform.system() != "Linux":
        raise RuntimeError("The differential adapter is Linux-only; use foundation-proof on macOS")
    directory = args.output / "sources" / role
    directory.mkdir(parents=True)
    reference = ROOT / metadata["reference_source"]
    baseline = directory / "Baseline.swift"
    transformations = [generated_source(reference, baseline, "Baseline", adapted)]
    candidate = SOURCE
    sources = []
    flags = list(FLAGS)
    if adapted:
        candidate = directory / "Candidate.swift"
        transformations.append(generated_source(SOURCE, candidate, "", True))
        flags += ["-D", "ADAPTED_FOUNDATION_BOUNDARY"]
    sources += [candidate, baseline]
    if proof:
        for original, name, prefix in [(SOURCE, "AdaptedCandidate", "Adapted"),
                                       (reference, "AdaptedBaseline", "AdaptedBaseline")]:
            destination = directory / f"{name}.swift"
            transformations.append(generated_source(original, destination, prefix, True))
            sources.append(destination)
        flags += ["-D", "FOUNDATION_BOUNDARY_PROOF"]
    if adapted or proof:
        helper = directory / BOUNDARY.name
        shutil.copyfile(BOUNDARY, helper)
        sources.append(helper)
    sources.append(HERE / "Driver.swift")
    if not (adapted or proof):
        # Keep the original timing receipt fields as well as the detailed manifest.
        metadata["compiled_baseline_sha256"] = sha256(baseline)
        metadata["baseline_adaptation"] = "Rename the two top-level types only"
        metadata["compiler_flags"] = flags
    executable = build / role
    command = [metadata["swiftc"], *flags, *map(str, sources), "-o", str(executable)]
    receipt = {
        "role": role, "command": command, "source_transformations": transformations,
        "compiled_source_sha256": {str(path): sha256(path) for path in sources},
        "qualification_scope": ("macOS original/adapted equivalence proof" if proof else
                                "adapted Foundation boundary" if adapted else "native Foundation"),
        "timing_allowed": not (adapted or proof),
    }
    metadata.setdefault("compilations", []).append(receipt)
    write_json(args.output / "environment.json", metadata)
    run(command, args.output, "compile-" + role)
    receipt["executable_sha256"] = sha256(executable)
    write_json(args.output / "environment.json", metadata)
    return executable


def record_corpus(executable: Path, output: Path) -> dict:
    paths = json.loads(run([str(executable), "--corpus"], output, "corpus"))["paths"]
    if (len(paths), paths.count(""), paths.count(".mkv"), sum(p.endswith("/") for p in paths)) != (16300, 1, 1, 27):
        raise RuntimeError("Original corpus invariants changed")
    encoded = json.dumps(paths, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    ordered_hash = hashlib.sha256(encoded).hexdigest()
    if ordered_hash != ORDERED_CORPUS_SHA256:
        raise RuntimeError("Original ordered corpus hash changed")
    receipt = {"cases": len(paths), "unique_paths": len(set(paths)),
               "duplicate_entries": len(paths) - len(set(paths)), "empty_paths": paths.count(""),
               "empty_basename_mkv": paths.count(".mkv"), "directory_only_paths": 27,
               "ordered_paths_sha256": ordered_hash,
               "hash_encoding": "UTF-8 compact JSON array, ensure_ascii=False; order and duplicates retained",
               "original_driver_blob": "b4716d684dfe61aee3dcd22d88abd439e77673b3",
               "generator_sha256": CORPUS_GENERATOR_SHA256}
    write_json(output / "corpus.json", receipt)
    return receipt


def benchmark(args: argparse.Namespace, metadata: dict) -> None:
    with tempfile.TemporaryDirectory(prefix="episode-recognition-build-", dir=args.output) as work:
        build = Path(work)
        proof = args.command == "foundation-proof"
        role = "foundation-proof" if proof else "adapted-differential" if platform.system() == "Linux" else "native"
        executable = compile_driver(args, metadata, build, role)
        metadata["corpus"] = record_corpus(executable, args.output)
        mode = "foundation-proof" if proof else "differential"
        differential = json.loads(run([str(executable), "--" + mode], args.output, mode))
        if differential.get("ok") is not True or differential.get("cases") != 16_300:
            raise RuntimeError("Full correctness comparison did not pass")
        write_json(args.output / "environment.json", metadata)
        if args.command in ["differential", "foundation-proof"]:
            result = {"environment": metadata, mode.replace("-", "_"): differential}
            write_json(args.output / "results.json", result)
            write_json(args.output / "receipt.json", result)
            print(json.dumps(differential, indent=2), flush=True)
            return
        # Linux must pass the complete adapted comparison first, then compile a
        # separate timing binary with the exact candidate and rename-only baseline.
        if role == "adapted-differential":
            executable = compile_driver(args, metadata, build, "timing")
        observations = []
        for scenario in args.scenarios:
            for repeat in range(args.repeats):
                pair = []
                order = ["baseline", "candidate"] if repeat % 2 == 0 else ["candidate", "baseline"]
                for implementation in order:
                    label = f"{scenario}-{repeat:02d}-{implementation}"
                    value = json.loads(run([str(executable), "--benchmark", implementation, scenario,
                                            str(args.iterations), str(args.rounds)], args.output, label))
                    value["repeat"] = repeat
                    value["execution_order"] = order
                    pair.append(value)
                    observations.append(value)
                if pair[0]["checksum"] != pair[1]["checksum"]:
                    raise RuntimeError(f"Timed result checksum mismatch in {scenario}, pair {repeat}")
                print(f"Completed {scenario} pair {repeat + 1}/{args.repeats}", flush=True)
        summaries = {}
        rng = random.Random(20261017)
        for scenario in args.scenarios:
            values = {name: [] for name in ["baseline", "candidate"]}
            for observation in observations:
                if observation["scenario"] == scenario:
                    values[observation["implementation"]].append(statistics.median(
                        observation["nanoseconds_per_operation"]))
            ratios = [candidate / baseline for baseline, candidate in
                      zip(values["baseline"], values["candidate"])]
            bootstraps = sorted(statistics.median(rng.choices(ratios, k=len(ratios))) for _ in range(10000))
            summaries[scenario] = {
                "baseline_median_ns_per_file": statistics.median(values["baseline"]),
                "candidate_median_ns_per_file": statistics.median(values["candidate"]),
                "paired_median_candidate_over_baseline": statistics.median(ratios),
                "paired_median_reduction_percent": 100 * (1 - statistics.median(ratios)),
                "paired_ratio_bootstrap_95_percent_interval": [bootstraps[249], bootstraps[9749]],
                "pairs": len(ratios),
            }
        evidence = {"environment": metadata, "differential": differential,
                    "summary": summaries, "observations": observations,
                    "method": "Median of per-process medians; paired candidate/baseline ratios; balanced alternating order; all observations retained"}
        write_json(args.output / "results.json", evidence)
        print(json.dumps(summaries, indent=2), flush=True)


def positive(text: str) -> int:
    value = int(text)
    if value < 1:
        raise argparse.ArgumentTypeError("must be positive")
    return value


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    tests = subparsers.add_parser("test")
    tests.add_argument("--configuration", choices=["debug", "release"], default="debug")
    tests.add_argument("--implementation", choices=["baseline", "candidate"], default="candidate")
    differential = subparsers.add_parser("differential", help="Compare the full corpus without running timings")
    proof = subparsers.add_parser("foundation-proof", help="Prove the adapter against original macOS Foundation; no timings")
    bench = subparsers.add_parser("benchmark")
    bench.add_argument("--repeats", type=positive, default=12)
    bench.add_argument("--iterations", type=positive, default=128,
                       help="Complete scans of the 64-path corpus per timed round")
    bench.add_argument("--rounds", type=positive, default=3)
    bench.add_argument("--scenarios", nargs="+", choices=SCENARIOS, default=SCENARIOS)
    for command in [tests, differential, proof, bench]:
        command.add_argument("--output", type=Path, required=True)
        command.add_argument("--reference", choices=["main", "folder-reuse"], default="main")
    args = parser.parse_args()
    args.output = args.output.resolve()
    if args.output.exists() and any(args.output.iterdir()):
        parser.error("--output must be empty; use a fresh directory for each run")
    args.output.mkdir(parents=True, exist_ok=True)
    metadata = environment(args.output, args.reference)
    write_json(args.output / "environment.json", metadata)
    if args.command == "test":
        test(args, metadata)
    else:
        benchmark(args, metadata)


if __name__ == "__main__":
    main()
