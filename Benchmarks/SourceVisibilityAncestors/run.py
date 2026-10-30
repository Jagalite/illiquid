#!/usr/bin/env python3
"""Measure bounded ancestor reuse in the real recursive source projection.

The macOS sources are unchanged copies or guarded verbatim declarations. Linux
adapts POSIX/XML imports and one legacy test fixture's directory URL hint.
Fixtures, cache diagnostics, checksums and compilation are outside projection timings.
"""
from __future__ import annotations

import argparse
import collections
import copy
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import statistics
import subprocess
import sys
import tarfile
import time
import math
import re
import xml.etree.ElementTree as ET

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
# Reviewed integration inputs; future drift requires another explicit review.
# Conflict tree plus exact resolution.patch; fingerprints below identify resolved inputs.
REVIEWED_TREE = '0e4d46116d11a8155ea3449c64cbec0055074589'
REVIEWED_SNAPSHOTS = {'Sources/IlliquidCore/NormalizedFileURL.swift': '3b65c98b88722ca4d51c315a7fd5e2fde0e40c846071b6b1e34cd1f1eddb3fd2', 'Sources/IlliquidCore/MediaFileSupport.swift': '33657b48e87932f789b6ea92cf949029d916743859e964b8445a4e1bf4c8ff28', 'Sources/IlliquidCore/SourcePreparationExecutor.swift': '681fc16a1e263af5f5cf11bd5838fefa29b4bf77ef58aa3615a9180e5bbd7b16', 'Sources/IlliquidCore/MediaNameRecognition.swift': 'cc3c1ac628498798384c3e93973ffa0dcd6f21036b1f1de779cd54c82cc944d1', 'Sources/IlliquidCore/MediaMetadataHints.swift': '9df354b5f319aee2d29799b601562e46571d664650bfb298133f7425939ba53a', 'Sources/IlliquidCore/NFOMetadataHints.swift': '5e9728f84654f5f38818444b9f1ef40db0d751aa23eb6aba273e587cc1f9892a', 'Sources/IlliquidCore/PlexMatchHints.swift': 'b35ce4f067ecac4f714c0895aaaa6df3b58e1dcb6c8d4353e59d18abc26c962b', 'Sources/IlliquidCore/MediaSidecarReader.swift': '629ea274d9b34e64c8e7702c8963b44df84a5eeee0e4d425401fdf35f4ce635a', 'Sources/IlliquidApp/SourceBrowserFilter.swift': '3d0ffefc80607a38c57bcfd4d714b5a3feee3c1b91a6ff48af49957f425f526a', 'Sources/IlliquidApp/SourceTreeProjectionInput.swift': '5f1c6e088682ce4a7ef30e65b6ca7f2420dca323ec1ae679ee9c16ea547ffb67', 'Sources/IlliquidApp/AppValues.swift': 'f4ccb48676680e0f37a6d99e53e1fb0e19df7c442eb31c77c991b997c0fa6d4f', 'Sources/IlliquidApp/SidebarValues.swift': 'a728725d048a3d13da14aa95e4383742b3b6cb94db8f518568b6af2c00bc6f9d'}
REVIEWED_SOURCE_SHA256 = {'Sources/IlliquidCore/NormalizedFileURL.swift': '3b65c98b88722ca4d51c315a7fd5e2fde0e40c846071b6b1e34cd1f1eddb3fd2', 'Sources/IlliquidCore/MediaFileSupport.swift': '33657b48e87932f789b6ea92cf949029d916743859e964b8445a4e1bf4c8ff28', 'Sources/IlliquidCore/SourcePreparationExecutor.swift': '681fc16a1e263af5f5cf11bd5838fefa29b4bf77ef58aa3615a9180e5bbd7b16', 'Sources/IlliquidCore/MediaNameRecognition.swift': 'cc3c1ac628498798384c3e93973ffa0dcd6f21036b1f1de779cd54c82cc944d1', 'Sources/IlliquidCore/MediaMetadataHints.swift': '9df354b5f319aee2d29799b601562e46571d664650bfb298133f7425939ba53a', 'Sources/IlliquidCore/NFOMetadataHints.swift': '5e9728f84654f5f38818444b9f1ef40db0d751aa23eb6aba273e587cc1f9892a', 'Sources/IlliquidCore/PlexMatchHints.swift': 'b35ce4f067ecac4f714c0895aaaa6df3b58e1dcb6c8d4353e59d18abc26c962b', 'Sources/IlliquidCore/MediaSidecarReader.swift': '629ea274d9b34e64c8e7702c8963b44df84a5eeee0e4d425401fdf35f4ce635a', 'Sources/IlliquidApp/SourceBrowserFilter.swift': '3d0ffefc80607a38c57bcfd4d714b5a3feee3c1b91a6ff48af49957f425f526a', 'Sources/IlliquidApp/SourceTreeProjectionInput.swift': '5f1c6e088682ce4a7ef30e65b6ca7f2420dca323ec1ae679ee9c16ea547ffb67', 'Sources/IlliquidApp/AppValues.swift': '705ad5cc17dc9b3536d6d21f7546f7eb0aca16545d3f2e6b1d70186402d9b88a', 'Sources/IlliquidApp/SidebarValues.swift': '016bf6321ab59b80ef498b0e9743a4be119c267fa12cf06141068114b76d1eda'}
REVIEWED_TESTS = {'SourceBrowserFilterTests.swift': '54e83961990c31f064543337798a637eeaf5a812455f8585501034eb02e2a830', 'SourceMediaOrganizationTests.swift': '517339c32382ae1a546d63a11ab1971fcab6ceb46c96b0087a26ac93947dc48d', 'SourceTreeVisibilityCacheTests.swift': '69d98d02086bdb3511ff1338c92acf13f6b128c263df892faefa4db29c594204', 'SourceAncestorVisibilityTests.swift': '5eb049f8a2d268927f5ec3012a5c0fb7969aa220afda36cd6a5860f59a7a3ef0'}
CORE = [
    "Utilities/NormalizedFileURL.swift", "Utilities/MediaFileSupport.swift",
    "Utilities/SourcePreparationExecutor.swift", "MediaLibrary/MediaNameRecognition.swift",
    "MediaLibrary/MediaMetadataHints.swift", "MediaLibrary/NFOMetadataHints.swift",
    "MediaLibrary/PlexMatchHints.swift", "MediaLibrary/MediaSidecarReader.swift",
]
APP = ["UI/SourceBrowserFilter.swift", "UI/SourceTreeProjectionInput.swift"]
EXCERPTS = {
    "AppValues.swift": ("App/AppModel.swift", [
        ("struct SourceTabItem:", "\nenum SourceTabStore {"),
    ]),
    "SidebarValues.swift": ("UI/SourcesSidebar.swift", [
        ("struct SourceTreeEntry:", "\nstruct SourceDirectoryListing:"),
        ("enum SourceRecursiveMediaLoader {", "\nstruct SourceTreeDisplayRow:"),
        ("struct SourceTreeDisplayRow:", "\nstruct SourcesSidebarExpansionSnapshot:"),
    ]),
}
TESTS = ["SourceBrowserFilterTests.swift", "SourceMediaOrganizationTests.swift",
         "SourceTreeVisibilityCacheTests.swift", "SourceAncestorVisibilityTests.swift"]
CASES = ["siblings_depth6","groups_depth3","interleaved_depth3","unique_parent_depth3","hidden_near","hidden_far","root_children","no_rules","tree_direct","media_depth3"]
PACKAGE = '''// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "SourceTreeVisibilityQualification",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "SourceTreeBenchmark", targets: ["SourceTreeBenchmark"])],
    targets: [
        .target(name: "IlliquidCore"),
        // The driver needs internal APIs; tests never link its @main entry point.
        .target(name: "IlliquidApp", dependencies: ["IlliquidCore"],
                swiftSettings: [.unsafeFlags(["-enable-testing"])]),
        .executableTarget(name: "SourceTreeBenchmark", dependencies: ["IlliquidCore", "IlliquidApp"]),
        .testTarget(name: "IlliquidAppTests", dependencies: ["IlliquidCore", "IlliquidApp"]),
    ]
)
'''


def digest(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def snapshot(read_source) -> tuple[dict[str, bytes], dict]:
    """Read each production file once; hash exactly the bytes used for staging."""
    files, records = {}, {}
    for relative in CORE + APP:
        module = "IlliquidCore" if relative in CORE else "IlliquidApp"
        original = f"Sources/{module}/{relative}"
        raw = read_source(original)
        name = f"Sources/{module}/{Path(relative).name}"
        files[name] = raw
        records[name] = {"repository_path": original, "source_sha256": digest(raw),
                         "git_blob": hashlib.sha1(b"blob " + str(len(raw)).encode() + b"\0" + raw).hexdigest(),
                         "snapshot_sha256": digest(raw), "excerpts": []}
    for name, (relative, anchors) in EXCERPTS.items():
        original = "Sources/IlliquidApp/" + relative
        raw = read_source(original)
        source = raw.decode()
        sections = []
        for start, end in anchors:
            if source.count(start) != 1 or source.count(end) != 1:
                raise ValueError(f"Ambiguous or missing extraction boundary: {original}: {start!r}/{end!r}")
            begin, finish = source.index(start), source.index(end)
            if finish <= begin:
                raise ValueError(f"Reversed extraction boundary: {original}")
            sections.append(source[begin:finish])
        staged = ("import Foundation\nimport IlliquidCore\n\n" + "\n\n".join(sections) + "\n").encode()
        destination = "Sources/IlliquidApp/" + name
        files[destination] = staged
        records[destination] = {"repository_path": original, "source_sha256": digest(raw),
                               "git_blob": hashlib.sha1(b"blob " + str(len(raw)).encode() + b"\0" + raw).hexdigest(),
                               "snapshot_sha256": digest(staged),
                               "excerpts": [{"start": a, "end": b, "sha256": digest(s.encode())}
                                            for (a, b), s in zip(anchors, sections)]}
    return files, records


def comparison_sources(
    baseline_files, baseline_records, candidate_files, candidate_records, *,
    focal_sources, baseline_revision, worktree_head, current_support=False,
):
    """Select shared comparison inputs without allowing unequal support files.

    Historical runs retain every baseline byte. Explicit integration runs keep
    the historical focal implementations and use one current support snapshot
    for both variants. Callers still enforce their shared-source equality gate.
    """
    names = set(baseline_files)
    if names != set(candidate_files) or names != set(baseline_records) or names != set(candidate_records):
        raise ValueError("Baseline/candidate source inventories differ")
    focal_sources = set(focal_sources)
    if not focal_sources or not focal_sources <= names:
        raise ValueError("Comparison focal sources are missing from the snapshot")
    for files, records in [(baseline_files, baseline_records), (candidate_files, candidate_records)]:
        for name, raw in files.items():
            if digest(raw) != records[name]["snapshot_sha256"]:
                raise ValueError(f"Source snapshot does not match its receipt: {name}")

    baseline_files = dict(baseline_files)
    baseline_records = copy.deepcopy(baseline_records)
    candidate_records = copy.deepcopy(candidate_records)
    for name in names:
        candidate_records[name].update(
            origin="working-tree", revision=None, worktree_head=worktree_head,
            comparison_role="focal" if name in focal_sources else "support",
        )
        if current_support and name not in focal_sources:
            baseline_files[name] = candidate_files[name]
            baseline_records[name] = copy.deepcopy(candidate_records[name])
        else:
            baseline_records[name].update(
                origin="pinned-baseline", revision=baseline_revision,
                comparison_role="focal" if name in focal_sources else "support",
            )
    comparison = {
        "mode": "current-support" if current_support else "historical-strict",
        "focal_sources": sorted(focal_sources),
        "focal_baseline_revision": baseline_revision,
        "candidate_worktree_head": worktree_head,
        "working_tree_revision_note": "Working-tree revision is null: source/snapshot hashes identify the exact bytes; worktree_head identifies their checkout ancestor.",
    }
    return baseline_files, baseline_records, candidate_records, comparison


def adapt_current_sorting(raw):
    """Only bridge the pinned uncached reference to the reviewed flat projection API."""
    original = b'enum SourceTreeSorting {\n    static func sorted(\n        _ entries: [SourceTreeEntry],\n        using configuration: SourceTreeSortConfiguration\n    ) -> [SourceTreeEntry] {\n        guard entries.count > 1,\n              configuration.type != .off\n                || configuration.dateCreated != .off\n                || configuration.name != .off\n        else { return entries }\n\n        // Resolve a filename only if earlier criteria tie, and at most once\n        // per entry. A date sort with distinct dates need not read any names.\n        var names: [String?] = configuration.name == .off\n            ? [] : Array(repeating: nil, count: entries.count)\n        func name(at index: Int) -> String {\n            if let cached = names[index] { return cached }\n            let value = entries[index].url.lastPathComponent\n            names[index] = value\n            return value\n        }\n\n        // Move indices during sorting instead of complete entries and their\n        // metadata. The original index also preserves the order of full ties.\n        return entries.indices.sorted { leftIndex, rightIndex in\n            let left = entries[leftIndex], right = entries[rightIndex]\n            if configuration.type != .off, left.kind != right.kind {\n                return configuration.type == .ascending\n                    ? left.kind == .folder : left.kind == .media\n            }\n\n            if configuration.dateCreated != .off {\n                switch (left.creationDate, right.creationDate) {\n                case let (leftDate?, rightDate?) where leftDate != rightDate:\n                    return configuration.dateCreated == .ascending\n                        ? leftDate < rightDate : leftDate > rightDate\n                case (_?, nil):\n                    return true\n                case (nil, _?):\n                    return false\n                default:\n                    break\n                }\n            }\n\n            if configuration.name != .off {\n                var comparison = name(at: leftIndex).localizedStandardCompare(name(at: rightIndex))\n                if comparison == .orderedSame {\n                    comparison = left.url.path.compare(right.url.path, options: [.literal])\n                }\n                if comparison != .orderedSame {\n                    return configuration.name == .ascending\n                        ? comparison == .orderedAscending : comparison == .orderedDescending\n                }\n            }\n            return leftIndex < rightIndex\n        }.map { entries[$0] }\n    }\n}\n'
    replacement = b'enum SourceTreeSorting {\n    static func sorted(\n        _ entries: [SourceTreeEntry],\n        using configuration: SourceTreeSortConfiguration\n    ) -> [SourceTreeEntry] {\n        guard let indices = sortedIndicesIfNeeded(entries, using: configuration)\n        else { return entries }\n        return indices.map { entries[$0] }\n    }\n\n    /// Nil keeps input order without allocating a permutation for unsorted,\n    /// empty, or singleton inputs. Callers can project directly from positions.\n    static func sortedIndicesIfNeeded(\n        _ entries: [SourceTreeEntry],\n        using configuration: SourceTreeSortConfiguration\n    ) -> [Int]? {\n        guard entries.count > 1,\n              configuration.type != .off\n                || configuration.dateCreated != .off\n                || configuration.name != .off\n        else { return nil }\n\n        // Resolve a filename only if earlier criteria tie, and at most once\n        // per entry. A date sort with distinct dates need not read any names.\n        var names: [String?] = configuration.name == .off\n            ? [] : Array(repeating: nil, count: entries.count)\n        func name(at index: Int) -> String {\n            if let cached = names[index] { return cached }\n            let value = entries[index].url.lastPathComponent\n            names[index] = value\n            return value\n        }\n\n        // Move indices during sorting instead of complete entries and their\n        // metadata. The original index also preserves the order of full ties.\n        return entries.indices.sorted { leftIndex, rightIndex in\n            let left = entries[leftIndex], right = entries[rightIndex]\n            if configuration.type != .off, left.kind != right.kind {\n                return configuration.type == .ascending\n                    ? left.kind == .folder : left.kind == .media\n            }\n\n            if configuration.dateCreated != .off {\n                switch (left.creationDate, right.creationDate) {\n                case let (leftDate?, rightDate?) where leftDate != rightDate:\n                    return configuration.dateCreated == .ascending\n                        ? leftDate < rightDate : leftDate > rightDate\n                case (_?, nil):\n                    return true\n                case (nil, _?):\n                    return false\n                default:\n                    break\n                }\n            }\n\n            if configuration.name != .off {\n                var comparison = name(at: leftIndex).localizedStandardCompare(name(at: rightIndex))\n                if comparison == .orderedSame {\n                    comparison = left.url.path.compare(right.url.path, options: [.literal])\n                }\n                if comparison != .orderedSame {\n                    return configuration.name == .ascending\n                        ? comparison == .orderedAscending : comparison == .orderedDescending\n                }\n            }\n            return leftIndex < rightIndex\n        }\n    }\n}\n'
    if raw.count(original) != 1:
        raise ValueError("Historical sorting compatibility boundary changed")
    return raw.replace(original, replacement, 1)


class Runner:
    def __init__(self, args):
        self.args = args
        self.output = args.output.resolve()
        if self.output.exists() and any(self.output.iterdir()):
            raise ValueError("Output must be new or empty; previous evidence is not overwritten")
        self.output.mkdir(parents=True, exist_ok=True)
        self.env = os.environ.copy()
        cache = self.output / "module-cache"
        cache.mkdir()
        self.env.update(SWIFTPM_MODULECACHE_OVERRIDE=str(cache), CLANG_MODULE_CACHE_PATH=str(cache))
        self.swift = args.swift or shutil.which("swift")
        if not self.swift:
            raise ValueError("Swift must be on PATH, or supply --swift /path/to/swift")
        self.driver_hashes = {name: digest((HERE / name).read_bytes()) for name in ["run.py", "Harness.swift"]}
        self.packages, self.manifests, self.binaries = {}, {}, {}
        shutil.copyfile(HERE / "run.py", self.output / "runner.py")

    def execute(self, command, label: str, timeout: int = 600, allowed=(0,)) -> subprocess.CompletedProcess:
        command = [str(x) for x in command]
        started = time.monotonic()
        result = subprocess.run(command, cwd=ROOT, env=self.env, text=True,
                                capture_output=True, timeout=timeout)
        record = {"label": label, "command": command, "returncode": result.returncode,
                  "elapsed_seconds": time.monotonic() - started, "stdout": result.stdout, "stderr": result.stderr}
        with (self.output / "commands.jsonl").open("a") as log:
            log.write(json.dumps(record, sort_keys=True) + "\n")
        if result.returncode not in allowed:
            raise RuntimeError(f"{label} failed ({result.returncode}): {' '.join(command)}\n"
                               + (result.stdout + result.stderr)[-12000:])
        return result

    def prepare(self):
        head = self.execute(["git", "rev-parse", "HEAD"], "revision").stdout.strip()
        self.execute(["git", "merge-base", "--is-ancestor", BASELINE, "HEAD"], "baseline-ancestry")
        baseline_files, baseline_records = snapshot(
            lambda path: self.execute(["git", "show", f"{BASELINE}:{path}"], "baseline:" + path).stdout.encode()
        )
        candidate_files, candidate_records = snapshot(lambda name: (ROOT / name).read_bytes())
        if self.args.current_source_correctness:
            if {name: digest(raw) for name, raw in candidate_files.items()} != REVIEWED_SNAPSHOTS:
                raise ValueError("Current source differs from reviewed integration snapshots")
            if {name: record["source_sha256"] for name, record in candidate_records.items()} != REVIEWED_SOURCE_SHA256:
                raise ValueError("Current source files differ from reviewed integration source pins")
            for name, expected in REVIEWED_TESTS.items():
                if digest((ROOT / "Tests/IlliquidAppTests" / name).read_bytes()) != expected:
                    raise ValueError(f"Current regression differs from reviewed integration test: {name}")
        baseline_files, baseline_records, candidate_records, comparison = comparison_sources(
            baseline_files, baseline_records, candidate_files, candidate_records,
            focal_sources={"Sources/IlliquidApp/SourceBrowserFilter.swift",
                           "Sources/IlliquidApp/SidebarValues.swift"},
            baseline_revision=BASELINE, worktree_head=head,
            current_support=self.args.current_source_correctness,
        )
        if self.args.current_source_correctness:
            comparison["reviewed_integration_tree"] = REVIEWED_TREE
            comparison["reviewed_test_sha256"] = REVIEWED_TESTS
        for relative, raw in candidate_files.items():
            if Path(relative).name not in {"SourceBrowserFilter.swift", "SidebarValues.swift"}:
                if raw != baseline_files[relative]:
                    raise ValueError(f"Unrelated staged production dependency changed: {relative}")
        for variant, files, records in [("baseline", baseline_files, baseline_records),
                                        ("candidate", candidate_files, candidate_records)]:
            package = self.output / "packages" / variant
            manifest = {"variant": variant, "baseline_revision": BASELINE, "production": records,
                        "comparison": comparison, "staged": {}, "adaptations": []}
            staging = dict(files)
            staging["Sources/SourceTreeBenchmark/Harness.swift"] = (HERE / "Harness.swift").read_bytes()
            for name in TESTS:
                if variant == "baseline" and name == "SourceAncestorVisibilityTests.swift":
                    continue
                staging["Tests/IlliquidAppTests/" + name] = (ROOT / "Tests/IlliquidAppTests" / name).read_bytes()
            staging["Package.swift"] = PACKAGE.encode()
            for relative, raw in staging.items():
                adapted = raw
                changes = []
                if (self.args.current_source_correctness and variant == "baseline"
                        and relative == "Sources/IlliquidApp/SidebarValues.swift"):
                    adapted = adapt_current_sorting(raw)
                    changes.append("exact reviewed sorting API bridge for current flat projection; uncached ancestor reference retained")
                if platform.system() == "Linux":
                    if relative.endswith("/MediaSidecarReader.swift"):
                        if raw.count(b"import Darwin\n") != 1:
                            raise ValueError("POSIX import boundary changed")
                        adapted = raw.replace(b"import Darwin\n", b"import Glibc\n", 1)
                        changes.append("Darwin import -> Glibc")
                    elif relative.endswith("/NFOMetadataHints.swift"):
                        if raw.count(b"import Foundation\n") != 1:
                            raise ValueError("XML import boundary changed")
                        adapted = raw.replace(b"import Foundation\n", b"import Foundation\nimport FoundationXML\n", 1)
                        changes.append("add FoundationXML import")
                    elif relative.endswith("/SourceMediaOrganizationTests.swift"):
                        original = b'appendingPathComponent("media-sidecars-" + UUID().uuidString)'
                        replacement = b'appendingPathComponent("media-sidecars-" + UUID().uuidString, isDirectory: true)'
                        if raw.count(original) != 1:
                            raise ValueError("Legacy sidecar fixture directory boundary changed")
                        # This root is constructed before the directory exists.
                        # Corelibs retains its missing directory hint, unlike the
                        # file's parent URL, so the reader's root URL equality
                        # fails despite equal paths. Keep production untouched.
                        adapted = raw.replace(original, replacement, 1)
                        changes.append("explicit directory hint for sidecarsReachRowsForFoldersAndExplicitFiles fixture root")
                destination = package / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(adapted)
                manifest["staged"][relative] = {"source_sha256": digest(raw), "compiled_sha256": digest(adapted)}
                if changes:
                    manifest["adaptations"].append({"file": relative, "changes": changes})
            self.packages[variant], self.manifests[variant] = package, manifest
            write_json(self.output / f"{variant}-sources.json", manifest)
        environment = {
            "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "platform": platform.platform(), "machine": platform.machine(), "python": sys.version,
            "swift": self.execute([self.swift, "--version"], "swift-version").stdout.strip(),
            "head": head, "comparison": comparison,
            "worktree": self.execute(["git", "status", "--short"], "worktree").stdout,
            "baseline": BASELINE, "driver_hashes": self.driver_hashes,
            "sizes": self.args.sizes, "cases": self.args.cases, "pairs": self.args.pairs,
            "exploratory": self.args.smoke,
            "performance_qualified": False if self.args.current_source_correctness else None,
            "measurement": "No timing; full output differential" if self.args.current_source_correctness else "Wall and process CPU around each awaited actor.project call; fixture setup, receipt calculation and diagnostics excluded",
            "fixtures": "Synthetic grouped/interleaved/unique-parent lexical URLs; metadata prepared outside timing; no filesystem I/O during projection",
            "ordering": "AB, BA alternating per case and size; fresh process for every member",
            "target_ms": self.args.target_ms, "minimum_ms": self.args.minimum_ms,
            "runner_image_os": os.environ.get("ImageOS"), "runner_image_version": os.environ.get("ImageVersion"),
            "cold_definition": "Fresh SourceBrowserFilter instance; process and input fixture already initialized",
            "cpu_affinity": sorted(os.sched_getaffinity(0)) if hasattr(os, "sched_getaffinity") else None,
        }
        if Path("/proc/cpuinfo").exists():
            environment["cpu_model"] = next((line.split(":", 1)[1].strip() for line in
                Path("/proc/cpuinfo").read_text().splitlines() if line.startswith("model name")), "")
        write_json(self.output / "environment.json", environment)

    def check_sources(self):
        for name, expected in self.driver_hashes.items():
            if digest((HERE / name).read_bytes()) != expected:
                raise ValueError(f"Harness changed during the run: {name}")
        for variant, manifest in self.manifests.items():
            for relative, record in manifest["staged"].items():
                if digest((self.packages[variant] / relative).read_bytes()) != record["compiled_sha256"]:
                    raise ValueError(f"Staged source changed: {variant}/{relative}")

    def swift_command(self, variant, action, configuration):
        command = [self.swift, action, "--package-path", self.packages[variant],
                   "--scratch-path", self.output / "build" / variant,
                   "--cache-path", self.output / "swiftpm-cache", "--config-path", self.output / "swiftpm-config",
                   "--security-path", self.output / "swiftpm-security", "--jobs", str(self.args.jobs),
                   "--configuration", configuration]
        # The standalone Linux driver probes child PIDs through /proc; the
        # integrated driver avoids that fragile path in restricted namespaces.
        if platform.system() == "Linux":
            command.append("--use-integrated-swift-driver")
        return command

    def test(self):
        records = []
        for configuration in self.args.configurations:
            for variant in ["baseline", "candidate"]:
                self.check_sources()
                print(f"Testing {variant} ({configuration})", flush=True)
                receipt = self.output / f"tests-{variant}-{configuration}.xml"
                command = self.swift_command(variant, "test", configuration) + [
                    "--disable-xctest", "--enable-swift-testing", "--no-parallel",
                    "--xunit-output", receipt, "-Xswiftc", "-warnings-as-errors"]
                result = self.execute(command, f"tests-{variant}-{configuration}")
                (self.output / f"tests-{variant}-{configuration}.txt").write_text(result.stdout + result.stderr)
                root = ET.parse(receipt).getroot()
                cases = list(root.iter("testcase"))
                completed = [case for case in cases if case.find("skipped") is None]
                if not completed or any(case.find("failure") is not None or case.find("error") is not None for case in cases):
                    raise ValueError(f"No passing executed tests in {receipt}")
                if variant == "candidate":
                    new_test_source = (ROOT / "Tests/IlliquidAppTests/SourceAncestorVisibilityTests.swift").read_text()
                    names = re.findall(r"@Test\s+func\s+(\w+)", new_test_source)
                    executed_xml = "\n".join(ET.tostring(case, encoding="unicode") for case in completed)
                    if len(names) != 8 or not all(name in executed_xml for name in names):
                        raise ValueError("All eight ancestor regressions must execute")
                records.append({"variant": variant, "configuration": configuration, "passed": True,
                                "executed": len(completed), "skipped": len(cases) - len(completed),
                                "junit_sha256": digest(receipt.read_bytes())})
        write_json(self.output / "tests.json", {"suites": TESTS, "runs": records})
        self.check_sources()

    def build(self):
        for variant in ["baseline", "candidate"]:
            print(f"Building {variant} benchmark (release)", flush=True)
            command = self.swift_command(variant, "build", "release")
            self.execute(command + ["--product", "SourceTreeBenchmark"], f"build-{variant}")
            bin_path = self.execute(command + ["--show-bin-path"], f"bin-path-{variant}").stdout.strip()
            self.binaries[variant] = Path(bin_path) / "SourceTreeBenchmark"
            self.manifests[variant]["binary_sha256"] = digest(self.binaries[variant].read_bytes())
            write_json(self.output / f"{variant}-sources.json", self.manifests[variant])
        self.check_sources()

    def measurement(self, variant, case, size, iterations, label):
        result = self.execute([self.binaries[variant], "measure", case, size, iterations], label)
        data = json.loads(result.stdout)
        if (data["case"], data["size"], data["iterations"]) != (case, size, iterations):
            raise ValueError("Unexpected measured workload")
        for total, samples in [("elapsed_ns", "durations_ns"), ("cpu_ns", "cpu_durations_ns")]:
            if len(data[samples]) != iterations or any(type(n) is not int or n < 0 for n in data[samples]):
                raise ValueError(f"Invalid {samples}")
            if data[total] != sum(data[samples]):
                raise ValueError(f"Inconsistent {total}")
        if len(data["receipts"]) != iterations or data["receipts"] != data["receipts"][:2] * (iterations // 2):
            raise ValueError("Projection output changed within a repeated two-state cycle")
        return data

    def measure(self):
        rows, summary, pilots = [], [], []
        for size in self.args.sizes:
            for case in self.args.cases:
                expected = None
                for variant in ("baseline", "candidate"):
                    result = self.execute([self.binaries[variant], "diagnose", case, size, 2],
                                          f"diagnose-{variant}-{case}-{size}")
                    data = json.loads(result.stdout)
                    if data["tree_build_count"] != 1 or data["visibility_build_count"] != 3:
                        raise ValueError("Diagnostic must rebuild visibility twice while reusing one tree")
                    if expected is not None and data["receipts"] != expected:
                        raise ValueError(f"Diagnostic projection differs: {case}/{size}")
                    expected = data["receipts"]
                    data.update(variant=variant)
                    with (self.output / "diagnostics.jsonl").open("a") as log:
                        log.write(json.dumps(data, sort_keys=True) + "\n")
                iterations = self.args.iterations or 2
                if self.args.iterations is None:
                    for attempt in range(6):
                        elapsed = []
                        for variant in ("baseline", "candidate"):
                            pilot = self.measurement(variant, case, size, iterations,
                                                     f"pilot-{variant}-{case}-{size}-{attempt}")
                            if pilot["receipts"][:2] != expected:
                                raise ValueError("Calibration output mismatch")
                            pilot.update(variant=variant, attempt=attempt)
                            pilots.append(pilot)
                            elapsed.append(min(pilot["elapsed_ns"], pilot["cpu_ns"]))
                        write_json(self.output / "calibration.json", pilots)
                        fastest = min(elapsed)
                        if fastest >= self.args.target_ms * 1_000_000:
                            break
                        iterations = max(iterations + 2, math.ceil(
                            iterations * self.args.target_ms * 1_000_000 * 1.2 / max(fastest, 1) / 2) * 2)
                        if iterations > 100_000:
                            raise ValueError("Unexpected calibration count")
                    else:
                        raise ValueError("Calibration did not reach the duration target")
                pairs = []
                for pair in range(self.args.pairs):
                    order = ["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]
                    values = {}
                    for position, variant in enumerate(order):
                        data = self.measurement(variant, case, size, iterations,
                                                f"measure-{variant}-{case}-{size}-{pair}")
                        if data["receipts"][:2] != expected:
                            raise ValueError(f"Timed projection differs: {case}/{size}")
                        data.update(variant=variant, pair=pair, process_order=position)
                        rows.append(data)
                        values[variant] = data
                        with (self.output / "measurements.jsonl").open("a") as log:
                            log.write(json.dumps(data, sort_keys=True) + "\n")
                    pairs.append(values)
                record = {"case": case, "size": size, "pairs": self.args.pairs, "iterations": iterations}
                for metric, field in (("wall", "elapsed_ns"), ("cpu", "cpu_ns")):
                    normalized = {v: [p[v][field] / iterations for p in pairs] for v in ("baseline", "candidate")}
                    ratios = [p["candidate"][field] / p["baseline"][field] for p in pairs]
                    record[metric] = {
                        "baseline_ns": {"median": statistics.median(normalized["baseline"]), "min": min(normalized["baseline"]), "max": max(normalized["baseline"])},
                        "candidate_ns": {"median": statistics.median(normalized["candidate"]), "min": min(normalized["candidate"]), "max": max(normalized["candidate"])},
                        "paired_ratios": ratios,
                        "median_paired_reduction_percent": 100 * (1 - statistics.median(ratios)),
                    }
                summary.append(record)
                write_json(self.output / "summary.json", summary)
                print(f"{case}, {size} rows: {record['wall']['median_paired_reduction_percent']:.1f}% wall reduction", flush=True)
        short = [row for row in rows if min(row["elapsed_ns"], row["cpu_ns"]) < self.args.minimum_ms * 1_000_000]
        completion = {
            "complete": False, "cases": self.args.cases, "sizes": self.args.sizes,
            "mode": self.args.mode, "exploratory": self.args.smoke,
            "pairs": self.args.pairs, "expected_observations": len(self.args.cases) * len(self.args.sizes) * self.args.pairs * 2,
            "actual_observations": len(rows), "observations_under_minimum": len(short),
            "minimum_required_ms": self.args.minimum_ms,
        }
        write_json(self.output / "completion.json", completion)
        if short:
            raise ValueError("Short observations retained; rerun a new cohort with a larger target")
        self.check_sources()
        for variant, binary in self.binaries.items():
            if digest(binary.read_bytes()) != self.manifests[variant]["binary_sha256"]:
                raise ValueError(f"Benchmark binary changed: {variant}")
        completion.update(complete=True, source_integrity_passed=True,
                          tests_executed=self.args.mode == "all")
        write_json(self.output / "completion.json", completion)

    def correctness(self):
        """Compare lossless JSON of every output field, with no projection timing."""
        observations = []
        for size in self.args.sizes:
            for case in self.args.cases:
                outputs = {}
                for variant in ("baseline", "candidate"):
                    result = self.execute([self.binaries[variant], "correctness", case, size, 2],
                                          f"correctness-{variant}-{case}-{size}")
                    data = json.loads(result.stdout)
                    if (data["case"], data["size"], data["iterations"]) != (case, size, 2):
                        raise ValueError("Unexpected correctness workload")
                    if data["tree_build_count"] != 1 or data["visibility_build_count"] != 3:
                        raise ValueError("Correctness must rebuild visibility twice and reuse one tree")
                    if len(data["outputs"]) != 2:
                        raise ValueError("Both complete projection states are required")
                    write_json(self.output / f"full-output-{variant}-{case}-{size}.json", data)
                    outputs[variant] = data
                if outputs["baseline"] != outputs["candidate"]:
                    raise ValueError(f"Complete projection differs: {case}/{size}")
                observations.append({"case": case, "size": size, "states": 2, "equal": True})
        self.check_sources()
        for variant, binary in self.binaries.items():
            if digest(binary.read_bytes()) != self.manifests[variant]["binary_sha256"]:
                raise ValueError(f"Benchmark binary changed: {variant}")
        write_json(self.output / "completion.json", {
            "complete": True, "mode": "current-source-correctness",
            "tests_executed": True, "source_integrity_passed": True,
            "performance_qualified": False, "observations": observations,
        })

    def export_evidence(self):
        """Keep an uploadable receipt without compiler caches or build products."""
        evidence = self.output / "evidence"
        evidence.mkdir(exist_ok=True)
        for source in self.output.iterdir():
            if source.is_file() and source.suffix in {".json", ".jsonl", ".txt", ".py", ".xml"}:
                shutil.copyfile(source, evidence / source.name)
        packages = self.output / "packages"
        if packages.exists():
            with tarfile.open(evidence / "staged-sources.tar.gz", "w:gz") as archive:
                for source in sorted(packages.rglob("*")):
                    if source.is_file():
                        archive.add(source, arcname=str(source.relative_to(packages)), recursive=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--mode", choices=["all", "test", "benchmark", "build"], default="all")
    parser.add_argument("--current-source-correctness", action="store_true",
                        help="shared current support; full regressions and lossless output differential, no timing")
    parser.add_argument("--swift")
    parser.add_argument("--jobs", type=int, default=1)
    parser.add_argument("--pairs", "--samples", dest="pairs", type=int, default=6)
    parser.add_argument("--tests-only", action="store_true", help="alias for --mode test")
    parser.add_argument("--sizes", type=int, nargs="+", default=[100, 1000, 10000])
    parser.add_argument("--case", dest="cases", action="append", choices=CASES)
    parser.add_argument("--iterations", type=int)
    parser.add_argument("--target-ms", type=float, default=120)
    parser.add_argument("--minimum-ms", type=float, default=40)
    parser.add_argument("--configuration", dest="configurations", action="append", choices=["debug", "release"])
    parser.add_argument("--smoke", action="store_true", help="allow fewer pairs; results are exploratory")
    args = parser.parse_args()
    if args.tests_only:
        args.mode = "test"
    args.cases = args.cases or CASES
    args.configurations = args.configurations or ["debug", "release"]
    if args.jobs < 1 or args.pairs < 1 or (not args.smoke and (args.pairs < 6 or args.pairs % 2)):
        parser.error("Use positive jobs and an even number of at least six pairs; --smoke permits fewer")
    if any(size not in [100, 1000, 10000, 100000] for size in args.sizes):
        parser.error("Supported sizes are 100, 1000, 10000, 100000")
    if args.iterations is not None and (args.iterations < 2 or args.iterations % 2):
        parser.error("Iterations must be even and at least two so both toggle states are measured")
    if args.minimum_ms < 40 or args.target_ms < args.minimum_ms:
        parser.error("Target must reach the minimum, with at least 40 ms per observation")
    if args.current_source_correctness and (args.mode != "all" or args.smoke
            or args.cases != CASES or args.sizes != [100, 1000, 10000]
            or args.configurations != ["debug", "release"]):
        parser.error("Current-source correctness requires all regressions, default cases/sizes and debug/release")
    runner = Runner(args)
    try:
        runner.prepare()
        if args.mode in {"all", "test"}:
            runner.test()
        if args.mode in {"all", "benchmark", "build"}:
            runner.build()
        if args.current_source_correctness:
            runner.correctness()
        elif args.mode in {"all", "benchmark"}:
            runner.measure()
    finally:
        runner.export_evidence()


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"Source tree qualification failed: {error}", file=sys.stderr)
        sys.exit(1)
