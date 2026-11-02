#!/usr/bin/env python3
"""Qualify media-file classification and real folder discovery against a pinned baseline."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
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
NATIVE = sys.platform == "darwin"
VARIANTS = ("baseline", "candidate")
SOURCE_PATHS = (
    "Playlist/ExternalSubtitleMatcher.swift", "Playlist/FolderPlaylist.swift",
    "Playlist/FolderPlaylistDiscovery.swift", "Playlist/PlaylistMutation.swift",
    "Utilities/MediaFileSupport.swift", "Utilities/NaturalFilenameOrdering.swift",
    "Utilities/NormalizedFileURL.swift",
)
FOCAL = "MediaFileSupport.swift"
TEST_PATHS = (
    "MediaFileSupportTests.swift", "FolderPlaylistDiscoveryTests.swift",
    "FolderDiscoveryFilesystemRegressionTests.swift", "ExternalSubtitleMatcherTests.swift",
    "TestSupport/TemporaryDirectory.swift",
)
from fixtures import fixtures


def sha256(path: Path) -> str:
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def save(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + "\n")


class Commands:
    def __init__(self, out: Path):
        self.out = out
        self.evidence = out / "evidence"
        self.records: list[dict] = []
        self.environment = dict(os.environ)
        for key, leaf in (("CLANG_MODULE_CACHE_PATH", "clang"),
                          ("SWIFTPM_MODULECACHE_OVERRIDE", "swift"),
                          ("XDG_CACHE_HOME", "xdg"), ("TMPDIR", "tmp")):
            path = out / "cache" / leaf
            path.mkdir(parents=True, exist_ok=True)
            self.environment[key] = str(path)

    def run(self, argv, label: str, *, benchmark: bool = False,
            timeout: int = 300, quiet: bool = False) -> Path:
        argv = [str(arg) for arg in argv]
        stdout = self.evidence / "logs" / f"{label}.stdout.log"
        stderr = stdout.with_name(f"{label}.stderr.log")
        stdout.parent.mkdir(parents=True, exist_ok=True)
        environment = dict(self.environment)
        if benchmark:
            environment["SWIFT_DETERMINISTIC_HASHING"] = "1"
        started = time.monotonic()
        record = {"label": label, "argv": argv, "cwd": str(ROOT),
                  "deterministicHashing": benchmark}
        try:
            with stdout.open("wb") as out, stderr.open("wb") as err:
                result = subprocess.run(argv, cwd=ROOT, env=environment,
                                        stdout=out, stderr=err, timeout=timeout)
            record["returncode"] = result.returncode
        except subprocess.TimeoutExpired:
            record["returncode"] = "timeout"
        finally:
            record.update(elapsedSeconds=time.monotonic() - started,
                          stdout=str(stdout.relative_to(self.evidence)),
                          stderr=str(stderr.relative_to(self.evidence)),
                          stdoutSHA256=sha256(stdout), stderrSHA256=sha256(stderr))
            self.records.append(record)
            save(self.evidence / "commands.json", self.records)
        if not quiet:
            print(f"{label}: {record['returncode']} ({record['elapsedSeconds']:.2f}s)", flush=True)
        if record["returncode"] != 0:
            raise RuntimeError(f"{label} failed; see {stdout} and {stderr}\n"
                               f"{stderr.read_text(errors='replace')[-5000:]}")
        return stdout

    def json(self, argv, label: str, **kwargs):
        return json.loads(self.run(argv, label, **kwargs).read_text())


def toolchain(args, commands: Commands) -> dict:
    swiftc = args.swiftc or os.environ.get("SWIFTC")
    if NATIVE and swiftc is None:
        swiftc = commands.run(["xcrun", "--find", "swiftc"], "compiler-path").read_text().strip()
    swiftc = shutil.which(swiftc or "swiftc")
    if not swiftc:
        raise RuntimeError("swiftc is required; use --swiftc or SWIFTC")
    # Preserve the swiftc/swift symlink basename: it selects the driver's mode.
    swiftc = str(Path(swiftc).absolute())
    swift = args.swift or os.environ.get("SWIFT") or str(Path(swiftc).parent / "swift")
    swift = shutil.which(swift)
    if not swift:
        raise RuntimeError("Matching swift is required; use --swift or SWIFT")
    compiler = {"swiftc": swiftc, "swift": swift,
                "version": commands.run([swiftc, "--version"], "compiler-version").read_text().strip(),
                "swiftcSHA256": sha256(Path(swiftc).resolve()),
                "swiftSHA256": sha256(Path(swift).resolve())}
    frontend = Path(swiftc).parent / "swift-frontend"
    if frontend.exists():
        compiler["frontendSHA256"] = sha256(frontend.resolve())
    if NATIVE:
        compiler["sdk"] = commands.run(["xcrun", "--sdk", "macosx", "--show-sdk-path"], "sdk-path").read_text().strip()
        compiler["sdkVersion"] = commands.run(["xcrun", "--sdk", "macosx", "--show-sdk-version"], "sdk-version").read_text().strip()
        commands.run(["sw_vers"], "macos-version")
        commands.run(["sysctl", "-n", "machdep.cpu.brand_string"], "cpu")
    return compiler


def snapshot(out: Path) -> dict:
    pinned = json.loads((HERE / "baseline/manifest.json").read_text())
    baseline = HERE / "baseline" / FOCAL
    data = baseline.read_bytes()
    blob = hashlib.sha1(f"blob {len(data)}\0".encode() + data).hexdigest()
    if sha256(baseline) != pinned["sha256"] or blob != pinned["gitBlob"]:
        raise RuntimeError("Pinned baseline differs from its manifest")
    paths = {f"shared/{Path(name).name}": ROOT / "Sources/IlliquidCore" / name
             for name in SOURCE_PATHS if Path(name).name != FOCAL}
    paths.update({f"baseline/{FOCAL}": baseline,
                  f"candidate/{FOCAL}": ROOT / "Sources/IlliquidCore/Utilities" / FOCAL,
                  "baseline-manifest.json": HERE / "baseline/manifest.json"})
    paths.update({name: HERE / name for name in
                  ("ClassificationHarness.swift", "DiscoveryHarness.swift", "run.py", "fixtures.py")})
    paths.update({f"tests/{Path(name).name}": ROOT / "Tests/IlliquidCoreTests" / name
                  for name in TEST_PATHS})
    hashes = {}
    for name, source in paths.items():
        target = out / "evidence/inputs" / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
        hashes[name] = sha256(target)
    return {"baselineRevision": pinned["revision"], "inputSHA256": hashes,
            "sourcePaths": {name: str(path.relative_to(ROOT)) for name, path in paths.items()}}


def production_sources(out: Path, variant: str) -> list[Path]:
    inputs = out / "evidence/inputs"
    return [inputs / (variant if Path(name).name == FOCAL else "shared") / Path(name).name
            for name in SOURCE_PATHS]


def build(variant: str, out: Path, compiler: dict, commands: Commands) -> dict[str, Path]:
    folder = out / "build" / variant
    folder.mkdir(parents=True)
    library = folder / ("libIlliquidCore.dylib" if NATIVE else "libIlliquidCore.so")
    flags = ["-swift-version", "6", "-O", "-whole-module-optimization", "-warnings-as-errors",
             "-module-cache-path", str(out / "cache/modules")]
    if NATIVE:
        flags += ["-target", f"{platform.machine()}-apple-macosx26.0", "-sdk", compiler["sdk"]]
    commands.run([compiler["swiftc"], *flags, "-emit-library", "-emit-module", "-module-name", "IlliquidCore",
                  "-emit-module-path", folder / "IlliquidCore.swiftmodule", "-o", library,
                  *production_sources(out, variant)], f"build-{variant}-module")
    binaries = {}
    for mode, name in (("classification", "ClassificationHarness.swift"), ("discovery", "DiscoveryHarness.swift")):
        binary = folder / mode
        commands.run([compiler["swiftc"], *flags, "-parse-as-library", "-I", folder, "-L", folder,
                      "-lIlliquidCore", "-Xlinker", "-rpath", "-Xlinker", folder,
                      out / "evidence/inputs" / name, "-o", binary], f"build-{variant}-{mode}")
        binaries[mode] = binary
    save(out / f"evidence/build-{variant}.json", {
        "librarySHA256": sha256(library), "executableSHA256": {k: sha256(v) for k, v in binaries.items()},
        "swiftmoduleSHA256": sha256(folder / "IlliquidCore.swiftmodule")})
    return binaries


def test(variant: str, configuration: str, out: Path, compiler: dict, commands: Commands) -> None:
    folder = out / "tests" / variant
    sources = folder / "Sources/IlliquidCore"
    tests = folder / "Tests/IlliquidCoreTests"
    sources.mkdir(parents=True, exist_ok=True)
    tests.mkdir(parents=True, exist_ok=True)
    for source in production_sources(out, variant):
        shutil.copyfile(source, sources / source.name)
    for name in TEST_PATHS:
        shutil.copyfile(out / "evidence/inputs/tests" / Path(name).name, tests / Path(name).name)
    (folder / "Package.swift").write_text('''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "MediaFileClassificationQualification", platforms: [.macOS("26.0")], targets: [
    .target(name: "IlliquidCore"),
    .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"])
])
''')
    arguments = [compiler["swift"], "test", "--package-path", folder, "--configuration", configuration,
                 "--scratch-path", folder / "build", "--jobs", "2", "--cache-path", out / "cache/packages",
                 "--config-path", out / "cache/config", "--security-path", out / "cache/security",
                 "-Xswiftc", "-warnings-as-errors"]
    if not NATIVE:
        arguments.append("--use-integrated-swift-driver")
    commands.run(arguments, f"test-{variant}-{configuration}")


def check_pair(pair: list[dict]) -> None:
    if len(pair) != 2 or {row["variant"] for row in pair} != set(VARIANTS):
        raise RuntimeError("Incomplete or duplicate pair")
    for field in ("id", "category", "files", "iterations", "checksum"):
        if pair[0][field] != pair[1][field]:
            raise RuntimeError(f"Timing output mismatch in {field}: {pair[0]['id']}")


def summarize(rows: list[dict]) -> list[dict]:
    results = []
    for scenario in dict.fromkeys(row["id"] for row in rows):
        selected = [row for row in rows if row["id"] == scenario]
        pairs = []
        for index in sorted({row["pair"] for row in selected}):
            pair = [row for row in selected if row["pair"] == index]
            check_pair(pair)
            pairs.append({row["variant"]: row for row in pair})
        metrics = {}
        for field in ("cpuNs", "wallNs"):
            values = {variant: [p[variant][field] / p[variant]["iterations"] for p in pairs]
                      for variant in VARIANTS}
            medians = {v: statistics.median(xs) for v, xs in values.items()}
            ratios = [p["candidate"][field] / p["baseline"][field] for p in pairs]
            metrics[field] = {"baselineMedian": medians["baseline"], "candidateMedian": medians["candidate"],
                              "medianReductionPercent": 100 * (1 - medians["candidate"] / medians["baseline"]),
                              "pairedRatioMedian": statistics.median(ratios), "pairedRatios": ratios,
                              "candidateFasterPairs": sum(r < 1 for r in ratios),
                              "ranges": {v: [min(xs), max(xs)] for v, xs in values.items()}}
        results.append({"id": scenario, "category": selected[0]["category"], "files": selected[0]["files"],
                        "iterations": selected[0]["iterations"], "pairs": len(pairs),
                        "nanosecondsPerOperation": metrics})
    return results


def benchmark(out: Path, args, compiler: dict, commands: Commands) -> None:
    binaries = {variant: build(variant, out, compiler, commands) for variant in VARIANTS}
    receipts = {v: commands.run([binary["classification"], "verify"], f"verify-classification-{v}")
                for v, binary in binaries.items()}
    if receipts["baseline"].read_bytes() != receipts["candidate"].read_bytes():
        raise RuntimeError("Complete URL classification receipts differ")
    receipt = json.loads(receipts["candidate"].read_text())
    verification = {"classificationEqual": True, "classificationCaseCount": receipt["caseCount"],
                    "classificationSHA256": sha256(receipts["candidate"])}
    print(f"PASS full classification parity: {receipt['caseCount']} URLs", flush=True)
    lists = {v: commands.json([binary["classification"], "scenarios"], f"scenarios-{v}")
             for v, binary in binaries.items()}
    if lists["baseline"] != lists["candidate"]:
        raise RuntimeError("Classification scenario definitions differ")
    cases = [{**s, "category": "classification", "argument": s["id"], "id": "classification-" + s["id"]}
             for s in lists["candidate"]]
    folders = fixtures(out / "fixtures")
    save(out / "evidence/folder-fixtures.json", folders)
    expected_playlists = {}
    for folder in folders:
        outputs = {v: commands.json([binary["discovery"], "verify", folder["path"]],
                                   f"verify-discovery-{folder['id']}-{v}")
                   for v, binary in binaries.items()}
        if outputs["baseline"] != outputs["candidate"]:
            raise RuntimeError(f"Full discovery output differs: {folder['id']}")
        if folder["expected_media"] is not None and len(outputs["baseline"]["items"]) != folder["expected_media"]:
            raise RuntimeError(f"Unexpected discovery item count: {folder['id']}")
        identifier = "discovery-" + folder["id"]
        expected_playlists[identifier] = outputs["baseline"]
        cases.append({"id": identifier, "category": "discovery", "argument": folder["path"],
                      "files": folder["entries"], "mediaCount": len(outputs["baseline"]["items"])})
    save(out / "evidence/discovery-verification.json", expected_playlists)
    verification.update(discoveryEqual=True, discoveryFixtureCount=len(folders),
                        discoverySHA256=sha256(out / "evidence/discovery-verification.json"))
    save(out / "evidence/verification.json", verification)
    save(out / "evidence/scenarios.json", cases)
    print(f"PASS full discovery parity: {len(folders)} real filesystem fixtures", flush=True)

    def measure(variant: str, case: dict, iterations: int, label: str) -> dict:
        row = commands.json([binaries[variant][case["category"]], "bench", case["argument"], iterations],
                            f"{label}-{case['id']}-{variant}", benchmark=True, quiet=True)
        if row["iterations"] != iterations or min(row["cpuNs"], row["wallNs"]) <= 0:
            raise RuntimeError(f"Invalid timing receipt: {row}")
        if case["category"] == "discovery":
            if row.pop("receipt") != expected_playlists[case["id"]]:
                raise RuntimeError(f"Timed discovery changed its output: {case['id']}")
        elif row["id"] != case["argument"] or row["files"] != case["files"] or row["mode"] != case["mode"]:
            raise RuntimeError(f"Wrong classification scenario: {row}")
        row.update(variant=variant, id=case["id"], category=case["category"], files=case["files"])
        return row

    counts = {}
    with (out / "evidence/calibration.jsonl").open("w") as stream:
        for case_index, case in enumerate(cases):
            count = args.iterations or 1
            target = args.target_ms if case["category"] == "classification" else args.discovery_target_ms
            if args.iterations is None:
                for attempt in range(8):
                    order = VARIANTS if (case_index + attempt) % 2 == 0 else tuple(reversed(VARIANTS))
                    pair = [measure(v, case, count, f"pilot-{attempt}") for v in order]
                    check_pair(pair)
                    for row in pair:
                        stream.write(json.dumps({**row, "attempt": attempt, "order": order}) + "\n")
                    stream.flush()
                    fastest = min(row["cpuNs"] for row in pair)
                    if fastest >= target * 1_000_000:
                        break
                    count = max(count + 1, math.ceil(count * target * 1_000_000 / fastest * 1.05))
                else:
                    raise RuntimeError(f"Calibration did not converge: {case['id']}")
            counts[case["id"]] = count
    save(out / "evidence/iteration-counts.json", counts)
    rows = []
    with (out / "evidence/measurements.jsonl").open("w") as stream:
        for index in range(args.pairs):
            for case_index, case in enumerate(cases):
                order = VARIANTS if (index + case_index) % 2 == 0 else tuple(reversed(VARIANTS))
                pair = []
                for variant in order:
                    row = measure(variant, case, counts[case["id"]], f"pair-{index:02d}")
                    row.update(pair=index, order=list(order))
                    rows.append(row)
                    pair.append(row)
                    stream.write(json.dumps(row, sort_keys=True) + "\n")
                    stream.flush()
                check_pair(pair)
            print(f"Completed pair {index + 1}/{args.pairs}", flush=True)
    results = summarize(rows)
    save(out / "evidence/summary.json", {"verification": verification, "scenarios": results})
    for row in results:
        cpu = row["nanosecondsPerOperation"]["cpuNs"]
        print(f"{row['id']}: {cpu['baselineMedian'] / 1000:.2f} -> {cpu['candidateMedian'] / 1000:.2f} us CPU/operation; "
              f"paired change {(cpu['pairedRatioMedian'] - 1) * 100:+.2f}%; "
              f"{cpu['candidateFasterPairs']}/{row['pairs']} faster", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--pairs", type=int, default=12)
    parser.add_argument("--target-ms", type=float, default=250)
    parser.add_argument("--discovery-target-ms", type=float, default=100)
    parser.add_argument("--iterations", type=int)
    parser.add_argument("--skip-tests", action="store_true", help="Exploration only; qualification includes both configurations")
    parser.add_argument("--swiftc")
    parser.add_argument("--swift")
    args = parser.parse_args()
    if not 2 <= args.pairs <= 30 or args.pairs % 2:
        parser.error("Use even --pairs in 2...30")
    if any(not math.isfinite(x) or not 1 <= x <= 2000 for x in (args.target_ms, args.discovery_target_ms)):
        parser.error("Timing targets must be finite and in 1...2000 ms")
    if args.iterations is not None and args.iterations < 1:
        parser.error("--iterations must be positive")
    out = args.output.resolve()
    if out.exists() and (not out.is_dir() or any(out.iterdir())):
        parser.error("Use a fresh output directory; previous evidence is never overwritten")
    out.mkdir(parents=True, exist_ok=True)
    commands = Commands(out)
    receipt = snapshot(out)
    compiler = toolchain(args, commands)
    receipt.update(recordedUTC=datetime.now(timezone.utc).isoformat(), platform=platform.platform(),
                   machine=platform.machine(), cpuCount=os.cpu_count(), python=sys.version, compiler=compiler,
                   testsIncluded=not args.skip_tests, timingEnvironment={"SWIFT_DETERMINISTIC_HASHING": "1"},
                   arguments={k: str(v) if isinstance(v, Path) else v for k, v in vars(args).items()},
                   method="Exact production sources; independently optimized library and harnesses; complete output parity; same iterations within balanced fresh-process AB/BA pairs.")
    save(out / "evidence/manifest.json", receipt)
    if not args.skip_tests:
        for variant in VARIANTS:
            for configuration in ("debug", "release"):
                test(variant, configuration, out, compiler, commands)
    benchmark(out, args, compiler, commands)
    current = {name: sha256(ROOT / path) for name, path in receipt["sourcePaths"].items()}
    if current != receipt["inputSHA256"]:
        raise RuntimeError("Inputs changed during qualification; rerun from a stable snapshot")
    save(out / "evidence/input-verification.json", {"unchanged": True, "inputSHA256": current})


if __name__ == "__main__":
    main()
