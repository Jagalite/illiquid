#!/usr/bin/env python3
"""Qualify and measure folder discovery using exact production Swift sources.

Run on macOS 26/Xcode 26.6 or a Swift 6.1+ Linux/glibc host:
  python3 Benchmarks/FolderDiscoveryClassification/run.py --pairs 6 --output DIR
The output directory must be new or empty. Tests run by default. No timing gate.
"""
from __future__ import annotations

import argparse
import datetime
import hashlib
import json
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
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
TARGET = "Playlist/FolderPlaylistDiscovery.swift"
BASELINE_TARGET_BLOB = "ed360be504b966541b75ccda98486cbe788dfd92"
SOURCES = [
    "Playlist/ExternalSubtitleMatcher.swift", "Playlist/FolderPlaylist.swift",
    TARGET, "Playlist/PlaylistMutation.swift", "Utilities/MediaFileSupport.swift",
    "Utilities/NaturalFilenameOrdering.swift", "Utilities/NormalizedFileURL.swift",
]
TESTS = [
    "FolderDiscoveryClassificationTests.swift", "FolderDiscoveryFilesystemRegressionTests.swift",
    "FolderPlaylistDiscoveryTests.swift", "FolderPlaylistTests.swift",
    "PreparedPlaylistConstructionTests.swift", "TestSupport/TemporaryDirectory.swift",
]
PACKAGE = '''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "FolderDiscoveryClassificationQualification",
    platforms: [.macOS("26.0")],
    targets: [.target(name: "IlliquidCore"),
        .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"])])
'''


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def git_blob(data: bytes) -> str:
    return hashlib.sha1(f"blob {len(data)}\0".encode() + data).hexdigest()


def save(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


class Run:
    def __init__(self, output: Path):
        self.output = output
        self.sequence = 0
        (output / "logs").mkdir()
        self.env = os.environ.copy()
        self.env.update(SWIFTPM_MODULECACHE_OVERRIDE=str(output / "cache" / "swift-module"),
                        CLANG_MODULE_CACHE_PATH=str(output / "cache" / "clang-module"))

    def command(self, args, label, *, extra_env=None, timeout=1200):
        self.sequence += 1
        arguments = list(map(str, args))
        log = self.output / "logs" / f"{self.sequence:04d}-{label}.log"
        env = self.env | (extra_env or {})
        started = time.monotonic()
        result = subprocess.run(arguments, cwd=ROOT, env=env, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=timeout)
        log.write_bytes(result.stdout)
        with (self.output / "commands.jsonl").open("a") as stream:
            stream.write(json.dumps(dict(arguments=arguments, returncode=result.returncode,
                elapsed_seconds=time.monotonic() - started, extra_environment=extra_env or {},
                log=str(log.relative_to(self.output)), log_sha256=sha(result.stdout)), sort_keys=True) + "\n")
        if result.returncode:
            raise RuntimeError(f"Command failed ({label}); see {log}\n{result.stdout.decode(errors='replace')[-4000:]}")
        return result.stdout.decode().strip()


def stage_sources(run: Run, manifest: dict) -> dict[str, list[Path]]:
    staged = {"baseline": [], "candidate": []}
    receipts = {key: {} for key in staged}
    for relative in SOURCES:
        source = "Sources/IlliquidCore/" + relative
        original = subprocess.check_output(["git", "show", f"{BASELINE}:{source}"], cwd=ROOT)
        candidate = (ROOT / source).read_bytes()
        if relative == TARGET:
            if git_blob(original) != BASELINE_TARGET_BLOB:
                raise RuntimeError("Pinned baseline discovery blob does not match")
        elif original != candidate:
            raise RuntimeError(f"Unrelated production dependency changed: {source}")
        for variant, data in (("baseline", original), ("candidate", candidate)):
            destination = run.output / "sources" / variant / Path(relative).name
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(data)
            staged[variant].append(destination)
            receipts[variant][source] = dict(sha256=sha(data), git_blob=git_blob(data))
    manifest["production_sources"] = receipts
    manifest["harness_sources"] = {}
    for name in ("run.py", "Driver.swift", "MemoryProbe.c"):
        data = (HERE / name).read_bytes()
        (run.output / "sources" / name).write_bytes(data)
        manifest["harness_sources"][name] = sha(data)
    manifest["test_sources"] = {}
    for relative in TESTS:
        data = (ROOT / "Tests/IlliquidCoreTests" / relative).read_bytes()
        destination = run.output / "sources" / "tests" / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(data)
        manifest["test_sources"][relative] = sha(data)
    (run.output / "sources" / "Package.swift").write_text(PACKAGE)
    manifest["test_package_sha256"] = sha(PACKAGE.encode())
    return staged


def run_tests(run: Run, sources: dict, swift: str) -> dict:
    result = {}
    for variant, files in sources.items():
        package = run.output / "build" / f"{variant}-tests"
        source_dir = package / "Sources" / "IlliquidCore"
        source_dir.mkdir(parents=True)
        for path in files:
            shutil.copy2(path, source_dir)
        shutil.copytree(run.output / "sources" / "tests", package / "Tests" / "IlliquidCoreTests")
        (package / "Package.swift").write_text(PACKAGE)
        result[variant] = {}
        for configuration in ("debug", "release"):
            print(f"Testing {variant} / {configuration}", flush=True)
            command = [swift, "test", "--package-path", package, "--scratch-path", package / ".build",
                       "--cache-path", run.output / "cache" / "packages",
                       "--config-path", run.output / "cache" / "config",
                       "--security-path", run.output / "cache" / "security",
                       "-c", configuration, "--jobs", "2", "--no-parallel"]
            if platform.system() == "Linux":
                command.append("--use-integrated-swift-driver")
            text = run.command(command, f"test-{variant}-{configuration}")
            counts = re.findall(r"Test run with (\d+) tests? .*passed", text)
            if not counts or int(counts[-1]) == 0:
                raise RuntimeError(f"No positive Swift Testing completion receipt: {variant}/{configuration}")
            result[variant][configuration] = dict(passed=True, tests=int(counts[-1]))
            save(run.output / "tests.json", result)
    return result


def build_probes(run: Run, sources: dict, swiftc: str, cc: str, manifest: dict):
    darwin = platform.system() == "Darwin"
    suffix = ".dylib" if darwin else ".so"
    swift_sdk, c_sdk = [], []
    if darwin:
        sdk = run.command(["xcrun", "--sdk", "macosx", "--show-sdk-path"], "sdk-path")
        swift_sdk = ["-sdk", sdk, "-target", f"{platform.machine()}-apple-macosx26.0"]
        c_sdk = ["-isysroot", sdk, "-mmacosx-version-min=26.0"]
    flags = ["-O", "-whole-module-optimization", "-swift-version", "6", "-parse-as-library",
             "-module-cache-path", run.output / "cache" / "swift-module", *swift_sdk]
    libraries, binaries = {}, {}
    manifest["compiled_outputs"] = {}
    for mode in ("timing", "memory"):
        directory = run.output / "build" / ("probe-" + mode)
        directory.mkdir(parents=True)
        library = directory / ("libDiscoveryProbe" + suffix)
        shared = ["-dynamiclib", "-Wl,-install_name," + str(library)] if darwin else ["-shared", "-pthread"]
        run.command([cc, "-O2", "-std=c11", "-fPIC", "-fno-builtin", *c_sdk, *shared,
                     *(["-DFD_METERED=1"] if mode == "memory" else []),
                     run.output / "sources" / "MemoryProbe.c", "-o", library], "build-probe-" + mode)
        libraries[mode] = library
        manifest["compiled_outputs"][str(library.relative_to(run.output))] = sha(library.read_bytes())
    for variant, files in sources.items():
        directory = run.output / "build" / variant
        directory.mkdir(parents=True)
        library = directory / ("libIlliquidCore" + suffix)
        run.command([swiftc, *flags, "-emit-library", "-emit-module", "-module-name", "IlliquidCore",
                     "-emit-module-path", directory / "IlliquidCore.swiftmodule",
                     *files, "-o", library], "build-core-" + variant)
        manifest["compiled_outputs"][str(library.relative_to(run.output))] = sha(library.read_bytes())
        binaries[variant] = {}
        for mode, probe in libraries.items():
            binary = directory / ("discovery-" + mode)
            run.command([swiftc, *flags, "-I", directory, "-L", directory, "-lIlliquidCore",
                         "-L", probe.parent, "-lDiscoveryProbe",
                         "-Xlinker", "-rpath", "-Xlinker", directory,
                         "-Xlinker", "-rpath", "-Xlinker", probe.parent,
                         run.output / "sources" / "Driver.swift", "-o", binary],
                        f"build-driver-{variant}-{mode}")
            binaries[variant][mode] = binary
            manifest["compiled_outputs"][str(binary.relative_to(run.output))] = sha(binary.read_bytes())
    return binaries, libraries


def fixtures(output: Path) -> list[dict]:
    root = output / "fixtures"
    root.mkdir()
    cases = []

    def create(path):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.touch()
        os.utime(path, (1_730_000_000, 1_730_000_000))

    for name, media, subtitles, unrelated in [
        ("empty", 0, 0, 0), ("small-25-media-50-subtitles", 25, 50, 0),
        ("media-only-1000", 1000, 0, 0), ("mixed-250-media-500-subtitles", 250, 500, 0),
        ("large-1000-media-2000-subtitles", 1000, 2000, 0),
        ("subtitle-only-1000", 0, 1000, 0), ("unsupported-only-1000", 0, 0, 1000),
    ]:
        folder = root / name
        folder.mkdir()
        for i in range(media):
            create(folder / f"Feature {i:04}.mkv")
        for i in range(subtitles):
            language, extension = ("en", "srt") if i % 2 == 0 else ("fr", "ass")
            create(folder / f"Feature {i // 2:04}.{language}.{extension}")
        for i in range(unrelated):
            create(folder / f"notes-{i:04}.txt")
        cases.append(dict(name=name, path=str(folder), expected_items=media,
                          expected_subtitles=subtitles if media else 0))
    folder, targets = root / "symlink-rich", root / "targets"
    folder.mkdir()
    targets.mkdir()
    for i in range(100):
        for extension in ("mkv", "en.srt", "fr.ass", "txt"):
            target = targets / f"Feature {i:04}.{extension}"
            create(target)
            (folder / f"alias-{i:04}-{extension.replace('.', '-')}").symlink_to(target)
        if i < 20:
            (folder / f"duplicate-{i:04}.mkv").symlink_to(targets / f"Feature {i:04}.mkv")
    (folder / "broken.mkv").symlink_to(targets / "absent.mp4")
    (folder / "directory.mkv").symlink_to(targets, target_is_directory=True)
    (folder / "misleading.mp4").symlink_to(targets / "Feature 0000.txt")
    create(folder / "nested.mkv" / "Ignored.mp4")
    create(targets / ".Hidden.mkv")
    (folder / ".hidden-alias").symlink_to(targets / ".Hidden.mkv")
    cases.append(dict(name="symlink-rich", path=str(folder), expected_items=100, expected_subtitles=200))
    inventory = []
    for path in sorted(root.rglob("*")):
        stat = path.lstat()
        inventory.append(dict(path=str(path.relative_to(root)), size=stat.st_size,
            mtime_ns=stat.st_mtime_ns, ctime_ns=stat.st_ctime_ns,
            birthtime=getattr(stat, "st_birthtime", None),
            kind="symlink" if path.is_symlink() else "directory" if path.is_dir() else "file",
            target=os.readlink(path) if path.is_symlink() else None))
    save(output / "fixtures.json", dict(cases=cases, inventory=inventory))
    return cases


def summarize(rows: list[dict], cases: list[dict], pairs: int) -> list[dict]:
    summaries = []
    for mode in ("timing", "memory"):
        keys = ["wall_ns", "cpu_ns"] if mode == "timing" else ["allocation_requests", "requested_bytes", "largest_request_bytes"]
        for case in cases:
            selected = [row for row in rows if row["mode"] == mode and row["case"] == case["name"]]
            if len(selected) != 2 * pairs:
                raise RuntimeError("Missing paired observations")
            result = dict(mode=mode, case=case["name"], pairs=pairs, metrics={})
            for key in keys:
                values = {variant: [next(row[key] for row in selected if row["variant"] == variant and row["pair"] == pair)
                                    for pair in range(pairs)] for variant in ("baseline", "candidate")}
                ratios = [100 * (after / before - 1) for before, after in zip(values["baseline"], values["candidate"]) if before]
                result["metrics"][key] = {
                    **{variant: dict(median=statistics.median(items), minimum=min(items), maximum=max(items))
                       for variant, items in values.items()},
                    "median_paired_change_percent": statistics.median(ratios) if ratios else None,
                    "median_paired_difference": statistics.median(after - before for before, after in zip(values["baseline"], values["candidate"])),
                    "candidate_lower_pairs": sum(after < before for before, after in zip(values["baseline"], values["candidate"])),
                }
            summaries.append(result)
    return summaries


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pairs", type=int, default=6)
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2:
        parser.error("--pairs must be even and at least 2 for balanced AB/BA sampling")
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("--output must be new or empty")
    output.mkdir(parents=True, exist_ok=True)
    swift = shutil.which(os.environ.get("SWIFT", "swift"))
    swiftc = shutil.which(os.environ.get("SWIFTC", "swiftc"))
    cc = shutil.which(os.environ.get("CC", "cc"))
    if not swift or not swiftc or not cc:
        parser.error("Swift, swiftc and a C compiler are required; set SWIFT/SWIFTC/CC or PATH")
    if os.environ.get("LD_PRELOAD") or os.environ.get("DYLD_INSERT_LIBRARIES"):
        parser.error("Use a clean environment without preloaded instrumentation")
    run = Run(output)
    manifest = dict(schema_version=1, baseline=BASELINE, baseline_target_blob=BASELINE_TARGET_BLOB,
        created_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),
        candidate_revision=run.command(["git", "rev-parse", "HEAD"], "git-head"),
        candidate_status=run.command(["git", "status", "--short", "--", "Sources/IlliquidCore", "Tests/IlliquidCoreTests", str(HERE.relative_to(ROOT))], "git-status"),
        environment=dict(platform=platform.platform(), machine=platform.machine(), cpu_count=os.cpu_count(),
            swift=run.command([swift, "--version"], "swift-version"),
            swiftc=run.command([swiftc, "--version"], "swiftc-version"),
            cc=run.command([cc, "--version"], "cc-version"),
            variables={name: os.environ.get(name) for name in ("LANG", "LC_ALL", "LC_COLLATE", "DEVELOPER_DIR", "SWIFT_DETERMINISTIC_HASHING")}),
        method=dict(pairs=args.pairs, iterations_per_process=1,
            scope="Warm real local directory discovery: listing, symlink resolution, resource queries, classification, sorting, metadata and subtitle matching; no UI/decode/playback measurement.",
            source_boundary="Seven complete unmodified production files; only FolderPlaylistDiscovery.swift differs; separate optimized Swift modules without cross-module optimization.",
            sampling="Each observation is a fresh process with one untimed discovery and complete receipt serialization, then one measured discovery. Workload order rotates; pairs alternate AB/BA. All observations retained.",
            timing="Uninstrumented binary; monotonic wall and process CPU clocks. Fixture creation and output serialization excluded; returned model retained until both clocks stop. No empty-loop subtraction or timing gate.",
            allocation="Separate instrumented processes count successful covered malloc-family requests and requested sizes on the discover caller thread. Typed and zone entry points covered on macOS; malloc/calloc/realloc on glibc. Nested macOS entry points counted once. Realloc counts the full requested size. Not live bytes, peak memory, RSS, or total process allocations.",
            verification="Exact sorted-key Codable playlist and URL-representation bytes match warmup vs measured output and every baseline/candidate process. Identical receipts are retained once per fixture, with SHA-256 recorded for every observation."))
    sources = stage_sources(run, manifest)
    save(output / "manifest.json", manifest)
    tests = run_tests(run, sources, swift)
    binaries, libraries = build_probes(run, sources, swiftc, cc, manifest)
    save(output / "manifest.json", manifest)
    preload_key = "DYLD_INSERT_LIBRARIES" if platform.system() == "Darwin" else "LD_PRELOAD"
    meter_environment = {preload_key: str(libraries["memory"])}
    controls = {variant: json.loads(run.command([binaries[variant]["memory"], "self-test"],
                "meter-control-" + variant, extra_env=meter_environment)) for variant in binaries}
    save(output / "meter-controls.json", controls)
    cases = fixtures(output)
    (output / "receipts").mkdir()
    temporary_receipt = output / "build" / "current-receipt.json"
    rows, expected = [], {}
    for mode in ("timing", "memory"):
        for pair in range(args.pairs):
            rotated = cases[pair % len(cases):] + cases[:pair % len(cases)]
            for case in rotated:
                order = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
                for position, variant in enumerate(order):
                    row = json.loads(run.command([binaries[variant][mode], mode, case["path"], temporary_receipt],
                        f"{mode}-{pair}-{case['name']}-{variant}",
                        extra_env=meter_environment if mode == "memory" else None, timeout=180))
                    receipt = temporary_receipt.read_bytes()
                    if (row["mode"] != mode or not row["before_after_equal"] or row["receipt_bytes"] != len(receipt)
                            or row["item_count"] != case["expected_items"] or row["subtitle_count"] != case["expected_subtitles"]):
                        raise RuntimeError(f"Unexpected semantic result: {case['name']}/{variant}/{mode}")
                    if mode == "timing" and (row["cpu_ns"] <= 0 or row["wall_ns"] <= 0):
                        raise RuntimeError("Invalid timing observation")
                    if case["name"] in expected and receipt != expected[case["name"]]:
                        raise RuntimeError(f"Complete receipt mismatch: {case['name']}/{variant}/{mode}/{pair}")
                    if case["name"] not in expected:
                        expected[case["name"]] = receipt
                        (output / "receipts" / (case["name"] + ".json")).write_bytes(receipt)
                    row.update(case=case["name"], variant=variant, pair=pair, order=position,
                               receipt_sha256=sha(receipt))
                    rows.append(row)
                    with (output / "observations.jsonl").open("a") as stream:
                        stream.write(json.dumps(row, sort_keys=True) + "\n")
                print(f"{mode} pair {pair + 1}/{args.pairs}: {case['name']}", flush=True)
    summary = dict(tests=tests, observations=len(rows), all_receipts_equal=True,
                   results=summarize(rows, cases, args.pairs))
    save(output / "summary.json", summary)
    save(output / "verification.json", dict(all_complete_receipts_equal=True,
        measured_processes=len(rows), fixtures=len(cases), meter_controls_passed=True,
        receipts={name: sha(data) for name, data in expected.items()}))
    print(json.dumps(summary, indent=2, sort_keys=True), flush=True)


if __name__ == "__main__":
    main()
