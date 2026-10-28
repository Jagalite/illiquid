#!/usr/bin/env python3
"""Measure source-local Metal pool ownership using complete production renderer sources."""

from __future__ import annotations

import argparse
import hashlib
import json
import platform
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
COMPOSITOR = "Sources/IlliquidNativePlayback/Subtitles/MetalASSSubtitleCompositor.swift"
SHARED = [
    "Sources/IlliquidNativePlayback/Subtitles/SubtitleMemoryBudget.swift",
    "Sources/IlliquidNativePlayback/Presentation/NativeMetalShaderLibrary.swift",
    "Sources/IlliquidNativePlayback/Resources/NativePlaybackShaders.metal",
    "Sources/IlliquidNativePlayback/Subtitles/LibassContext.swift",
]
TESTS = [
    "Tests/IlliquidNativePlaybackTests/SubtitleGPUResourcePoolTests.swift",
    "Tests/IlliquidNativePlaybackTests/SubtitleGPUResourceMetalTests.swift",
]


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def declaration(source: str, anchor: str) -> str:
    if source.count(anchor) != 1:
        raise ValueError(f"Expected one declaration: {anchor}")
    start = source.index(anchor)
    opening = source.index("{", start)
    depth = 1
    for index in range(opening + 1, len(source)):
        depth += (source[index] == "{") - (source[index] == "}")
        if depth == 0:
            return source[start:index + 1]
    raise ValueError(f"Unterminated declaration: {anchor}")


def once(source: str, old: str, new: str) -> str:
    if source.count(old) != 1:
        raise ValueError(f"Baseline instrumentation anchor changed: {old[:100]}")
    return source.replace(old, new, 1)


def observe_baseline(source: str) -> str:
    # Widen test visibility and add read-only accounting. Original acquire,
    # release, upload and draw bodies remain byte-for-byte intact. Retirement
    # is a no-op because the pinned production renderer has no such operation.
    source = once(source, "private final class FrameResources:", "final class FrameResources:")
    old = declaration(source, "private final class ResourcePool:")
    observed = old.replace("private final class ResourcePool:", "final class ResourcePool:", 1)
    observed = observed[:-1] + """
        struct Snapshot {
            let sourceGeneration: UInt64
            let idleResourceCount: Int
            let idleTextureBytes: Int
            let idleVertexBufferBytes: Int
        }

        func snapshotForTesting() -> Snapshot {
            lock.withLock {
                Snapshot(
                    sourceGeneration: 0,
                    idleResourceCount: available.count,
                    idleTextureBytes: available.reduce(0) { $0 + ($1.texture?.allocatedSize ?? 0) },
                    idleVertexBufferBytes: available.reduce(0) { $0 + ($1.vertexBuffer?.allocatedSize ?? 0) }
                )
            }
        }
    }"""
    source = once(source, old, observed)
    return once(source, "    func draw(\n", """    func retireSourceResources() {}

    var resourcePoolSnapshotForTesting: ResourcePool.Snapshot {
        resourcePool.snapshotForTesting()
    }

    func draw(
""")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("A native macOS Metal device is required; no emulated memory results.")
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("Choose an empty output directory; retained evidence is never overwritten.")
    output.mkdir(parents=True, exist_ok=True)

    def command(argv: list[str], label: str) -> str:
        result = subprocess.run(argv, cwd=ROOT, text=True, capture_output=True)
        log = result.stdout + result.stderr
        (output / f"{label}.log").write_text(log)
        with (output / "commands.jsonl").open("a") as stream:
            stream.write(json.dumps({"command": argv, "label": label, "returncode": result.returncode,
                                     "log_sha256": sha(log.encode())}, sort_keys=True) + "\n")
        if result.returncode:
            raise RuntimeError(f"{label} failed ({result.returncode}):\n{log[-12000:]}")
        return result.stdout

    def historical(path: str) -> bytes:
        return subprocess.check_output(["git", "show", f"{BASELINE}:{path}"], cwd=ROOT)

    write_json(output / "environment.json", {
        "system": command(["sw_vers"], "system"),
        "machine": platform.machine(),
        "swift": command(["xcrun", "swiftc", "--version"], "swift-version"),
        "sdk": command(["xcrun", "--sdk", "macosx", "--show-sdk-version"], "sdk-version"),
        "head": command(["git", "rev-parse", "HEAD"], "revision").strip(),
        "baseline": BASELINE,
    })
    source_receipt = {"baseline": BASELINE, "inputs_sha256": {}, "baseline_observation_only": True}
    baseline = historical(COMPOSITOR)
    candidate = (ROOT / COMPOSITOR).read_bytes()
    source_receipt["inputs_sha256"]["baseline/" + COMPOSITOR] = sha(baseline)
    source_receipt["inputs_sha256"]["candidate/" + COMPOSITOR] = sha(candidate)
    shared = {}
    for path in SHARED:
        contents = (ROOT / path).read_bytes()
        if contents != historical(path):
            raise ValueError(f"Shared dependency differs from pinned baseline: {path}")
        shared[path] = contents
        source_receipt["inputs_sha256"][path] = sha(contents)
    for path in [*TESTS, str(HERE.relative_to(ROOT) / "Probe.swift"),
                 str(Path(__file__).relative_to(ROOT))]:
        source_receipt["inputs_sha256"][path] = sha((ROOT / path).read_bytes())

    observed_baseline = observe_baseline(baseline.decode()).encode()
    source_receipt["instrumented_baseline_sha256"] = sha(observed_baseline)
    region = declaration(
        shared[SHARED[-1]].decode(), "struct ASSRenderedRegion: Sendable {"
    )
    source_receipt["rendered_region_declaration_sha256"] = sha(region.encode())
    packages = {}
    for variant, renderer in (("baseline", observed_baseline), ("candidate", candidate)):
        package = output / variant
        native = package / "Sources/IlliquidNativePlayback"
        resources = native / "Resources"
        probe = package / "Sources/SubtitleGPUMemoryProbe"
        resources.mkdir(parents=True)
        probe.mkdir(parents=True)
        (native / "MetalASSSubtitleCompositor.swift").write_bytes(renderer)
        (native / "SubtitleMemoryBudget.swift").write_bytes(shared[SHARED[0]])
        (native / "NativeMetalShaderLibrary.swift").write_bytes(shared[SHARED[1]])
        (resources / "NativePlaybackShaders.metal").write_bytes(shared[SHARED[2]])
        (native / "ASSRenderedRegion.swift").write_text("import CoreGraphics\nimport Foundation\n\n" + region + "\n")
        shutil.copyfile(HERE / "Probe.swift", probe / "Probe.swift")
        test_target = ""
        if variant == "candidate":
            tests = package / "Tests/IlliquidNativePlaybackTests"
            tests.mkdir(parents=True)
            for path in TESTS:
                shutil.copyfile(ROOT / path, tests / Path(path).name)
            test_target = '.testTarget(name: "IlliquidNativePlaybackTests", dependencies: ["IlliquidNativePlayback"]),'
        (package / "Package.swift").write_text("""// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "SubtitleGPUResourceQualification",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "IlliquidNativePlayback", resources: [.process("Resources")]),
        .executableTarget(name: "SubtitleGPUMemoryProbe", dependencies: ["IlliquidNativePlayback"]),
        """ + test_target + """
    ]
)
""")
        packages[variant] = package
    write_json(output / "source-receipt.json", source_receipt)

    for configuration in ("debug", "release"):
        command([
            "swift", "test", "--package-path", str(packages["candidate"]),
            "-c", configuration, "--no-parallel", "--jobs", "2",
            "-Xswiftc", "-enable-testing", "-Xswiftc", "-warnings-as-errors",
        ], f"candidate-tests-{configuration}")
        print(f"PASS candidate component tests ({configuration})", flush=True)

    measurements = {}
    for variant, package in packages.items():
        arguments = [
            "swift", "build", "--package-path", str(package), "-c", "release",
            "--product", "SubtitleGPUMemoryProbe", "--jobs", "2",
            "-Xswiftc", "-enable-testing", "-Xswiftc", "-warnings-as-errors",
        ]
        command(arguments, f"{variant}-build")
        directory = command([
            "swift", "build", "--package-path", str(package), "-c", "release", "--show-bin-path",
        ], f"{variant}-binary-path").strip()
        binary = Path(directory) / "SubtitleGPUMemoryProbe"
        measurements[variant] = json.loads(command([str(binary)], f"{variant}-probe"))
        write_json(output / f"{variant}-memory.json", measurements[variant])

    if len(measurements["baseline"]) != 2 or len(measurements["candidate"]) != 2:
        raise ValueError("Both R8 and BGRA measurements are required.")
    for old, new in zip(measurements["baseline"], measurements["candidate"], strict=True):
        for field in ("format", "atlas_width", "atlas_height", "quad_count", "initial_pixels_sha256",
                      "rebuilt_pixels_sha256", "following_pixels_sha256", "pixel_bytes"):
            if old[field] != new[field]:
                raise ValueError(f"Baseline/candidate output differs: {field}")
        for row in (old, new):
            if row["before"]["idle_resources"] != 1 or row["before"]["texture_allocated_bytes"] <= 0:
                raise ValueError("Probe did not populate actual Metal resources.")
            if row["before"] != row["ordinary_gap"]:
                raise ValueError("Ordinary subtitle gaps must preserve resource reuse.")
        if old["before"] != old["retired"]:
            raise ValueError("Baseline observation unexpectedly changed resource ownership.")
        if any(new["retired"][key] != 0 for key in
               ("idle_resources", "texture_allocated_bytes", "vertex_buffer_allocated_bytes")):
            raise ValueError("Candidate retained idle resources after source retirement.")
        for key in ("texture_allocated_bytes", "vertex_buffer_allocated_bytes"):
            if not 0 < new["following_small_source"][key] < old["following_small_source"][key]:
                raise ValueError(f"Small following source did not reduce retained capacity: {key}")

    write_json(output / "summary.json", {
        "qualification": "passed",
        "metric": "Idle pool-owned Metal resource allocatedSize bytes; not RSS or driver reclamation.",
        "baseline": BASELINE,
        "measurements": measurements,
        "pixel_parity": True,
        "candidate_configurations": ["debug", "release"],
        "scope": "Component renderer and pool; authority integration is a separate native test job.",
    })
    print((output / "summary.json").read_text(), flush=True)


if __name__ == "__main__":
    main()
