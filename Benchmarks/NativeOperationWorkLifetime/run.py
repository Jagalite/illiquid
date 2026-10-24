#!/usr/bin/env python3
"""Measure settled operation-task ownership using exact runtime method bodies.

The renderer Boolean, physical-stop latch, bounded effect receipts and timer
adapter are explicit laboratory dependencies; this is not a full player test.
"""
from __future__ import annotations
import argparse
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
BASELINE = "4abf4b44f13386ccd04f1ce4ad0e756255ca4d14"
RUNTIME = "Sources/IlliquidNativePlayback/Production/NativePlaybackRuntime.swift"
LEDGER = "Sources/IlliquidNativePlayback/Production/NativeOperationTransaction.swift"
PRESENTATION = "Sources/IlliquidNativePlayback/Presentation/NativePresentationCoordinator.swift"
VARIANTS = ("baseline", "candidate")
SCENARIOS = ("supersede", "complete", "cancel", "physicalStop")
MARKERS = [
    "    private func beginOperation(", "    private func correlateOperation(",
    "    private func finishOperation(\n        effectID:",
    "    private func cancelOperation(kind:", "    private func cancelOperationWork(",
    "    private func finishWhenPresentationFlushCompletes(",
]

def digest(data): return hashlib.sha256(data).hexdigest()
def save(path, value): path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
def declaration(source, marker):
    if source.count(marker) != 1: raise ValueError(f"Nonunique declaration: {marker}")
    start = source.index(marker)
    opening, depth = source.index("{", start), 0
    for end in range(opening, len(source)):
        depth += (source[end] == "{") - (source[end] == "}")
        if depth == 0: return source[start:end + 1]
    raise ValueError(f"Unterminated declaration: {marker}")

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--swift", default=shutil.which("swift") or "swift")
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--cycles", default="32,4096,32768")
    parser.add_argument("--tests-only", action="store_true")
    args = parser.parse_args()
    cycles = [int(value) for value in args.cycles.split(",")]
    if args.pairs < 2 or args.pairs % 2 or any(value < 2 for value in cycles):
        parser.error("Use even pairs >=2 and cycles >=2")
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()): parser.error("Use a new/empty output directory")
    output.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, TERM="dumb", NO_COLOR="1")
    env.update(SWIFTPM_MODULECACHE_OVERRIDE=str(output / "module-cache"),
               CLANG_MODULE_CACHE_PATH=str(output / "module-cache"))
    commands = []
    def command(argv, *, log=None):
        argv = [str(x) for x in argv]
        started = time.monotonic()
        result = subprocess.run(argv, cwd=ROOT, env=env, capture_output=True, text=True, timeout=900)
        receipt = {"argv": argv, "seconds": time.monotonic() - started,
                   "returncode": result.returncode, "stdout_sha256": digest(result.stdout.encode()),
                   "stdout_bytes": len(result.stdout.encode()), "stderr": result.stderr}
        if argv[:2] != ["git", "show"]: receipt["stdout"] = result.stdout
        commands.append(receipt)
        save(output / "commands.json", commands)
        if log: (output / log).write_text(result.stdout + result.stderr)
        if result.returncode: raise RuntimeError(f"Command failed: {argv}\n{result.stderr[-10000:]}")
        return result.stdout
    manifest = {"baseline_commit": BASELINE, "candidate_head": command(["git", "rev-parse", "HEAD"]).strip(),
        "worktree_status": command(["git", "status", "--porcelain=v1"]),
        "compiler": command([args.swift, "--version"]).strip(), "platform": platform.platform(),
        "machine": platform.machine(), "pairs": args.pairs, "cycles": cycles,
        "scenarios": list(SCENARIOS), "tests_only": args.tests_only,
        "sources": {}, "fragments": {}, "binaries": {},
        "scope": "Exact begin/correlate/finish(effectID)/cancel(kind)/cancelWork/flush-poller bodies and complete ledger/core types. Explicit adapters: presentation Boolean, bounded terminal receipts, physical-stop latch and timer registration using exact admission prefix. No native renderer/session, app footprint or throughput claim.",
        "ownership": "No external Task collection. Await all callback-capture probes' deinitialization then 5ms quiet period; sample live heap with runtime registry alive, then clear research registry and sample again.",
        "harness": {str(p.relative_to(HERE)): digest(p.read_bytes()) for p in HERE.rglob("*")
                    if p.is_file() and p.suffix in (".py", ".swift", ".template", ".c", ".h")}}
    def source(variant, relative):
        data = command(["git", "show", f"{BASELINE}:{relative}"]).encode() if variant == "baseline" else (ROOT / relative).read_bytes()
        target = output / "sources" / variant / relative
        target.parent.mkdir(parents=True, exist_ok=True); target.write_bytes(data)
        manifest["sources"][f"{variant}:{relative}"] = digest(data)
        return data
    core_paths = sorted(str(p.relative_to(ROOT)) for p in (ROOT / "Sources/IlliquidPlaybackCore").glob("*.swift"))
    binaries = {}
    for variant in VARIANTS:
        package = output / variant; package.mkdir()
        for relative in ["Sources/IlliquidCore/Player/MediaTrack.swift", *core_paths]:
            target = package / relative; target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(source(variant, relative))
        executable = package / "Sources/OperationWorkBenchmark"; executable.mkdir(parents=True)
        (executable / "NativeOperationTransaction.swift").write_bytes(source(variant, LEDGER))
        original = source(variant, RUNTIME).decode()
        methods = [declaration(original, marker) for marker in MARKERS]
        deadline = declaration(original, "    private func scheduleOperationDeadline(")
        admission = deadline[deadline.index("{") + 1:deadline.index("        cancelOperationDeadline(effectID:")]
        fence = declaration(source(variant, PRESENTATION).decode(), "struct PresentationFence:")
        shell = (HERE / "RuntimeShell.swift.template").read_text().replace("%%PRODUCTION_METHODS%%", "\n\n".join(methods))
        shell = shell.replace("%%DEADLINE_ADMISSION%%", admission).replace("%%PRESENTATION_FENCE%%", fence)
        (executable / "RuntimeShell.swift").write_text(shell)
        (executable / "Harness.swift").write_bytes((HERE / "Harness.swift").read_bytes())
        shutil.copytree(HERE / "CWorkHeap", package / "Sources/CWorkHeap")
        manifest["fragments"][variant] = {
            "methods": {marker: digest(body.encode()) for marker, body in zip(MARKERS, methods)},
            "deadline_admission_sha256": digest(admission.encode()), "fence_sha256": digest(fence.encode()),
            "generated_shell_sha256": digest(shell.encode())}
        define = ', swiftSettings: [.define("WORK_LIFETIME_CANDIDATE")]' if variant == "candidate" else ""
        (package / "Package.swift").write_text('// swift-tools-version: 6.1\nimport PackageDescription\n'
            'let package = Package(name: "OperationWorkLifetime", platforms: [.macOS("26.0")], products: [\n'
            '.executable(name: "OperationWorkBenchmark", targets: ["OperationWorkBenchmark"])], targets: [\n'
            '.target(name: "IlliquidCore"),\n.target(name: "IlliquidPlaybackCore", dependencies: ["IlliquidCore"]),\n'
            '.target(name: "CWorkHeap", publicHeadersPath: "include"),\n'
            '.executableTarget(name: "OperationWorkBenchmark", dependencies: ["IlliquidPlaybackCore", "CWorkHeap"]'
            + define + ')], swiftLanguageModes: [.v6])\n')
        build = [args.swift, "build", "--package-path", package, "-c", "release", "--jobs", "2",
                 "--cache-path", output / "cache", "--config-path", output / "config",
                 "--security-path", output / "security", "-Xswiftc", "-warnings-as-errors"]
        if platform.system() == "Linux": build.append("--use-integrated-swift-driver")
        save(output / "manifest.json", manifest)
        print(f"Build {variant}", flush=True)
        command([*build, "--product", "OperationWorkBenchmark"], log=f"{variant}-build.log")
        binaries[variant] = Path(command([*build, "--show-bin-path"]).strip()) / "OperationWorkBenchmark"
        manifest["binaries"][variant] = digest(binaries[variant].read_bytes())
    for relative in ["Sources/IlliquidCore/Player/MediaTrack.swift", *core_paths, LEDGER]:
        if manifest["sources"][f"baseline:{relative}"] != manifest["sources"][f"candidate:{relative}"]:
            raise ValueError(f"Unrelated support changed: {relative}")
    checks = {variant: json.loads(command([binary, "verify"], log=f"{variant}-qualification.log")) for variant, binary in binaries.items()}
    save(output / "qualification.json", checks)
    observations = []
    for scenario in (() if args.tests_only else SCENARIOS):
        for count in cycles:
            for pair in range(args.pairs):
                rows = {}
                for order_index, variant in enumerate(VARIANTS if pair % 2 == 0 else VARIANTS[::-1]):
                    row = json.loads(command([binaries[variant], scenario, count]))
                    if row["scenario"] != scenario or row["cycles"] != count: raise ValueError("Receipt mismatch")
                    row.update(variant=variant, pair=pair, order_index=order_index)
                    observations.append(row); rows[variant] = row
                    with (output / "observations.jsonl").open("a") as handle: handle.write(json.dumps(row, sort_keys=True) + "\n")
                for field in ("success", "cancelled", "failed", "result_digest", "completed_closure_lifetimes"):
                    if rows["baseline"][field] != rows["candidate"][field]: raise ValueError(f"Terminal parity failed: {field}")
            print(f"Measured {scenario} {count}", flush=True)
    summaries = []
    for scenario in SCENARIOS:
        for count in cycles:
            rows = [row for row in observations if row["scenario"] == scenario and row["cycles"] == count]
            if not rows: continue
            result = {"scenario": scenario, "cycles": count, "metrics": {}}
            for field in ("completed_handles_retained", "retained_allocator_delta_bytes", "reclaimed_registry_bytes",
                          "released_allocator_delta_bytes", "loop_wall_nanoseconds", "loop_cpu_nanoseconds"):
                values = {v: [next(row[field] for row in rows if row["variant"] == v and row["pair"] == p)
                              for p in range(args.pairs)] for v in VARIANTS}
                a, b = values["baseline"], values["candidate"]
                result["metrics"][field] = {"baseline_median": statistics.median(a), "candidate_median": statistics.median(b),
                    "baseline_range": [min(a), max(a)], "candidate_range": [min(b), max(b)],
                    "paired_change_median": statistics.median(y-x for x,y in zip(a,b)),
                    "candidate_lower_pairs": sum(y<x for x,y in zip(a,b))}
            summaries.append(result)
    for key, expected in manifest["sources"].items():
        variant, relative = key.split(":", 1)
        if variant == "candidate" and digest((ROOT / relative).read_bytes()) != expected:
            raise ValueError(f"Measured source changed: {relative}")
    summary = {"status": "complete", "observations": len(observations), "pairs": args.pairs,
        "qualification_scenarios_per_variant": len(checks["candidate"]), "results": summaries,
        "limits": "Allocator deltas include Swift runtime/task scheduler allocations; completed Task handles do not establish retained media payload. Synthetic scheduling times are not player throughput. Native renderer/resource behavior requires native tests."}
    save(output / "manifest.json", manifest); save(output / "summary.json", summary)
    print("OPERATION_WORK_LIFETIME_SUMMARY " + json.dumps(summary, sort_keys=True), flush=True)

if __name__ == "__main__": main()
