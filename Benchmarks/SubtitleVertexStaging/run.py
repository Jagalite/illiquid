#!/usr/bin/env python3
"""Qualify the actual subtitle vertex upload methods on native macOS Metal."""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import platform
import shutil
import statistics
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
COMPOSITOR = ROOT / "Sources/IlliquidNativePlayback/Subtitles/MetalASSSubtitleCompositor.swift"
WRITER = ROOT / "Sources/IlliquidNativePlayback/Subtitles/ASSSubtitleVertexWriter.swift"
TEST = ROOT / "Tests/IlliquidNativePlaybackTests/SubtitleVertexWriterTests.swift"
CASES = [f"quads-{count}-{mode}" for count in (1, 8, 64, 256) for mode in ("edges", "centers")]
CASES += ["varying-edges", "varying-centers"]


def digest(data: bytes | str) -> str:
    return hashlib.sha256(data.encode() if isinstance(data, str) else data).hexdigest()


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def append_json(path: Path, value: object) -> None:
    with path.open("a") as stream:
        stream.write(json.dumps(value, sort_keys=True) + "\n")


def command(args: list[str | Path], output: Path, timeout: int = 300) -> str:
    args = [str(arg) for arg in args]
    started = time.monotonic()
    result = subprocess.run(args, cwd=ROOT, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=timeout)
    append_json(output / "commands.jsonl", {"command": args, "returncode": result.returncode,
                                           "elapsed_seconds": time.monotonic() - started})
    if result.returncode:
        (output / "failure.log").write_text(result.stdout)
        raise RuntimeError(f"Command failed: {args!r}\n{result.stdout[-16000:]}")
    return result.stdout


def block(source: str, anchor: str) -> str:
    if source.count(anchor) != 1:
        raise ValueError(f"Expected one declaration: {anchor!r}")
    start = source.index(anchor)
    opening = source.index("{", start)
    depth = 1
    for offset in range(opening + 1, len(source)):
        depth += (source[offset] == "{") - (source[offset] == "}")
        if depth == 0:
            return source[start:offset + 1]
    raise ValueError(f"Unterminated declaration: {anchor!r}")


def shared_types(source: str) -> str:
    boundary = "/// CPU preparation shared by the Metal overlay and the correctness harness."
    if source.count(boundary) != 1:
        raise ValueError("Shared type boundary changed")
    return source[:source.index(boundary)]


def adapter(source: str, variant: str) -> str:
    if variant == "baseline":
        resources = block(source, "    private final class FrameResources:")
        resource_initializer = "FrameResources()"
    elif variant == "candidate":
        resources = block(source, "    final class FrameResources: @unchecked Sendable {")
        # Keep the complete production declaration unchanged. This isolated
        # upload adapter owns one resource for its entire lifetime, generation 0.
        expected_initializer = """        init(sourceGeneration: UInt64) {
            self.sourceGeneration = sourceGeneration
        }"""
        if (resources.count("        let sourceGeneration: UInt64\n") != 1
                or block(resources, "        init(sourceGeneration: UInt64) {") != expected_initializer):
            raise ValueError("Candidate resource generation initializer changed")
        resource_initializer = "FrameResources(sourceGeneration: 0)"
    else:
        raise ValueError(f"Unknown adapter variant: {variant!r}")
    upload = block(source, "    private func uploadVertices(")
    if variant == "baseline":
        vertex = block(source, "    private struct Vertex {")
        make = block(source, "    private func makeVertices(")
        invoke = """        let vertices = makeVertices(frame, texture: texture, targetSize: targetSize)
        precondition(uploadVertices(vertices, resources: resources))
        let count = vertices.count
"""
    else:
        vertex = "    private typealias Vertex = ASSSubtitleVertexWriter.Vertex"
        if vertex not in source:
            raise ValueError("Candidate vertex alias changed")
        make = ""
        invoke = """        guard let count = uploadVertices(frame, texture: texture, targetSize: targetSize,
                                                resources: resources) else {
            preconditionFailure("Vertex buffer allocation failed")
        }
"""
    header = """import CoreGraphics
import Foundation
import Metal

struct VertexUploadRecord: Encodable, Equatable {
    let x: UInt32
    let y: UInt32
    let u: UInt32
    let v: UInt32
    let rgba: UInt32
}

@MainActor
final class VertexUploadHarness {
"""
    fields = """
    private let device: any MTLDevice
    private let configuration: MetalASSRenderConfiguration
    private let resources = """ + resource_initializer + """
    private var synchronousFailure: MetalASSFailureReason?
    private var bufferAllocationFailures = 0

    init(device: any MTLDevice, configuration: MetalASSRenderConfiguration) {
        self.device = device
        self.configuration = configuration
    }

    var capacity: Int { resources.vertexCapacity }
    var vertexStride: Int { MemoryLayout<Vertex>.stride }

    func encode(_ frame: ASSPreparedSubtitleFrame, texture: any MTLTexture, targetSize: CGSize) -> UInt64 {
"""
    finish = """        let last = record(at: count - 1)
        return UInt64(last.x) &+ UInt64(last.y) &+ UInt64(last.u)
            &+ UInt64(last.v) &+ UInt64(last.rgba) &+ UInt64(count)
    }

    func records(count: Int) -> [VertexUploadRecord] {
        (0..<count).map { record(at: $0) }
    }

    private func record(at index: Int) -> VertexUploadRecord {
        let vertex = resources.vertexBuffer!.contents().load(
            fromByteOffset: index * MemoryLayout<Vertex>.stride, as: Vertex.self)
        let rgba = (UInt32(vertex.color.x) << 24) | (UInt32(vertex.color.y) << 16)
            | (UInt32(vertex.color.z) << 8) | UInt32(vertex.color.w)
        return VertexUploadRecord(x: vertex.position.x.bitPattern, y: vertex.position.y.bitPattern,
                                  u: vertex.textureCoordinate.x.bitPattern, v: vertex.textureCoordinate.y.bitPattern,
                                  rgba: rgba)
    }
"""
    result = header + vertex + "\n" + resources + fields + invoke + finish + make + "\n" + upload + "\n}\n"
    if upload not in result or resources not in result or (make and make not in result):
        raise ValueError("Source extraction changed bytes")
    return result


def prepare_sources(variant: str, destination: Path, output: Path) -> list[Path]:
    destination.mkdir(parents=True, exist_ok=True)
    baseline = (HERE / "baseline/MetalASSSubtitleCompositor.swift").read_text()
    current = COMPOSITOR.read_text()
    if shared_types(baseline) != shared_types(current):
        raise ValueError("Shared renderer types differ from the frozen baseline")
    source = baseline if variant == "baseline" else current
    files = {"Types.swift": shared_types(source), "Adapter.swift": adapter(source, variant)}
    if variant == "candidate":
        files["ASSSubtitleVertexWriter.swift"] = WRITER.read_text()
    paths = []
    for name, content in files.items():
        path = destination / name
        path.write_text(content)
        paths.append(path)
    write_json(output / f"{destination.parent.name}-sources.json",
               {name: {"sha256": digest(content), "content": content} for name, content in files.items()})
    return paths


def build(variant: str, configuration: str, output: Path) -> Path:
    destination = output / "build" / f"{variant}-{configuration}"
    destination.mkdir(parents=True, exist_ok=True)
    sources = prepare_sources(variant, destination / "sources", output)
    flags = ["-swift-version", "6", "-warnings-as-errors", "-O" if configuration == "release" else "-Onone"]
    if configuration == "release":
        flags.append("-whole-module-optimization")
    library = destination / "libIlliquidNativePlayback.dylib"
    command(["swiftc", *flags, "-enable-testing", "-emit-library", "-emit-module",
             "-module-name", "IlliquidNativePlayback", "-emit-module-path",
             destination / "IlliquidNativePlayback.swiftmodule", *sources, "-o", library], output)
    executable = destination / "benchmark"
    command(["swiftc", *flags, "-parse-as-library", "-I", destination, "-L", destination,
             "-lIlliquidNativePlayback", "-Xlinker", "-rpath", "-Xlinker", destination,
             HERE / "Harness.swift", "-o", executable], output)
    return executable


def unit_tests(output: Path) -> None:
    package = output / "build/writer-tests"
    source = package / "Sources/IlliquidNativePlayback"
    tests = package / "Tests/IlliquidNativePlaybackTests"
    source.mkdir(parents=True)
    tests.mkdir(parents=True)
    (source / "Types.swift").write_text(shared_types(COMPOSITOR.read_text()))
    shutil.copyfile(WRITER, source / WRITER.name)
    shutil.copyfile(TEST, tests / TEST.name)
    (package / "Package.swift").write_text("""// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "SubtitleVertexStagingTests", platforms: [.macOS("26.0")],
    targets: [
        .target(name: "IlliquidNativePlayback"),
        .testTarget(name: "IlliquidNativePlaybackTests", dependencies: ["IlliquidNativePlayback"]),
    ])
""")
    for configuration in ("debug", "release"):
        log = command(["swift", "test", "--package-path", package, "--jobs", "2", "--no-parallel",
                       "-c", configuration, "-Xswiftc", "-warnings-as-errors"], output, timeout=600)
        (output / f"writer-{configuration}-tests.log").write_text(log)
    log = command(["swift", "test", "--package-path", package, "--jobs", "2", "--no-parallel",
                   "--sanitize", "address"], output, timeout=600)
    (output / "writer-address-sanitizer-tests.log").write_text(log)


def measure(executable: Path, case: str, iterations: int, seed: int, output: Path) -> dict:
    record = json.loads(command([executable, case, str(iterations), str(seed)], output, timeout=120))
    if record["case"] != case or record["iterations"] != iterations or record["seed"] != seed:
        raise RuntimeError("Driver command/receipt mismatch")
    if record["elapsed_ns"] <= 0 or record["operations_per_iteration"] < 1:
        raise RuntimeError("Invalid driver timing")
    receipt = record.pop("receipt")
    record["receipt_sha256"] = digest(json.dumps(receipt, sort_keys=True, separators=(",", ":")))
    receipts = output / "receipts"
    receipts.mkdir(exist_ok=True)
    write_json(receipts / f"{executable.parent.name}-{case}-{seed}.json", receipt)
    record["ns_per_iteration"] = record["elapsed_ns"] / iterations
    record["ns_per_operation"] = record["elapsed_ns"] / (iterations * record["operations_per_iteration"])
    return record


def summarize(records: list[dict]) -> dict:
    result = {}
    for case in dict.fromkeys(row["case"] for row in records):
        rows = [row for row in records if row["case"] == case]
        summary = {}
        for variant in ("baseline", "candidate"):
            times = [row["ns_per_operation"] for row in rows if row["variant"] == variant]
            summary[variant] = {"median_ns": statistics.median(times), "min_ns": min(times), "max_ns": max(times)}
        reductions = []
        for pair in sorted({row["pair"] for row in rows}):
            values = {row["variant"]: row for row in rows if row["pair"] == pair}
            for field in ("receipt_sha256", "checksum", "seed", "iterations", "operations_per_iteration",
                          "vertex_payload_bytes_per_iteration"):
                if values["baseline"][field] != values["candidate"][field]:
                    raise RuntimeError(f"Pair mismatch: {case}/{pair}/{field}")
            reductions.append(100 * (1 - values["candidate"]["ns_per_operation"]
                                      / values["baseline"]["ns_per_operation"]))
        summary["paired_reduction_percent"] = {
            "median": statistics.median(reductions), "min": min(reductions), "max": max(reductions),
            "candidate_faster_pairs": sum(value > 0 for value in reductions), "pairs": len(reductions)}
        result[case] = summary
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--tests-only", action="store_true")
    parser.add_argument("--pairs", type=int, default=8)
    parser.add_argument("--target-ms", type=float, default=80)
    args = parser.parse_args()
    if sys.platform != "darwin" or args.pairs < 2 or args.pairs % 2 or args.target_ms <= 0:
        parser.error("Requires macOS, an even pair count >= 2, and a positive target duration")
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("Use an empty output directory")
    output.mkdir(parents=True, exist_ok=True)
    baseline = json.loads((HERE / "baseline/manifest.json").read_text())
    if digest((HERE / "baseline/MetalASSSubtitleCompositor.swift").read_bytes()) != baseline["sha256"]:
        raise RuntimeError("Frozen baseline hash mismatch")
    manifest = {
        "collected_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "platform": platform.platform(), "machine": platform.machine(),
        "swift": command(["swiftc", "--version"], output).strip(),
        "hardware": command(["sysctl", "hw.model", "machdep.cpu.brand_string"], output).strip(),
        "git_head": command(["git", "rev-parse", "HEAD"], output).strip(),
        "git_status": command(["git", "status", "--porcelain"], output).strip(),
        "baseline": baseline, "arguments": {**vars(args), "output": str(output)},
        "sources": {str(path.relative_to(ROOT)): digest(path.read_bytes())
                    for path in (COMPOSITOR, WRITER, TEST, HERE / "Harness.swift", HERE / "run.py")},
        "extraction": "Complete original Vertex/FrameResources/makeVertices/uploadVertices declarations "
                      "or candidate FrameResources/uploadVertices plus complete writer; shared declarations "
                      "unchanged. Thin adapter supplies a real Metal device/configuration, retains buffers "
                      "and reads logical vertex fields after upload. No shader, encoder or command buffer is timed.",
        "method": "Separate Swift modules; real shared Metal buffers; warm capacity; same-iteration "
                  "fresh-process AB/BA pairs; complete field/Float-bit parity, consumed checksums; "
                  "no discarded timing samples and no control subtraction.",
    }
    write_json(output / "manifest.json", manifest)
    try:
        if args.tests_only:
            tests = {}
            for configuration in ("debug", "release"):
                for variant in ("baseline", "candidate"):
                    executable = build(variant, configuration, output)
                    for case in CASES:
                        measure(executable, case, 1, 42, output)
                    tests[f"{variant}_{configuration}_upload_harness"] = "passed"
            unit_tests(output)
            tests.update(writer_debug="passed", writer_release="passed", writer_address_sanitizer="passed")
            write_json(output / "tests.json", tests)
            print(json.dumps(tests, sort_keys=True), flush=True)
            return
        executables = {variant: build(variant, "release", output) for variant in ("baseline", "candidate")}
        manifest["binaries"] = {
            variant: {path.name: digest(path.read_bytes()) for path in executable.parent.iterdir()
                      if path.is_file() and (path.name == "benchmark" or path.suffix == ".dylib")}
            for variant, executable in executables.items()}
        write_json(output / "manifest.json", manifest)
        records = []
        for case in CASES:
            calibration = {}
            for variant, executable in executables.items():
                first = measure(executable, case, 1, 1000, output)
                count = max(1, min(10000, math.ceil(20_000_000 / first["elapsed_ns"])))
                probe = measure(executable, case, count, 1000, output)
                calibration[variant] = probe["ns_per_iteration"]
                append_json(output / "calibration.jsonl", {"variant": variant, "stage": "single", **first})
                append_json(output / "calibration.jsonl", {"variant": variant, "stage": "probe", **probe})
            iterations = max(1, min(math.ceil(args.target_ms * 1e6 / min(calibration.values())),
                                    math.floor(1_500_000_000 / max(calibration.values()))))
            for pair in range(args.pairs):
                order = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
                for position, variant in enumerate(order):
                    record = measure(executables[variant], case, iterations, 2000 + pair, output)
                    record.update(variant=variant, pair=pair, position=position)
                    records.append(record)
                    append_json(output / "measurements.jsonl", record)
                summarize(records[-2:])
            write_json(output / "summary.json", summarize(records))
            print(case, json.dumps(summarize(records)[case], sort_keys=True), flush=True)
        write_json(output / "verification.json", {"all_pairs_equal": True, "cases": len(CASES),
                                                  "records": len(records), "pairs_per_case": args.pairs})
    except Exception as error:
        write_json(output / "failure.json", {"type": type(error).__name__, "message": str(error)})
        raise
    finally:
        if (output / "build").exists():
            shutil.rmtree(output / "build")


if __name__ == "__main__":
    main()
