#!/usr/bin/env python3
"""Portable qualification of the exact ratio parser, without geometry emulation."""
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
NATIVE = ROOT / "Benchmarks/VideoRatioParsing"
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
SOURCE = "Sources/IlliquidCore/Player/VideoPresentationGeometry.swift"
SCENARIOS = ["ratio_nil", "ratio_scalar", "ratio_colon", "ratio_invalid"]


def sha(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def save(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def excerpt(raw: bytes, start: bytes, end: bytes) -> bytes:
    if raw.count(start) != 1 or raw.count(end) != 1 or raw.index(start) >= raw.index(end):
        raise ValueError(f"Extraction anchors changed: {start!r}; review the portable subset")
    return raw[raw.index(start):raw.index(end)]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--target-ms", type=float, default=150)
    parser.add_argument("--minimum-ms", type=float, default=60)
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument("--inside-kyoto", action="store_true")
    args = parser.parse_args()
    if args.pairs < 6 or args.pairs % 2 or not 100 <= args.target_ms <= 150 or not 60 <= args.minimum_ms < args.target_ms:
        parser.error("Use even pairs >= 6, target-ms in 100...150, and 60 <= minimum-ms < target-ms")
    out = args.output.resolve()
    if out.exists() and any(out.iterdir()):
        parser.error("Use a new or empty output directory")
    out.mkdir(parents=True, exist_ok=True)
    for name in ["commands", "snapshots", "generated"]:
        (out / name).mkdir()
    inputs = {path: path.read_bytes() for path in [ROOT / SOURCE, NATIVE / "Driver.swift", NATIVE / "baseline.json",
                                                 HERE / "run.py", HERE / "Driver.swift", HERE / "README.md"]}
    for path, raw in inputs.items():
        snapshot = out / "snapshots" / path.relative_to(ROOT)
        snapshot.parent.mkdir(parents=True, exist_ok=True)
        snapshot.write_bytes(raw)
    environment = os.environ.copy()
    environment["CLANG_MODULE_CACHE_PATH"] = str(out / "module-cache")
    commands: list[dict] = []

    def run(argv: list[str | Path], timeout: int = 600) -> str:
        command = [str(value) for value in argv]
        number, started = len(commands), time.time()
        result = subprocess.run(command, cwd=ROOT, env=environment, capture_output=True, timeout=timeout)
        stdout, stderr = out / "commands" / f"{number:04d}.stdout", out / "commands" / f"{number:04d}.stderr"
        stdout.write_bytes(result.stdout); stderr.write_bytes(result.stderr)
        item = {"command": command, "returncode": result.returncode, "started_unix": started,
                "elapsed_seconds": time.time() - started,
                "stdout": str(stdout.relative_to(out)), "stdout_sha256": sha(result.stdout),
                "stderr": str(stderr.relative_to(out)), "stderr_sha256": sha(result.stderr)}
        commands.append(item)
        with (out / "commands.jsonl").open("a") as stream:
            stream.write(json.dumps(item, sort_keys=True) + "\n")
        if result.returncode:
            raise RuntimeError(f"Command failed: {command!r}\n{result.stderr.decode(errors='replace')[-5000:]}")
        return result.stdout.decode()

    manifest = json.loads(inputs[NATIVE / "baseline.json"])
    baseline = run(["git", "show", f"{BASELINE}:{SOURCE}"]).encode()
    if manifest["revision"] != BASELINE or sha(baseline) != manifest["source_sha256"][SOURCE]:
        raise ValueError("Complete production baseline differs from the native study's pinned source")
    (out / "snapshots" / "baseline-VideoPresentationGeometry.swift").write_bytes(baseline)
    functions, wrappers = {}, {}
    for variant, raw in [("baseline", baseline), ("candidate", inputs[ROOT / SOURCE])]:
        function = excerpt(raw, b"    public static func ratio(", b"\n    public init(sourceSize:")
        functions[variant] = function
        wrappers[variant] = b"import Foundation\n\npublic enum VideoPresentationGeometry {\n" + function + b"\n}\n"
        (out / "generated" / f"{variant}-ratio.swift").write_bytes(function)
        (out / "generated" / f"{variant}-Parser.swift").write_bytes(wrappers[variant])
    if baseline.replace(functions["baseline"], b"", 1) != inputs[ROOT / SOURCE].replace(functions["candidate"], b"", 1):
        raise ValueError("Production source outside the exact ratio declaration changed")
    native_driver = inputs[NATIVE / "Driver.swift"]
    pieces = {
        "inputs": excerpt(native_driver, b"let scalarInputs = ", b"\nfunc settings("),
        "corpus": excerpt(native_driver, b"func bits(", b"\nfunc verify()"),
        "loop": excerpt(native_driver, b"@inline(never)\nfunc ratioLoop(", b"\n@inline(never)\nfunc geometryLoop("),
        "authored_checks": excerpt(native_driver, b"    let expected: [(String?, Double?)]", b"\n    let source = CGSize("),
    }
    for name, raw in pieces.items():
        (out / "generated" / f"excerpt-{name}.swift").write_bytes(raw)
    support = b"import Foundation\nimport IlliquidCore\n\n" + b"\n\n".join(pieces[name] for name in ["inputs", "corpus", "loop"])
    support += b'''\n\nfunc verifyRatio() -> [String: Any] {\n''' + pieces["authored_checks"] + b'''
    let rows: [[String: Any]] = ratioCorpus().map {
        ["input": $0.map { $0 as Any } ?? NSNull(), "bits": bits(VideoPresentationGeometry.ratio($0))]
    }
    return ["authored_checks": expected.count, "ratio": rows]
}
'''
    support_path = out / "generated" / "Support.swift"
    support_path.write_bytes(support)
    driver = out / "snapshots" / (HERE / "Driver.swift").relative_to(ROOT)
    receipt = {"baseline_revision": BASELINE, "candidate_revision": run(["git", "rev-parse", "HEAD"]).strip(),
        "working_tree": run(["git", "status", "--short"]), "pairs": args.pairs,
        "target_ms": args.target_ms, "minimum_ms": args.minimum_ms,
        "input_sha256": {str(path.relative_to(ROOT)): sha(raw) for path, raw in inputs.items()},
        "baseline_full_source_sha256": sha(baseline), "exact_function_sha256": {v: sha(raw) for v, raw in functions.items()},
        "wrapper_sha256": {v: sha(raw) for v, raw in wrappers.items()},
        "native_driver_excerpt_sha256": {name: sha(raw) for name, raw in pieces.items()}, "support_sha256": sha(support),
        "scope": "Exact production parser subset; no CoreGraphics emulation, geometry tests, native app, or memory measurement"}
    save(out / "receipt.json", receipt)
    generated_hashes = {path: sha(path.read_bytes()) for path in (out / "generated").iterdir()}
    if args.prepare_only:
        save(out / "completion.json", {"prepared": True, "compiled": False, "qualified": False, "scope": "parser only"})
        print("Prepared exact parser/corpus/loop extractions; Swift compilation and execution were not run.")
        return
    kyoto = Path("/Volumes/seed1/Projects/kyoto/kyoto.py")
    if kyoto.is_file() and not args.inside_kyoto:
        raise RuntimeError("Kyoto is available: submit this entire runner through it with --inside-kyoto")
    if not kyoto.is_file():
        print("Kyoto is unavailable; running isolated portable parser builds directly and serially.", flush=True)
    swiftc = shutil.which("swiftc")
    if not swiftc:
        raise RuntimeError("swiftc must be available on PATH")
    flags = ["-swift-version", "6", "-O", "-whole-module-optimization", "-parse-as-library"]
    save(out / "environment.json", {"platform": platform.platform(), "machine": platform.machine(),
        "compiler": run([swiftc, "--version"]).strip(), "flags": flags, "system": platform.uname()._asdict(),
        "scope": "Portable parser only; host/toolchain results are not native geometry performance"})
    binaries, artifacts, traces = {}, {}, {}
    for variant in wrappers:
        folder = out / variant
        folder.mkdir()
        library = folder / ("libIlliquidCore.dylib" if sys.platform == "darwin" else "libIlliquidCore.so")
        module, binary = folder / "IlliquidCore.swiftmodule", folder / "driver"
        install_name = ["-Xlinker", "-install_name", "-Xlinker", "@rpath/libIlliquidCore.dylib"] if sys.platform == "darwin" else []
        run([swiftc, *flags, "-emit-library", "-emit-module", "-module-name", "IlliquidCore",
             "-emit-module-path", module, out / "generated" / f"{variant}-Parser.swift", *install_name, "-o", library])
        run([swiftc, *flags, "-I", folder, "-L", folder, "-lIlliquidCore", "-Xlinker", "-rpath", "-Xlinker", folder,
             support_path, driver, "-o", binary])
        binaries[variant] = binary
        for artifact in [library, module, binary]:
            artifacts[artifact] = sha(artifact.read_bytes())
        trace = run([binary, "verify"])
        (out / f"{variant}-trace.json").write_text(trace)
        traces[variant] = json.loads(trace)
    if traces["baseline"] != traces["candidate"]:
        raise ValueError("Exact optional Double output traces differ")
    verification = {"exact_parser_trace_match": True, "ratio_cases": len(traces["candidate"]["ratio"]),
        "authored_checks_per_variant": traces["candidate"]["authored_checks"],
        "trace_sha256": {v: sha((out / f"{v}-trace.json").read_bytes()) for v in wrappers},
        "geometry_tests_run": False, "repository_test_suites_run": False}
    save(out / "verification.json", verification)

    def measure(variant: str, scenario: str, count: int) -> dict:
        row = json.loads(run([binaries[variant], scenario, str(count)]))
        if row["scenario"] != scenario or row["iterations"] != count or min(row["wall_ns"], row["cpu_ns"]) <= 0:
            raise ValueError("Malformed timing observation")
        return row

    counts, calibration, rows = {}, [], []
    for scenario in SCENARIOS:
        needs = []
        for variant in wrappers:
            count = 16_384
            for _ in range(8):
                row = measure(variant, scenario, count)
                calibration.append(dict(row, variant=variant))
                elapsed = min(row["wall_ns"], row["cpu_ns"])
                if elapsed >= args.target_ms * 1_000_000:
                    break
                count = math.ceil(count * max(1.5, args.target_ms * 1_100_000 / elapsed) / 32) * 32
                if count > 100_000_000:
                    raise ValueError("Calibration requires too many iterations")
            else:
                raise ValueError("Calibration did not converge")
            needs.append(count)
        counts[scenario] = max(needs)
    save(out / "calibration.json", {"iterations": counts, "observations": calibration})
    for pair in range(args.pairs):
        order = ["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]
        print(f"Parser timing pair {pair + 1}/{args.pairs}: {'/'.join(order)}", flush=True)
        for scenario in SCENARIOS:
            paired = []
            for position, variant in enumerate(order):
                row = dict(measure(variant, scenario, counts[scenario]), variant=variant, pair=pair, order=position)
                if min(row["wall_ns"], row["cpu_ns"]) < args.minimum_ms * 1_000_000:
                    raise ValueError("Observation below minimum duration; preserve this run and use a new output directory")
                rows.append(row); paired.append(row)
                with (out / "measurements.jsonl").open("a") as stream:
                    stream.write(json.dumps(row, sort_keys=True) + "\n")
            if paired[0]["checksum"] != paired[1]["checksum"]:
                raise ValueError("Timed checksums differ")
    summary = {}
    for scenario in SCENARIOS:
        result = {}
        for metric in ["wall_ns", "cpu_ns"]:
            values = {v: [r[metric] / r["iterations"] for r in rows if r["scenario"] == scenario and r["variant"] == v]
                      for v in wrappers}
            result[metric + "_per_call"] = {v: {"median": statistics.median(data), "min": min(data), "max": max(data)}
                                             for v, data in values.items()}
            result[metric + "_speedup"] = statistics.median(values["baseline"]) / statistics.median(values["candidate"])
        summary[scenario] = result
    for path, raw in inputs.items():
        if path.read_bytes() != raw:
            raise ValueError(f"Input changed during experiment: {path}")
    for path, digest in {**generated_hashes, **artifacts}.items():
        if sha(path.read_bytes()) != digest:
            raise ValueError(f"Generated or compiled artifact changed: {path}")
    save(out / "artifacts.json", {str(path.relative_to(out)): value for path, value in artifacts.items()})
    save(out / "summary.json", summary)
    save(out / "completion.json", {"prepared": True, "compiled": True, "qualified": True,
        "scope": "Portable ratio parser only", "observations": len(rows), "expected_observations": args.pairs * len(SCENARIOS) * 2,
        "input_and_artifact_stability_checked": True, "native_geometry_qualification": False})
    print(json.dumps({"verification": verification, "summary": summary}, indent=2), flush=True)


if __name__ == "__main__":
    main()
