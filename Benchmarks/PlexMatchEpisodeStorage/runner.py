#!/usr/bin/env python3
"""Qualify compact PlexMatch storage using complete production sources on macOS."""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import statistics
import subprocess
import sys
import time

BASELINE = "4abf4b44f13386ccd04f1ce4ad0e756255ca4d14"
SOURCE_NAMES = ["MediaNameRecognition", "MediaMetadataHints", "PlexMatchHints",
                "NFOMetadataHints", "MediaSidecarReader"]
TEST_NAMES = ["PlexMatchHintsRegressionTests", "PlexMatchReaderRegressionTests", "MediaSidecarTests"]
SOURCE_PATHS = [f"Sources/IlliquidCore/MediaLibrary/{name}.swift" for name in SOURCE_NAMES]
TEST_PATHS = [f"Tests/IlliquidCoreTests/{name}.swift" for name in TEST_NAMES]
HARNESS_PATHS = [f"Benchmarks/PlexMatchEpisodeStorage/{name}"
                 for name in ("Harness.swift", "MemoryProbe.c", "runner.py")]
HEADER = "#include <stdint.h>\nuint64_t plexmatch_heap_in_use(void);\n"
PACKAGE = '''// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "PlexMatchStorageQualification",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "IlliquidCore"),
        .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"])
    ]
)
'''


def digest(path: Path) -> str:
    result = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def save_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False, sort_keys=True) + "\n")


def git(repo: Path, *args: str) -> bytes:
    result = subprocess.run(["git", *args], cwd=repo, capture_output=True)
    if result.returncode:
        raise RuntimeError(f"git {' '.join(args)} failed: {result.stderr.decode(errors='replace')}")
    return result.stdout


class Commands:
    def __init__(self, evidence: Path, env: dict[str, str]):
        self.evidence, self.env, self.records = evidence, env, []
        (evidence / "logs").mkdir()

    def run(self, argv, label: str, *, cwd: Path, timeout: int = 180,
            quiet: bool = False, benchmark: bool = False) -> str:
        argv = [str(arg) for arg in argv]
        stdout = self.evidence / "logs" / (label + ".stdout.log")
        stderr = self.evidence / "logs" / (label + ".stderr.log")
        environment = dict(self.env)
        if benchmark:
            environment["SWIFT_DETERMINISTIC_HASHING"] = "1"
        record = {"label": label, "argv": argv, "cwd": str(cwd),
                  "benchmarkDeterministicHashing": benchmark}
        start = time.monotonic()
        try:
            with stdout.open("wb") as out, stderr.open("wb") as err:
                result = subprocess.run(argv, cwd=cwd, env=environment, stdout=out,
                                        stderr=err, timeout=timeout)
            record["returncode"] = result.returncode
        except subprocess.TimeoutExpired:
            record["returncode"] = "timeout"
        finally:
            record.update(elapsedSeconds=time.monotonic() - start,
                          stdout=str(stdout.relative_to(self.evidence)),
                          stderr=str(stderr.relative_to(self.evidence)),
                          stdoutSHA256=digest(stdout), stderrSHA256=digest(stderr))
            self.records.append(record)
            save_json(self.evidence / "commands.json", self.records)
        if not quiet:
            print(f"{label}: {record['returncode']} ({record['elapsedSeconds']:.2f}s)", flush=True)
        if record["returncode"] != 0:
            raise RuntimeError(f"{label} failed ({record['returncode']}); "
                               f"see {stdout} and {stderr}\n{stderr.read_text(errors='replace')[-4000:]}")
        return stdout.read_text()


def make_fixtures(directory: Path) -> dict:
    header = "title: Retained Café 🎬\nyear: 2019\nseason: 7\ntvdbid: 42\nguid: imdb://tt123\n"

    def mapping(index: int) -> tuple[str, str]:
        episode = index % 8998 + 1
        tokens = [f"E{episode:04}", f"S03E{episode:04}", f"SP{episode:04}",
                  f"S04E{episode:04}-E{episode + 1:04}"]
        key = ("Season 2/" if index % 5 == 4 else "") + f"episode-{index:05}.mkv"
        return key, f"ep: {tokens[index % 4]}: {key}\n"

    def write_fixture(identifier: str, text: str, keys: list[str], mappings: int) -> dict:
        path = directory / "cases" / identifier / ".plexmatch"
        path.parent.mkdir(parents=True, exist_ok=True)
        data = text.encode()
        assert len(data) <= 128 * 1024
        path.write_bytes(data)
        for key in keys[:3] + keys[-1:] + ["__missing__.mkv"]:
            if key.startswith("/") or ".." in key.split("/") or "\\" in key:
                continue
            media = path.parent / key
            media.parent.mkdir(parents=True, exist_ok=True)
            media.touch()
        return {"id": identifier, "file": str(path.relative_to(directory)),
                "mappings": mappings, "inputBytes": len(data), "keys": keys}

    cases = []
    for count in (0, 1, 24, 1024):
        rows = [mapping(index) for index in range(count)]
        cases.append(write_fixture(f"mappings-{count}", header + "".join(row[1] for row in rows),
                                   [row[0] for row in rows], count))
    rows, total = [], len(header.encode())
    while True:
        row = mapping(len(rows))
        size = len(row[1].encode())
        if total + size > 128 * 1024:
            break
        rows.append(row)
        total += size
    near_text = header + "".join(row[1] for row in rows)
    assert 127 * 1024 <= total <= 128 * 1024
    cases.append(write_fixture("near-128kib", near_text, [row[0] for row in rows], len(rows)))
    contract = write_fixture("semantic-contract", """\ufefftitle: 番組 Café 🎬
year: 2022
tvdbid: 12
guid: imdb://tt42
ep: S02E03-E05: duplicate.mkv
ep: E06: duplicate.mkv
ep: E０２: duplicate.mkv
ep: E04: local.mkv
ep: S000E0000: zero.mkv
ep: SP01-S00E02: special.mkv
ep: s03e04-e06: nested/範囲é 🎬.mkv
ep: E07: café.mkv
ep: E08: café.mkv
ep: S02E03-S03E04: invalid-cross-season.mkv
ep: E04-E04: invalid-range.mkv
ep: E０２: invalid-unicode.mkv
ep: E02: ../escape.mkv
ep: E02: /absolute.mkv
""", ["duplicate.mkv", "local.mkv", "zero.mkv", "special.mkv", "nested/範囲é 🎬.mkv",
      "café.mkv", "café.mkv", "invalid-cross-season.mkv", "invalid-range.mkv",
      "invalid-unicode.mkv", "../escape.mkv", "/absolute.mkv"], 6)
    cache_files, cache_bytes = [], 0
    for index in range(32):
        folder = directory / "cache" / f"series-{index:03}"
        folder.mkdir(parents=True)
        text = near_text.replace("title: Retained Café 🎬", f"title: Cache Series {index:03}", 1)
        data = text.encode()
        assert len(data) <= 128 * 1024
        (folder / ".plexmatch").write_bytes(data)
        (folder / rows[0][0]).touch()
        cache_files.append(f"series-{index:03}/{rows[0][0]}")
        cache_bytes += len(data)
    assert cache_bytes < 16 * 1024 * 1024
    fixtures = {"cases": cases, "contract": contract,
                "cache": {"id": "reader-cache-32", "root": "cache", "files": cache_files,
                          "totalInputBytes": cache_bytes, "sidecarCount": 32}}
    save_json(directory / "fixtures.json", fixtures)
    return fixtures


def summarize(samples: list[dict], fixtures: dict, args) -> dict:
    summaries = []
    for fixture in fixtures["cases"] + [fixtures["cache"]]:
        grouped = {variant: [s for s in samples if s["variant"] == variant
                            and s["scenario"] == fixture["id"]] for variant in ("baseline", "candidate")}
        memory = {variant: [s["allocation"]["releasedBytes"] for s in rows]
                  for variant, rows in grouped.items()}
        medians = {variant: statistics.median(values) for variant, values in memory.items()}
        difference = medians["baseline"] - medians["candidate"]
        paired = {variant: {row["pair"]: row for row in rows} for variant, rows in grouped.items()}
        reductions = []
        for pair in range(args.pairs):
            baseline, candidate = paired["baseline"][pair], paired["candidate"][pair]
            if baseline["allocation"]["payloadChecksum"] != candidate["allocation"]["payloadChecksum"]:
                raise RuntimeError(f"retained payload differs for {fixture['id']} pair {pair}")
            reductions.append(baseline["allocation"]["releasedBytes"] - candidate["allocation"]["releasedBytes"])
        timing = {}
        for metric in grouped["baseline"][0]["timings"]:
            measurements = {variant: [s["timings"][metric]["nanosecondsPerOperation"] for s in rows]
                            for variant, rows in grouped.items()}
            med = {variant: statistics.median(values) for variant, values in measurements.items()}
            ratios = [paired["candidate"][pair]["timings"][metric]["nanosecondsPerOperation"]
                      / paired["baseline"][pair]["timings"][metric]["nanosecondsPerOperation"]
                      for pair in range(args.pairs)]
            timing[metric] = {"baselineMedianNanoseconds": med["baseline"],
                              "candidateMedianNanoseconds": med["candidate"],
                              "candidateOverBaseline": med["candidate"] / med["baseline"],
                              "pairedCandidateOverBaseline": {"ratios": ratios,
                                  "median": statistics.median(ratios), "range": [min(ratios), max(ratios)],
                                  "candidateFasterPairs": sum(ratio < 1 for ratio in ratios)},
                              "rangesNanoseconds": {v: [min(xs), max(xs)] for v, xs in measurements.items()}}
        summaries.append({"scenario": fixture["id"], "mappings": fixture.get("mappings"),
                          "sidecarCount": fixture.get("sidecarCount", 1),
                          "inputBytes": fixture.get("inputBytes", fixture.get("totalInputBytes")),
                          "baselineMedianReleasedBytes": medians["baseline"],
                          "candidateMedianReleasedBytes": medians["candidate"],
                          "medianReductionBytes": difference,
                          "pairedReductionBytes": {"values": reductions, "median": statistics.median(reductions),
                                                   "range": [min(reductions), max(reductions)],
                                                   "positivePairs": sum(value > 0 for value in reductions)},
                          "reductionPercent": 100 * difference / medians["baseline"] if medians["baseline"] else None,
                          "releasedBytesRanges": {v: [min(xs), max(xs)] for v, xs in memory.items()},
                          "timings": timing})
    meaningful = [s for s in summaries if s["scenario"] in ("mappings-1024", "near-128kib", "reader-cache-32")]
    return {"schemaVersion": 1, "status": "passed",
            "baselineRevision": BASELINE, "pairs": args.pairs, "targetMilliseconds": args.target_ms,
            "semanticParity": True, "tests": "same current suites passed on both sources in debug and release",
            "memoryMetric": "malloc_zone_statistics(NULL).size_in_use held minus after explicit payload release",
            "largeCaseMemoryReductionObserved": all(s["medianReductionBytes"] > 0 for s in meaningful),
            "scenarios": summaries,
            "limitations": ["Component allocator storage, not RSS or whole-player memory.",
                            "Dictionary capacity and allocator size classes govern storage; no per-entry heap allocation claim.",
                            "Timing includes an autorelease pool and scalar consumer per operation; parse also includes one lookup.",
                            "Each process calibrates its own iteration count; timing checksums are sinks, not parity checks.",
                            "Timing ratios are descriptive, not a statistical no-regression guarantee."]}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--target-ms", type=float, default=100)
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument("--swift", type=Path)
    args = parser.parse_args()
    if not 1 <= args.pairs <= 20 or not 1 <= args.target_ms <= 1000:
        parser.error("--pairs must be 1...20 and --target-ms must be 1...1000")
    repo = Path(__file__).resolve().parents[2]
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("--output must be absent or empty; evidence is never overwritten")
    if platform.system() != "Darwin" and not args.prepare_only:
        parser.error("execution requires macOS; use --prepare-only elsewhere")
    output.mkdir(parents=True, exist_ok=True)
    evidence = output / "evidence"
    evidence.mkdir()
    snapshot = evidence / "sources"
    inputs = SOURCE_PATHS + TEST_PATHS + HARNESS_PATHS
    input_hashes = {name: digest(repo / name) for name in inputs}
    packages, source_hashes = {}, {}
    for variant in ("baseline", "candidate"):
        package = output / "packages" / variant
        packages[variant] = package
        source_hashes[variant] = {}
        for name in SOURCE_PATHS:
            data = git(repo, "show", f"{BASELINE}:{name}") if variant == "baseline" else (repo / name).read_bytes()
            path = package / "Sources" / "IlliquidCore" / Path(name).name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
            original = snapshot / variant / name
            original.parent.mkdir(parents=True, exist_ok=True)
            original.write_bytes(data)
            source_hashes[variant][name] = digest(path)
        for name in TEST_PATHS:
            path = package / name
            path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(repo / name, path)
        (package / "Package.swift").write_text(PACKAGE)
    changed = [name for name in SOURCE_PATHS if source_hashes["baseline"][name] != source_hashes["candidate"][name]]
    if changed != ["Sources/IlliquidCore/MediaLibrary/PlexMatchHints.swift"]:
        raise RuntimeError(f"expected only PlexMatchHints.swift to differ, found {changed}")
    for name in TEST_PATHS + HARNESS_PATHS:
        path = snapshot / "common" / name
        path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(repo / name, path)
    (snapshot / "common" / "Package.swift").write_text(PACKAGE)
    (snapshot / "common" / "MemoryProbe.h").write_text(HEADER)
    fixtures_directory = evidence / "fixtures"
    fixtures = make_fixtures(fixtures_directory)
    candidate_diff = git(repo, "diff", "--binary", "HEAD", "--", *inputs)
    (evidence / "candidate.patch").write_bytes(candidate_diff)
    manifest = {"schemaVersion": 1, "preparedAtUTC": dt.datetime.now(dt.timezone.utc).isoformat(),
                "baselineRevision": BASELINE, "candidateRevision": git(repo, "rev-parse", "HEAD").decode().strip(),
                "candidateStatus": git(repo, "status", "--short", "--untracked-files=all", "--", *inputs).decode(),
                "candidateDiffSHA256": hashlib.sha256(candidate_diff).hexdigest(),
                "inputSHA256": input_hashes, "productionSHA256": source_hashes,
                "changedProductionSources": changed, "platform": platform.platform(),
                "machine": platform.machine(), "pythonVersion": sys.version,
                "arguments": vars(args) | {"output": str(output), "swift": str(args.swift) if args.swift else None},
                "benchmarkEnvironment": {"SWIFT_DETERMINISTIC_HASHING": "1"},
                "fixtureSHA256": {str(path.relative_to(fixtures_directory)): digest(path)
                                  for path in sorted(fixtures_directory.rglob("*")) if path.is_file()},
                "generatedPackageSHA256": hashlib.sha256(PACKAGE.encode()).hexdigest(),
                "generatedProbeHeaderSHA256": hashlib.sha256(HEADER.encode()).hexdigest()}
    save_json(evidence / "manifest.json", manifest)
    if args.prepare_only:
        save_json(evidence / "summary.json", {"status": "prepared-only", "executed": False,
                                             "fixtures": [{k: v for k, v in f.items() if k != "keys"}
                                                          for f in fixtures["cases"]], "cache": fixtures["cache"]})
        print(f"Prepared exact source packages and fixtures: {evidence}")
        return

    environment = dict(os.environ)
    environment["CLANG_MODULE_CACHE_PATH"] = str(output / "module-cache")
    environment["SWIFTPM_MODULECACHE_OVERRIDE"] = str(output / "module-cache")
    commands = Commands(evidence, environment)
    try:
        swift = args.swift or Path(commands.run(["xcrun", "--find", "swift"], "find-swift", cwd=repo).strip())
        swiftc = swift.with_name("swiftc")
        clang = Path(commands.run(["xcrun", "--find", "clang"], "find-clang", cwd=repo).strip())
        sdk = commands.run(["xcrun", "--sdk", "macosx", "--show-sdk-path"], "find-sdk", cwd=repo).strip()
        version = commands.run([swift, "--version"], "swift-version", cwd=repo).strip()
        manifest["toolchain"] = {"version": version, "sdk": sdk,
                                 "tools": {name: {"path": str(path), "resolvedPath": str(path.resolve()),
                                                  "sha256": digest(path.resolve())}
                                           for name, path in (("swift", swift), ("swiftc", swiftc), ("clang", clang))}}
        save_json(evidence / "manifest.json", manifest)
        test_results = []
        for variant, package in packages.items():
            for configuration in ("debug", "release"):
                label = f"tests-{variant}-{configuration}"
                stdout = commands.run([swift, "test", "--package-path", package,
                              "--scratch-path", output / "build" / variant,
                              "--cache-path", output / "swift-cache",
                              "--config-path", output / "swift-config",
                              "--security-path", output / "swift-security",
                              "--jobs", "2", "--no-parallel", "-c", configuration],
                             label, cwd=repo, timeout=240)
                logs = stdout + (evidence / "logs" / (label + ".stderr.log")).read_text()
                counts = re.findall(r"Test run with (\d+) tests?\b[^\n]*\bpassed\b", logs)
                if not counts or int(counts[-1]) <= 0:
                    raise RuntimeError(f"{label} did not report a nonempty successful Swift Testing run")
                test_results.append({"variant": variant, "configuration": configuration,
                                     "passedTests": int(counts[-1]), "logLabel": label})
                save_json(evidence / "tests.json", test_results)
        if len({result["passedTests"] for result in test_results}) != 1:
            raise RuntimeError("baseline/candidate debug/release test counts differ")
        target = platform.machine() + "-apple-macosx26.0"
        common = snapshot / "common" / "Benchmarks" / "PlexMatchEpisodeStorage"
        binaries = output / "bin"
        binaries.mkdir()
        c_object = binaries / "MemoryProbe.o"
        commands.run([clang, "-O2", "-target", target, "-isysroot", sdk, "-c", common / "MemoryProbe.c", "-o", c_object],
                     "compile-probe", cwd=repo)
        executables = {}
        for variant, package in packages.items():
            executable = binaries / variant
            executables[variant] = executable
            commands.run([swiftc, "-swift-version", "6", "-O", "-whole-module-optimization", "-parse-as-library",
                          "-module-name", "PlexMatchEpisodeStorage", "-target", target, "-sdk", sdk,
                          "-module-cache-path", output / "module-cache",
                          "-import-objc-header", snapshot / "common" / "MemoryProbe.h",
                          *[package / "Sources" / "IlliquidCore" / f"{name}.swift" for name in SOURCE_NAMES],
                          common / "Harness.swift", c_object, "-o", executable],
                         f"compile-{variant}", cwd=repo)
        manifest["binarySHA256"] = {v: digest(p) for v, p in executables.items()}
        manifest["probeObjectSHA256"] = digest(c_object)
        save_json(evidence / "manifest.json", manifest)
        semantic = {}
        fixture_manifest = fixtures_directory / "fixtures.json"
        for variant, executable in executables.items():
            raw = commands.run([executable, "semantic", fixture_manifest], f"semantic-{variant}", cwd=repo,
                               benchmark=True)
            semantic[variant] = json.loads(raw)
            (evidence / f"semantic-{variant}.json").write_text(raw)
        if semantic["baseline"] != semantic["candidate"]:
            raise RuntimeError("full semantic output differs; inspect semantic-baseline.json and semantic-candidate.json")
        save_json(evidence / "parity.json", {"equal": True,
                                            "sha256": {v: digest(evidence / f"semantic-{v}.json") for v in semantic}})
        samples = []
        with (evidence / "samples.jsonl").open("w") as sink:
            for pair in range(args.pairs):
                order = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
                for fixture in fixtures["cases"] + [fixtures["cache"]]:
                    for position, variant in enumerate(order):
                        raw = commands.run([executables[variant], "sample", fixture_manifest, fixture["id"], str(args.target_ms)],
                                           f"pair-{pair:02}-{fixture['id']}-{variant}", cwd=repo, quiet=True,
                                           benchmark=True)
                        sample = json.loads(raw) | {"pair": pair, "position": position, "variant": variant}
                        samples.append(sample)
                        sink.write(json.dumps(sample, sort_keys=True) + "\n")
                        sink.flush()
                print(f"Completed pair {pair + 1}/{args.pairs}: {' / '.join(order)}", flush=True)
        if input_hashes != {name: digest(repo / name) for name in inputs}:
            raise RuntimeError("benchmark input changed during qualification")
        summary = summarize(samples, fixtures, args)
        summary["candidateRevision"] = manifest["candidateRevision"]
        if not summary["largeCaseMemoryReductionObserved"]:
            summary["status"] = "no-demonstrated-memory-reduction"
        save_json(evidence / "summary.json", summary)
        print(json.dumps(summary, indent=2, sort_keys=True), flush=True)
        if not summary["largeCaseMemoryReductionObserved"]:
            raise RuntimeError("required large-fixture allocator reduction was not observed")
    except Exception as error:
        save_json(evidence / "failure.json", {"error": str(error), "type": type(error).__name__})
        raise


if __name__ == "__main__":
    main()
