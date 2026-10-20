#!/usr/bin/env python3
"""Paired native disk-cache measurements with exact production sources and output gates."""
import argparse
import hashlib
import json
import os
import platform
import statistics
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
BASELINE = "33fff16155c3472960f88e04c72dfdfdefd56dcf"
CORE = ["Sources/IlliquidCore/" + path for path in (
    "Player/ThumbnailPolicy.swift", "Utilities/NonDecodePerformance.swift",
    "Persistence/MediaContentVersion.swift", "Persistence/MediaPlaybackSettings.swift",
    "Player/MediaTrack.swift")]
NATIVE = ["Sources/IlliquidNativePlayback/Media/" + name + ".swift" for name in (
    "NativeThumbnailCache", "NativeThumbnailDiskCache", "ThumbnailPromotionMailbox",
    "ThumbnailBlockingReader", "NativeFileContentVersion")]
CHANGED = "Sources/IlliquidNativePlayback/Media/NativeThumbnailDiskCache.swift"
HEAP = "Sources/IlliquidNativePlayback/Media/ThumbnailDiskEvictionHeap.swift"


def workloads():
    def case(name, count, mib, *, layout="exact-byte-cap", background=False,
             prefill=False, target=None, evictions=32, byte_pressure=32, count_pressure=0):
        return dict(name=name, seedCount=count, initialMiB=mib, seedLayout=layout,
                    insertionCount=32 if target is None else 0, incomingBackground=background,
                    prefill=prefill, targetMiB=target, expectedEvictions=evictions,
                    expectedBytePressure=byte_pressure, expectedCountPressure=count_pressure)
    return [
        case("byte-foreground-1000", 1000, 4),
        case("byte-foreground-4000", 4000, 16),
        case("byte-foreground-8191", 8191, 32),
        case("byte-background-4000", 4000, 16, background=True),
        case("count-foreground-8192", 8191, 64, layout="fixed-payload", prefill=True,
             byte_pressure=0, count_pressure=32),
        case("count-background-8192", 8191, 64, layout="fixed-payload", background=True,
             prefill=True, byte_pressure=0, count_pressure=32),
        case("no-trim-4000", 4000, 64, layout="fixed-payload", evictions=0, byte_pressure=0),
        case("shrink-8191-to-4096", 8191, 64, layout="fixed-payload", target=16,
             evictions=4095, byte_pressure=1),
        case("disable-4096", 4096, 64, layout="fixed-payload", target=0,
             evictions=4096, byte_pressure=1),
    ]


def sha(data):
    return hashlib.sha256(data).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def append_json(path, value):
    with path.open("a") as output:
        output.write(json.dumps(value, sort_keys=True) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pairs", type=int, default=8)
    parser.add_argument("--verify-only", action="store_true")
    parser.add_argument("--swiftc", type=Path)
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("Requires native macOS CoreGraphics/ImageIO; no Linux adapters are used.")
    if args.pairs < 2 or args.pairs > 20 or args.pairs % 2:
        parser.error("--pairs must be an even number between 2 and 20 for balanced AB/BA order.")
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("--output must be new or empty.")
    output.mkdir(parents=True, exist_ok=True)
    for child in ["build", "module-cache", "sources", "cases", "receipts", "fixtures", "driver"]:
        (output / child).mkdir()
    environment = os.environ.copy()
    environment["SWIFT_DETERMINISTIC_HASHING"] = "1"
    # Production diagnostics remain disabled for this standalone cache experiment.
    environment.pop("ILLIQUID_ENABLE_BENCHMARK_OVERRIDES", None)
    environment.pop("ILLIQUID_BENCHMARK_NONDECODE", None)
    commands = []

    def run(command, timeout=300):
        command = [str(value) for value in command]
        start = time.monotonic()
        process = subprocess.run(command, cwd=ROOT, env=environment,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
        record = dict(index=len(commands), command=command, cwd=str(ROOT),
                      exit=process.returncode, stdout=process.stdout.decode("utf-8"),
                      stderr=process.stderr.decode("utf-8"), seconds=time.monotonic() - start)
        commands.append(record)
        append_json(output / "commands.jsonl", record)
        if process.returncode:
            raise RuntimeError(f"Command failed: {command}\n{record['stderr']}\n{record['stdout']}")
        return process.stdout

    print("Staging frozen baseline and unchanged production dependencies", flush=True)
    sources = {}
    paths = {"baseline": {}, "candidate": {}}
    for path in CORE + NATIVE:
        baseline = run(["git", "show", f"{BASELINE}:{path}"])
        candidate = (ROOT / path).read_bytes()
        if path != CHANGED and baseline != candidate:
            raise RuntimeError(f"Supporting source changed since baseline: {path}")
        for variant, content in [("baseline", baseline), ("candidate", candidate)]:
            destination = output / "sources" / variant / path
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(content)
            paths[variant][path] = destination
            sources[f"{variant}/{path}"] = sha(content)
    heap_path = output / "sources" / "candidate" / HEAP
    heap_path.parent.mkdir(parents=True, exist_ok=True)
    heap_path.write_bytes((ROOT / HEAP).read_bytes())
    paths["candidate"][HEAP] = heap_path
    sources[f"candidate/{HEAP}"] = sha(heap_path.read_bytes())
    for name in ["Harness.swift", "run.py"]:
        (output / "driver" / name).write_bytes((HERE / name).read_bytes())
        sources[f"driver/{name}"] = sha((output / "driver" / name).read_bytes())
    write_json(output / "sources.json", sources)

    swiftc = args.swiftc.resolve() if args.swiftc else Path(run(["xcrun", "--find", "swiftc"]).decode().strip())
    sdk = run(["xcrun", "--sdk", "macosx", "--show-sdk-path"]).decode().strip()
    host = dict(baseline=BASELINE, candidateCommit=run(["git", "rev-parse", "HEAD"]).decode().strip(),
                workingTree=run(["git", "status", "--porcelain"]).decode(),
                platform=platform.platform(), machine=platform.machine(), python=platform.python_version(),
                compiler=run([swiftc, "--version"]).decode(), sdk=sdk,
                xcode=run(["xcodebuild", "-version"]).decode(),
                hardware=run(["sysctl", "hw.model", "hw.ncpu", "hw.memsize", "machdep.cpu.brand_string"]).decode(),
                osVersion=run(["sw_vers"]).decode(), pairs=args.pairs,
                environment={"SWIFT_DETERMINISTIC_HASHING": "1",
                             "DEVELOPER_DIR": environment.get("DEVELOPER_DIR"),
                             "LANG": environment.get("LANG"), "LC_ALL": environment.get("LC_ALL")})
    write_json(output / "environment.json", host)
    flags = ["-O", "-whole-module-optimization", "-swift-version", "6", "-parse-as-library",
             "-sdk", sdk, "-target", f"{platform.machine()}-apple-macos26.0",
             "-module-cache-path", output / "module-cache"]
    core_dir = output / "build" / "core"
    core_dir.mkdir()
    print("Compiling shared core and two exact-source native disk-cache executables", flush=True)
    run([swiftc, *flags, "-emit-library", "-emit-module", "-module-name", "IlliquidCore",
         "-emit-module-path", core_dir / "IlliquidCore.swiftmodule",
         *[paths["baseline"][path] for path in CORE], "-o", core_dir / "libIlliquidCore.dylib"])
    binaries = {}
    for variant in ["baseline", "candidate"]:
        binary = output / "build" / variant
        native_paths = [paths[variant][path] for path in NATIVE]
        if variant == "candidate":
            native_paths.append(heap_path)
        run([swiftc, *flags, "-I", core_dir, "-L", core_dir, "-lIlliquidCore",
             "-Xlinker", "-rpath", "-Xlinker", core_dir,
             *native_paths, output / "driver" / "Harness.swift", "-o", binary])
        binaries[variant] = binary
    binary_hashes = {variant: sha(path.read_bytes()) for variant, path in binaries.items()}
    binary_hashes["sharedCore"] = sha((core_dir / "libIlliquidCore.dylib").read_bytes())
    write_json(output / "binaries.json", binary_hashes)
    jpeg = output / "fixture.jpg"
    fixture = json.loads(run([binaries["baseline"], "prepare", jpeg]))
    if sha(jpeg.read_bytes()) != fixture["jpegSHA256"] or len(jpeg.read_bytes()) != 4096:
        raise RuntimeError("Prepared JPEG does not match its receipt.")
    write_json(output / "fixture.json", fixture)
    cases = workloads()
    names = [case["name"] for case in cases]
    if len(names) != 9 or len(set(names)) != 9:
        raise RuntimeError("Declared workload cohort is incomplete or duplicated.")
    for case in cases:
        write_json(output / "cases" / (case["name"] + ".json"), case)
    write_json(output / "workloads.json", cases)
    operation_number = 0

    def observe(case, variant, receipt=False):
        nonlocal operation_number
        fixture_dir = output / "fixtures" / f"{operation_number:04d}"
        operation_number += 1
        receipt_path = output / "receipts" / (case["name"] + ".json") if receipt else "-"
        row = json.loads(run([binaries[variant], output / "cases" / (case["name"] + ".json"),
                              jpeg, fixture_dir, receipt_path]))
        expected_ops = 32 if case["targetMiB"] is None else 1
        if (row["name"] != case["name"] or row["operations"] != expected_ops
                or row["operation"] != ("insert" if case["targetMiB"] is None else "configure")
                or row["evictions"] != case["expectedEvictions"]
                or row["bytePressure"] != case["expectedBytePressure"]
                or row["countPressure"] != case["expectedCountPressure"]
                or row["actualSHA256"] != row["expectedSHA256"]
                or row["oracleCheckedEveryFilenameAndSize"] is not True
                or row["wallNS"] <= 0 or row["cpuNS"] <= 0):
            raise RuntimeError(f"Incomplete or invalid measurement for {case['name']}: {row}")
        row.update(variant=variant, commandIndex=commands[-1]["index"], binarySHA256=binary_hashes[variant])
        return row

    def identity(row):
        return {key: value for key, value in row.items() if key not in
                ["wallNS", "cpuNS", "variant", "commandIndex", "binarySHA256", "pair", "ordinal"]}

    def verify_integrity():
        for name, digest in sources.items():
            path = output / name if name.startswith("driver/") else output / "sources" / name
            if sha(path.read_bytes()) != digest:
                raise RuntimeError(f"Staged source changed during qualification: {name}")
        for variant, path in binaries.items():
            if sha(path.read_bytes()) != binary_hashes[variant]:
                raise RuntimeError(f"Executable changed during qualification: {variant}")
        if sha((core_dir / "libIlliquidCore.dylib").read_bytes()) != binary_hashes["sharedCore"]:
            raise RuntimeError("Shared production core changed during qualification.")
        if sha(jpeg.read_bytes()) != fixture["jpegSHA256"]:
            raise RuntimeError("Fixed JPEG changed during qualification.")
        write_json(output / "integrity.json", dict(stagedSourcesUnchanged=True,
                   executablesUnchanged=True, sharedCoreUnchanged=True, fixtureUnchanged=True))

    print("Verifying all nine workloads against the independent full-survivor oracle", flush=True)
    verification = []
    expected_receipts = {}
    for case in cases:
        before = observe(case, "baseline", receipt=True)
        after = observe(case, "candidate")
        if identity(before) != identity(after):
            raise RuntimeError(f"Baseline/candidate preflight differs: {case['name']}")
        expected_receipts[case["name"]] = identity(before)
        verification.extend([before, after])
        write_json(output / "verification.json", verification)
        print(f"  verified {case['name']}: {before['evictions']} evictions", flush=True)
    if {row["name"] for row in verification} != set(names) or len(verification) != 18:
        raise RuntimeError("Verification did not cover the full declared cohort.")
    if args.verify_only:
        verify_integrity()
        print("Native verification passed for both implementations and all nine workloads.", flush=True)
        return

    rows, schedule = [], []
    for pair in range(args.pairs):
        order = ["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]
        rotated = cases[pair % len(cases):] + cases[:pair % len(cases)]
        for case in rotated:
            for variant in order:
                schedule.append((pair, case["name"], variant))
    write_json(output / "schedule.json", schedule)
    for pair, name, variant in schedule:
        case = next(case for case in cases if case["name"] == name)
        row = observe(case, variant)
        if identity(row) != expected_receipts[name]:
            raise RuntimeError(f"Timed output differs from preflight: {pair}/{name}/{variant}")
        row.update(pair=pair, ordinal=len(rows))
        rows.append(row)
        append_json(output / "observations.jsonl", row)
        if len(rows) % 2 == 0:
            print(f"  pair {pair + 1}/{args.pairs}: {name}", flush=True)
    persisted = [json.loads(line) for line in (output / "observations.jsonl").read_text().splitlines()]
    if persisted != rows or [(r["pair"], r["name"], r["variant"]) for r in persisted] != schedule:
        raise RuntimeError("Persisted observations are missing, reordered, or changed.")
    if len(rows) != len(names) * args.pairs * 2:
        raise RuntimeError("Measurement cohort is incomplete.")
    verify_integrity()
    summary = []
    for case in cases:
        subset = [row for row in rows if row["name"] == case["name"]]
        result = dict(name=case["name"], operation=subset[0]["operation"],
                      operationsPerObservation=subset[0]["operations"], pairs=args.pairs)
        for metric in ["wallNS", "cpuNS"]:
            by_variant = {}
            for variant in ["baseline", "candidate"]:
                values = [row[metric] / row["operations"] for row in subset if row["variant"] == variant]
                by_variant[variant] = dict(median=statistics.median(values), min=min(values), max=max(values))
            ratios = []
            for pair in range(args.pairs):
                a = next(row for row in subset if row["pair"] == pair and row["variant"] == "baseline")
                b = next(row for row in subset if row["pair"] == pair and row["variant"] == "candidate")
                ratios.append(b[metric] / a[metric])
            by_variant.update(pairedCandidateOverBaseline=ratios,
                              medianPairedReductionPercent=statistics.median([(1 - value) * 100 for value in ratios]),
                              improvedPairs=sum(value < 1 for value in ratios))
            result[metric] = by_variant
        summary.append(result)
    write_json(output / "summary.json", dict(observations=len(rows), cases=summary))
    write_json(output / "validation.json", dict(verificationObservations=18, timedObservations=len(rows),
               declaredCases=names, fullOraclePassed=True, matchedPreflight=True,
               exactPersistedSchedule=True, sourceHashes=sources, binaryHashes=binary_hashes))
    print("\nNative cache results (per operation):", flush=True)
    for case in summary:
        wall = case["wallNS"]
        print(f"{case['name']}: {wall['baseline']['median'] / 1e6:.3f} -> "
              f"{wall['candidate']['median'] / 1e6:.3f} ms; "
              f"paired reduction {wall['medianPairedReductionPercent']:.1f}% "
              f"({wall['improvedPairs']}/{args.pairs} pairs faster)", flush=True)


if __name__ == "__main__":
    main()
