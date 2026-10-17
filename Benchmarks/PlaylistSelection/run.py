#!/usr/bin/env python3
"""Compare exact playlist-selection sources; retain tests and every process receipt."""
import argparse
import datetime
import gzip
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import statistics
import subprocess
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BASELINE_COMMIT = "68274d1b09dcc866296321a5a8858efc297c4f19"
SOURCES = {
    "PlaylistMutation.swift": "Sources/IlliquidCore/Playlist/PlaylistMutation.swift",
    "FolderPlaylist.swift": "Sources/IlliquidCore/Playlist/FolderPlaylist.swift",
    "NaturalFilenameOrdering.swift": "Sources/IlliquidCore/Utilities/NaturalFilenameOrdering.swift",
    "NormalizedFileURL.swift": "Sources/IlliquidCore/Utilities/NormalizedFileURL.swift",
}
TESTS = [
    "PlaylistMutationTests.swift", "PlaylistSelectionIdentityTests.swift",
    "PlaylistOrderRestorationTests.swift", "FolderPlaylistTests.swift",
    "TestSupport/TemporaryDirectory.swift",
]
WORKLOADS = ("head", "middle", "tail", "missing", "invalid-current", "nil-current",
             "tail-unicode", "missing-unicode", "all-invalid-items")


def sha(data):
    return hashlib.sha256(data).hexdigest()


def fingerprint(path):
    data = path.read_bytes()
    return {"sha256": sha(data), "git_blob": hashlib.sha1(
        b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()}


def write_json(path, value):
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)
    if json.loads(path.read_text()) != value:
        raise RuntimeError(f"JSON read-back mismatch: {path}")


def append_json(path, value):
    with path.open("a", encoding="utf-8") as stream:
        stream.write(json.dumps(value, sort_keys=True) + "\n")
        stream.flush()
        os.fsync(stream.fileno())


def read_rows(path):
    return [json.loads(line) for line in path.read_text().splitlines()]


class Recorder:
    def __init__(self, output):
        self.output, self.commands = output, []
        (output / "commands").mkdir()
        self.environment = dict(os.environ)
        self.environment["CLANG_MODULE_CACHE_PATH"] = str(output / "module-cache")
        self.environment["SWIFTPM_MODULECACHE_OVERRIDE"] = str(output / "module-cache")

    def run(self, arguments, cwd=None):
        arguments = list(map(str, arguments))
        identifier = len(self.commands)
        started = datetime.datetime.now(datetime.timezone.utc).isoformat()
        clock = time.perf_counter_ns()
        completed = subprocess.run(arguments, cwd=cwd, env=self.environment,
                                   capture_output=True, check=False)
        record = {"id": identifier, "argv": arguments, "cwd": str(cwd or ROOT),
                  "startedUTC": started, "elapsedNanoseconds": time.perf_counter_ns() - clock,
                  "returncode": completed.returncode}
        for name, data in (("stdout", completed.stdout), ("stderr", completed.stderr)):
            relative = f"commands/{identifier:04d}.{name}.gz"
            (self.output / relative).write_bytes(gzip.compress(data, mtime=0))
            record[name] = {"path": relative, "sha256": sha(data), "bytes": len(data)}
        append_json(self.output / "commands.jsonl", record)
        self.commands.append(record)
        if completed.returncode:
            raise RuntimeError(f"Command {identifier} failed ({completed.returncode}): "
                               f"{' '.join(arguments)}\n{completed.stderr.decode(errors='replace')[-4000:]}")
        return completed.stdout, identifier

    def audit(self):
        if read_rows(self.output / "commands.jsonl") != self.commands:
            raise RuntimeError("Persisted command log differs from completed commands")
        for record in self.commands:
            for name in ("stdout", "stderr"):
                receipt = record[name]
                data = gzip.decompress((self.output / receipt["path"]).read_bytes())
                if sha(data) != receipt["sha256"] or len(data) != receipt["bytes"]:
                    raise RuntimeError(f"Damaged command receipt: {receipt['path']}")


def snapshot(output):
    manifest_path = HERE / "baseline/manifest.json"
    manifest = json.loads(manifest_path.read_text())
    entries = manifest.get("files", manifest.get("entries", []))
    if manifest.get("baseline_commit") != BASELINE_COMMIT or len(entries) != len(SOURCES):
        raise RuntimeError("Frozen baseline manifest has an unexpected commit or file count")
    mapping = {entry["file"]: entry for entry in entries}
    if set(mapping) != set(SOURCES):
        raise RuntimeError("Frozen baseline must describe exactly the four production files")
    for name, original in SOURCES.items():
        entry = mapping[name]
        if entry["path"] != original or any(
                fingerprint(HERE / "baseline" / name)[key] != entry[key]
                for key in ("sha256", "git_blob")):
            raise RuntimeError(f"Frozen baseline provenance mismatch: {name}")
    tracked = {}
    for variant in ("baseline", "candidate"):
        destination = output / "sources" / variant
        destination.mkdir(parents=True)
        for name, original in SOURCES.items():
            source = HERE / "baseline" / name if variant == "baseline" else ROOT / original
            shutil.copyfile(source, destination / name)
    for source, relative in [(HERE / "Harness.swift", "sources/Harness.swift"),
                             (Path(__file__), "sources/run.py"),
                             (manifest_path, "sources/baseline-manifest.json")]:
        shutil.copyfile(source, output / relative)
    for name in TESTS:
        target = output / "sources/tests" / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / "Tests/IlliquidCoreTests" / name, target)
    for path in sorted((output / "sources").rglob("*")):
        if path.is_file():
            tracked[str(path.relative_to(output))] = fingerprint(path)
    return tracked


def test_variant(variant, output, swift, recorder):
    package = output / "tests" / variant
    package.mkdir(parents=True)
    shutil.copytree(output / "sources" / variant, package / "Sources/IlliquidCore")
    shutil.copytree(output / "sources/tests", package / "Tests/IlliquidCoreTests")
    (package / "Package.swift").write_text('''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "PlaylistSelectionQualification",
    platforms: [.macOS("26.0")],
    targets: [.target(name: "IlliquidCore"),
              .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"])])
''')
    return {configuration: recorder.run([
        swift, "test", "--package-path", package, "--jobs", "2", "--no-parallel",
        "-c", configuration, "-Xswiftc", "-warnings-as-errors"], cwd=package)[1]
        for configuration in ("debug", "release")}


def build_variant(variant, output, swiftc, platform_flags, recorder):
    build = output / "build" / variant
    build.mkdir(parents=True)
    library = build / ("libIlliquidCore.dylib" if platform.system() == "Darwin" else "libIlliquidCore.so")
    common = [swiftc, "-O", "-whole-module-optimization", "-swift-version", "6",
              "-warnings-as-errors", "-module-cache-path", output / "module-cache",
              *platform_flags]
    recorder.run([*common, "-enable-testing", "-emit-module", "-emit-library",
                  "-module-name", "IlliquidCore", "-emit-module-path", build / "IlliquidCore.swiftmodule",
                  *[output / "sources" / variant / name for name in SOURCES], "-o", library], cwd=ROOT)
    executable = build / "playlist-selection"
    recorder.run([*common, "-parse-as-library", "-I", build, "-L", build, "-lIlliquidCore",
                  "-Xlinker", "-rpath", "-Xlinker", build,
                  output / "sources/Harness.swift", "-o", executable], cwd=ROOT)
    return executable, {"library": fingerprint(library), "driver": fingerprint(executable)}


def iterations_for(workload, size):
    scans = size // 2 + 1 if workload == "middle" else size
    if workload in ("head", "nil-current", "empty"):
        scans = 1
    return max(1, 10000 // max(1, scans))


def summarize(rows, cases, samples):
    summaries = []
    for workload, size in cases:
        selected = [row for row in rows if (row["workload"], row["size"]) == (workload, size)]
        result = {"workload": workload, "size": size, "pairs": samples}
        for variant in ("baseline", "candidate"):
            values = [r["nanosecondsPerOperation"] for r in selected if r["variant"] == variant]
            result[variant] = {"median": statistics.median(values), "min": min(values), "max": max(values)}
        paired = [{r["variant"]: r["nanosecondsPerOperation"] for r in selected if r["sample"] == sample}
                  for sample in range(samples)]
        result["medianPairedSpeedup"] = statistics.median(p["baseline"] / p["candidate"] for p in paired)
        result["medianPairedTimeReductionPercent"] = statistics.median(
            100 * (1 - p["candidate"] / p["baseline"]) for p in paired)
        result["ratioOfMedians"] = result["baseline"]["median"] / result["candidate"]["median"]
        summaries.append(result)
    return {"unit": "nanoseconds per selection", "observations": len(rows), "cases": summaries}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--swift", default="swift")
    parser.add_argument("--swiftc", default="swiftc")
    parser.add_argument("--samples", type=int, default=8)
    parser.add_argument("--sizes", nargs="+", type=int, default=[1, 100, 1000, 10000])
    parser.add_argument("--tests-only", action="store_true")
    args = parser.parse_args()
    if args.samples < 2 or args.samples % 2 or any(size < 1 for size in args.sizes) or len(set(args.sizes)) != len(args.sizes):
        parser.error("Use an even sample count >= 2 and distinct positive sizes")
    swift, swiftc = shutil.which(args.swift), shutil.which(args.swiftc)
    if not swift or not swiftc:
        parser.error("Both Swift executables must be available")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    recorder = Recorder(output)
    sources = snapshot(output)
    versions = {name: recorder.run([executable, "--version"], cwd=ROOT)[0].decode()
                for name, executable in (("swift", swift), ("swiftc", swiftc))}
    cases = [(workload, size) for workload in WORKLOADS for size in args.sizes] + [("empty", 0)]
    metadata = {"baseline_commit": BASELINE_COMMIT, "platform": platform.platform(),
                "machine": platform.machine(), "python": platform.python_version(), "toolchains": versions,
                "swift": swift, "swiftc": swiftc, "sources": sources,
                "compilerExecutables": {name: fingerprint(Path(executable).resolve())
                                        for name, executable in (("swift", swift), ("swiftc", swiftc))},
                "environment": {key: recorder.environment.get(key) for key in (
                    "LANG", "LC_ALL", "TZ", "SDKROOT", "SWIFT_EXEC", "DEVELOPER_DIR",
                    "LD_LIBRARY_PATH", "CLANG_MODULE_CACHE_PATH", "SWIFTPM_MODULECACHE_OVERRIDE")},
                "samples": args.samples, "sizes": args.sizes, "testsOnly": args.tests_only,
                "cases": [{"workload": workload, "size": size, "iterations": iterations_for(workload, size)}
                          for workload, size in cases]}
    write_json(output / "manifest.json", metadata)
    tests = {variant: test_variant(variant, output, swift, recorder) for variant in ("baseline", "candidate")}
    write_json(output / "tests.json", tests)
    if not args.tests_only:
        flags = []
        if platform.system() == "Darwin":
            sdk = recorder.run(["xcrun", "--sdk", "macosx", "--show-sdk-path"], cwd=ROOT)[0].decode().strip()
            flags = ["-sdk", sdk, "-target", f"{platform.machine()}-apple-macosx26.0"]
        binaries, metadata["binaries"] = {}, {}
        for variant in ("baseline", "candidate"):
            binaries[variant], metadata["binaries"][variant] = build_variant(variant, output, swiftc, flags, recorder)
        receipts = {}
        for variant in binaries:
            receipts[variant], _ = recorder.run([binaries[variant], "verify"], cwd=ROOT)
            (output / f"verification-{variant}.jsonl.gz").write_bytes(gzip.compress(receipts[variant], mtime=0))
        if not receipts["baseline"] or receipts["baseline"] != receipts["candidate"]:
            raise RuntimeError("Complete baseline/candidate verification receipts differ or are empty")
        metadata["verification"] = {"sha256": sha(receipts["baseline"]), "lines": len(receipts["baseline"].splitlines())}
        rows = []
        for workload, size in cases:
            print(f"Measuring {workload}, {size} items", flush=True)
            for sample in range(args.samples):
                pair = []
                order = ("baseline", "candidate") if sample % 2 == 0 else ("candidate", "baseline")
                for position, variant in enumerate(order):
                    iterations = iterations_for(workload, size)
                    raw, command = recorder.run([binaries[variant], "benchmark", workload, size, iterations], cwd=ROOT)
                    result = json.loads(raw)
                    if any(result.get(key) != value for key, value in (("workload", workload), ("size", size), ("iterations", iterations))) or any(
                            type(result.get(key)) is not int or result[key] <= 0 for key in ("operations", "wallNanoseconds")) or "checksum" not in result:
                        raise RuntimeError(f"Malformed benchmark result in command {command}")
                    row = {**result, "variant": variant, "sample": sample, "position": position, "command": command,
                           "nanosecondsPerOperation": result["wallNanoseconds"] / result["operations"]}
                    append_json(output / "measurements.jsonl", row)
                    rows.append(row)
                    pair.append(row)
                if any(pair[0][key] != pair[1][key] for key in ("iterations", "operations", "checksum")):
                    raise RuntimeError(f"Benchmark pair output mismatch: {workload}/{size}/{sample}")
        saved = read_rows(output / "measurements.jsonl")
        if saved != rows or len(saved) != len(cases) * args.samples * 2:
            raise RuntimeError("Persisted measurements are incomplete or differ from completed results")
        summary = summarize(saved, cases, args.samples)
    for relative, expected in sources.items():
        if fingerprint(output / relative) != expected:
            raise RuntimeError(f"Measured source snapshot changed: {relative}")
    recorder.audit()
    write_json(output / "manifest.json", metadata)
    if not args.tests_only:
        write_json(output / "summary.json", summary)
    write_json(output / "completed.json", {"commands": len(recorder.commands), "testsPassed": True,
                                          "observations": 0 if args.tests_only else len(rows)})
    print(f"Completed; evidence in {output}", flush=True)


if __name__ == "__main__":
    main()
