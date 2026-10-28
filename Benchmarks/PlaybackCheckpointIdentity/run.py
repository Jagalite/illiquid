#!/usr/bin/env python3
"""Compare complete production checkpoint construction with a frozen baseline."""
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
PLAYER_PATH = "Sources/IlliquidPlayer/Player/PlaybackCheckpointWriter.swift"
TEST_PATH = "Tests/IlliquidPlayerTests/PlaybackCheckpointTests.swift"
PROBE_PATH = "Benchmarks/ThumbnailReadAllocation/allocmeter.c"
RECORD_BOUNDARY = b"/// A versioned, atomic Application Support document"


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def git_blob(data):
    return hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()


def save(path, value):
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


class Run:
    def __init__(self, output):
        self.output = output
        self.logs = output / "logs"
        self.logs.mkdir()
        self.work = output / ".work"
        self.work.mkdir()
        self.sources = output / "sources"
        self.sources.mkdir()
        self.number = 0

    def command(self, args, label, env_updates=None):
        self.number += 1
        args = [str(value) for value in args]
        log = self.logs / f"{self.number:04d}-{label}.log"
        env = os.environ.copy()
        if env_updates:
            env.update(env_updates)
        start = time.monotonic()
        result = subprocess.run(args, cwd=ROOT, env=env, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=1200)
        log.write_bytes(result.stdout)
        with (self.output / "commands.jsonl").open("a") as stream:
            stream.write(json.dumps(dict(command=self.number, args=args,
                cwd=str(ROOT), environment_overrides=env_updates or {},
                elapsed_seconds=time.monotonic() - start, returncode=result.returncode,
                log=str(log.relative_to(self.output)))) + "\n")
        if result.returncode:
            raise RuntimeError(f"{label} failed ({result.returncode}); see {log}")
        return result.stdout.decode().strip()


def stage(run, manifest):
    frozen = json.loads((HERE / "baseline/manifest.json").read_text())
    manifest["baseline"] = frozen
    manifest["sources"] = {}
    common = run.sources / "shared"
    common.mkdir()
    for path, expected in frozen["shared_dependencies"].items():
        raw = (ROOT / path).read_bytes()
        if sha256(raw) != expected["sha256"] or git_blob(raw) != expected["git_blob"]:
            raise RuntimeError(f"Shared production dependency changed from pinned baseline: {path}")
        data = raw
        if path.endswith("PlaybackSessionStore.swift"):
            if data.count(RECORD_BOUNDARY) != 1:
                raise RuntimeError("Session record/protocol extraction boundary changed")
            # Exact production record and protocol; exclude only the unrelated
            # AtomicPlaybackSessionStore and its macOS lifecycle dependency.
            data = data.split(RECORD_BOUNDARY)[0]
        (common / Path(path).name).write_bytes(data)
        manifest["sources"][path] = dict(full_sha256=sha256(raw), staged_sha256=sha256(data))
    baseline = (HERE / "baseline/PlaybackCheckpointWriter.swift").read_bytes()
    if sha256(baseline) != frozen["checkpoint"]["sha256"] or git_blob(baseline) != frozen["checkpoint"]["git_blob"]:
        raise RuntimeError("Frozen checkpoint source does not match its pinned hashes")
    for variant, data in [("baseline", baseline), ("candidate", (ROOT / PLAYER_PATH).read_bytes())]:
        directory = run.work / variant
        directory.mkdir()
        (directory / "PlaybackCheckpointWriter.swift").write_bytes(data)
        snapshot = run.sources / variant
        snapshot.mkdir()
        (snapshot / "PlaybackCheckpointWriter.swift").write_bytes(data)
        manifest[variant + "_checkpoint_sha256"] = sha256(data)
    for path in [HERE / "Driver.swift", HERE / "run.py", ROOT / TEST_PATH, ROOT / PROBE_PATH]:
        data = path.read_bytes()
        manifest["sources"][str(path.relative_to(ROOT))] = dict(sha256=sha256(data))
        (run.sources / path.name).write_bytes(data)
    return common


def tests(run, common, swift, manifest):
    receipts = []
    for variant in ["baseline", "candidate"]:
        package = run.work / (variant + "-tests")
        core = package / "Sources/IlliquidCore"
        player = package / "Sources/IlliquidPlayer"
        test = package / "Tests/IlliquidPlayerTests"
        for directory in [core, player, test]:
            directory.mkdir(parents=True)
        for path in common.glob("*.swift"):
            shutil.copyfile(path, core / path.name)
        shutil.copyfile(run.work / variant / "PlaybackCheckpointWriter.swift", player / "PlaybackCheckpointWriter.swift")
        shutil.copyfile(run.sources / "PlaybackCheckpointTests.swift", test / "PlaybackCheckpointTests.swift")
        (package / "Package.swift").write_text('''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "CheckpointIdentityQualification", platforms: [.macOS("26.0")], targets: [
    .target(name: "IlliquidCore"),
    .target(name: "IlliquidPlayer", dependencies: ["IlliquidCore"]),
    .testTarget(name: "IlliquidPlayerTests", dependencies: ["IlliquidCore", "IlliquidPlayer"]),
])
''')
        for configuration in ["debug", "release"]:
            run.command([swift, "test", "--package-path", package, "--jobs", "2",
                         "--no-parallel", "-c", configuration], f"tests-{variant}-{configuration}")
            receipts.append(dict(variant=variant, configuration=configuration, passed=True))
            save(run.output / "tests.json", receipts)
        # Keep logs/receipts, not duplicate test build caches in research output.
        shutil.rmtree(package / ".build")
    manifest["test_runs"] = receipts


def build(run, common, swiftc, manifest):
    shared = run.work / "build-shared"
    shared.mkdir()
    flags = ["-O", "-whole-module-optimization", "-swift-version", "6", "-enable-testing",
             "-module-cache-path", run.work / "module-cache"]
    extension = ".so"
    if sys.platform == "darwin":
        extension = ".dylib"
        sdk = run.command(["xcrun", "--sdk", "macosx", "--show-sdk-path"], "sdk")
        flags += ["-sdk", sdk, "-target", f"{platform.machine()}-apple-macosx26.0"]
    core = shared / ("libIlliquidCore" + extension)
    run.command([swiftc, *flags, "-emit-library", "-emit-module", "-module-name", "IlliquidCore",
                 "-emit-module-path", shared / "IlliquidCore.swiftmodule",
                 *sorted(common.glob("*.swift")), "-o", core], "build-core")
    manifest["core_library_sha256"] = sha256(core.read_bytes())
    binaries = {}
    for variant in ["baseline", "candidate"]:
        directory = run.work / variant
        library = directory / ("libIlliquidPlayer" + extension)
        links = ["-I", shared, "-L", shared, "-lIlliquidCore",
                 "-Xlinker", "-rpath", "-Xlinker", shared]
        run.command([swiftc, *flags, *links, "-emit-library", "-emit-module", "-module-name", "IlliquidPlayer",
                     "-emit-module-path", directory / "IlliquidPlayer.swiftmodule",
                     directory / "PlaybackCheckpointWriter.swift", "-o", library], f"build-{variant}-player")
        binary = directory / "driver"
        run.command([swiftc, *flags, *links, "-parse-as-library", "-I", directory, "-L", directory,
                     "-lIlliquidPlayer", "-Xlinker", "-rpath", "-Xlinker", directory,
                     run.sources / "Driver.swift", "-o", binary], f"build-{variant}-driver")
        binaries[variant] = binary
        manifest[variant + "_library_sha256"] = sha256(library.read_bytes())
        manifest[variant + "_binary_sha256"] = sha256(binary.read_bytes())
    return binaries


def cases(quick):
    result = []
    for size in ([0, 10, 1000] if quick else [0, 1, 10, 1000, 10000]):
        scenarios = ["nil-folder", "missing", "remote"] if size == 0 else [
            "nil-folder", "first-hit", "middle-hit", "late-hit", "missing", "remote"]
        result.extend(dict(count=size, scenario=scenario) for scenario in scenarios)
    return result


def observe(run, binary, case, iterations, mode, label, env=None):
    row = json.loads(run.command([binary, case["count"], case["scenario"], iterations, mode], label, env))
    if not row["complete_record_parity"] or row["iterations"] != iterations or row["mode"] != mode:
        raise RuntimeError("Driver did not complete the requested observation")
    if row["count"] != case["count"] or row["scenario"] != case["scenario"] or not math.isfinite(row["seconds"]) or row["seconds"] <= 0:
        raise RuntimeError("Invalid observation receipt")
    return row


def matching(left, right):
    for field in ["checksum", "canonical_record_fnv1a64", "canonical_record_bytes", "iterations", "count", "scenario"]:
        if left[field] != right[field]:
            raise RuntimeError(f"Baseline/candidate parity failed: {field}")


def measurements(run, binaries, workloads, args):
    rows = []
    calibrations = []
    for case in workloads:
        controls = {variant: observe(run, binary, case, 1, "timing", f"calibrate-{variant}")
                    for variant, binary in binaries.items()}
        matching(controls["baseline"], controls["candidate"])
        fastest = min(row["seconds"] for row in controls.values())
        iterations = max(1, min(100000, math.ceil(args.target_ms / 1000 / fastest)))
        calibrations.append(dict(**case, iterations=iterations, observations=controls))
        save(run.output / "calibration.json", calibrations)
        for pair in range(args.pairs):
            order = ["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]
            paired = {}
            for variant in order:
                row = observe(run, binaries[variant], case, iterations, "timing", f"timing-{variant}")
                if row["canonical_record_fnv1a64"] != controls["baseline"]["canonical_record_fnv1a64"]:
                    raise RuntimeError("Record changed between calibration and measurement")
                row.update(variant=variant, pair=pair)
                paired[variant] = row
                rows.append(row)
                with (run.output / "observations.jsonl").open("a") as stream:
                    stream.write(json.dumps(row, sort_keys=True) + "\n")
            matching(paired["baseline"], paired["candidate"])
        summary = summarize(rows, workloads, "seconds", "elapsed_ms", scale=1000)
        save(run.output / "summary.json", summary)
        print(json.dumps(summary[-1]), flush=True)
    recorded = [json.loads(line) for line in (run.output / "observations.jsonl").read_text().splitlines()]
    if recorded != rows:
        raise RuntimeError("Persisted observations differ from completed observations")
    return rows


def summarize(rows, workloads, field, label, scale=1):
    result = []
    for case in workloads:
        selected = [row for row in rows if row["count"] == case["count"] and row["scenario"] == case["scenario"]]
        if not selected:
            continue
        by_variant = {variant: [row[field] / row["iterations"] * scale for row in selected
                               if row["variant"] == variant] for variant in ["baseline", "candidate"]}
        changes = []
        for pair in sorted(set(row["pair"] for row in selected)):
            values = {row["variant"]: row[field] / row["iterations"] for row in selected if row["pair"] == pair}
            if values["baseline"]:
                changes.append((values["baseline"] - values["candidate"]) / values["baseline"] * 100)
        result.append(dict(**case, metric=label, pairs=len(by_variant["baseline"]),
            baseline_median=statistics.median(by_variant["baseline"]),
            candidate_median=statistics.median(by_variant["candidate"]),
            baseline_range=[min(by_variant["baseline"]), max(by_variant["baseline"])],
            candidate_range=[min(by_variant["candidate"]), max(by_variant["candidate"])],
            paired_reduction_percent=statistics.median(changes) if changes else None,
            paired_reduction_range=[min(changes), max(changes)] if changes else None))
    return result


def allocations(run, binaries, workloads, args, manifest):
    if sys.platform != "linux" or platform.libc_ver()[0] != "glibc":
        save(run.output / "allocations.json", dict(status="unavailable", reason="Linux/glibc-only allocation request probe"))
        return []
    probe = run.work / "allocmeter.so"
    run.command(["cc", "-shared", "-fPIC", "-O2", run.sources / "allocmeter.c", "-o", probe], "build-allocation-probe")
    manifest["allocation_probe_binary_sha256"] = sha256(probe.read_bytes())
    controls = {(entry["count"], entry["scenario"]): entry["observations"]
                for entry in json.loads((run.output / "calibration.json").read_text())}
    rows = []
    for case in workloads:
        for pair in range(args.pairs):
            paired = {}
            for variant in (["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]):
                row = observe(run, binaries[variant], case, 1, "allocations", f"allocations-{variant}",
                              {"LD_PRELOAD": str(probe)})
                for field in ["allocation_requests", "allocation_requested_bytes"]:
                    if not isinstance(row.get(field), int) or row[field] < 0:
                        raise RuntimeError(f"Missing or invalid allocation metric: {field}")
                matching(row, controls[(case["count"], case["scenario"])][variant])
                row.update(variant=variant, pair=pair)
                paired[variant] = row
                rows.append(row)
                with (run.output / "allocation-observations.jsonl").open("a") as stream:
                    stream.write(json.dumps(row, sort_keys=True) + "\n")
            matching(paired["baseline"], paired["candidate"])
    save(run.output / "allocations.json", dict(status="measured", scope="successful malloc/calloc/realloc requests; not live memory or RSS",
        requests=summarize(rows, workloads, "allocation_requests", "requests_per_record"),
        requested_bytes=summarize(rows, workloads, "allocation_requested_bytes", "requested_bytes_per_record")))
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--swift", default=shutil.which("swift"))
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--target-ms", type=float, default=40)
    parser.add_argument("--tests-only", action="store_true")
    parser.add_argument("--skip-tests", action="store_true")
    parser.add_argument("--quick", action="store_true")
    args = parser.parse_args()
    if not args.swift or args.pairs < 1 or not math.isfinite(args.target_ms) or args.target_ms <= 0:
        parser.error("A Swift toolchain, positive --pairs and positive --target-ms are required")
    if args.tests_only and args.skip_tests:
        parser.error("--tests-only and --skip-tests are mutually exclusive")
    args.output = args.output.resolve()
    if args.output.exists() and any(args.output.iterdir()):
        parser.error("--output must be new or empty; prior evidence is never overwritten")
    args.output.mkdir(parents=True, exist_ok=True)
    run = Run(args.output)
    swift = Path(shutil.which(args.swift) or args.swift).absolute()
    swiftc = swift.with_name("swiftc")
    manifest = dict(platform=platform.platform(), machine=platform.machine(), python=sys.version,
                    swift=str(swift), pairs=args.pairs, target_ms=args.target_ms,
                    started_utc=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                    locale={key: os.environ.get(key) for key in ["LANG", "LC_ALL"]})
    try:
        manifest["compiler"] = run.command([swift, "--version"], "compiler")
        common = stage(run, manifest)
        save(args.output / "manifest.json", manifest)
        if not args.skip_tests:
            tests(run, common, swift, manifest)
        if args.tests_only:
            save(args.output / "manifest.json", manifest)
            save(args.output / "completion.json", dict(passed=True, tests_only=True))
            return
        binaries = build(run, common, swiftc, manifest)
        save(args.output / "manifest.json", manifest)
        workloads = cases(args.quick)
        save(args.output / "cases.json", workloads)
        rows = measurements(run, binaries, workloads, args)
        allocation_rows = allocations(run, binaries, workloads, args, manifest)
        save(args.output / "manifest.json", manifest)
        save(args.output / "completion.json", dict(passed=True, timing_observations=len(rows),
            allocation_observations=len(allocation_rows), expected_timing_observations=len(workloads) * args.pairs * 2))
    except Exception as error:
        save(args.output / "manifest.json", manifest)
        save(args.output / "completion.json", dict(passed=False, error=str(error)))
        raise


if __name__ == "__main__":
    main()
