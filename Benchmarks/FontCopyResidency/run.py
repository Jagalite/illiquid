#!/usr/bin/env python3
"""Run a bounded, fresh-process macOS Foundation.Data residency experiment."""
from __future__ import annotations

import argparse
import base64
from datetime import datetime, timezone
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
KYOTO = Path("/Volumes/seed1/Projects/kyoto/kyoto.py")
SOURCE_NAMES = ("Probe.swift", "Probe.c", "Probe.h", "run.py", "README.md")
METRICS = ("malloc_bytes_in_use", "malloc_bytes_allocated", "resident_size",
           "phys_footprint", "internal", "reusable", "compressed")
STAGES = ("after_source_initialization", "priming_block_live", "priming_block_freed",
          "before_copy", "after_copy", "after_destination_read_touch",
          "after_source_read_touch", "after_pressure_relief", "after_source_release",
          "after_full_validation", "after_destination_release", "after_final_pressure_relief")


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def save(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n")


def plan() -> list[dict]:
    orders = []
    for mode, pairs in (("debug", 1), ("release", 6)):
        group_index = 0
        for cohort in ("data", "volatile-copy", "vm-copy"):
            for mib in (2, 4, 16):
                alignments = ("aligned",) if cohort == "vm-copy" else ("aligned", "offset-one")
                for alignment in alignments:
                    for cache in ("clean", "primed"):
                        group = f"{cohort}-{mib}mib-{alignment}-{cache}"
                        for pair in range(pairs):
                            order = ("no-copy", "copy") if (pair + group_index) % 2 == 0 else ("copy", "no-copy")
                            for position, action in enumerate(order):
                                orders.append(dict(sequence=len(orders), mode=mode, group=group,
                                    cohort=cohort, payload_bytes=mib * 1_048_576,
                                    source_alignment=alignment, cache=cache,
                                    pair=pair, position=position, action=action))
                        group_index += 1
    assert len(orders) == 420
    assert sum(row["mode"] == "release" for row in orders) == 360
    return orders


def describe(values: list[int]) -> dict:
    return {"median": statistics.median(values), "minimum": min(values), "maximum": max(values)}


class Study:
    def __init__(self, output: Path):
        self.output = output.resolve()
        if self.output.exists() and any(self.output.iterdir()):
            raise ValueError("Use an empty or new output directory")
        self.output.mkdir(parents=True, exist_ok=True)
        self.commands, self.rows, self.orders, self.binaries = [], [], plan(), {}
        self.manifest = {
            "schema_version": 1, "complete": False,
            "started_utc": datetime.now(timezone.utc).isoformat(),
            "platform": platform.platform(), "machine": platform.machine(),
            "pairs": {"debug": 1, "release": 6}, "planned_observations": len(self.orders),
            "performance_summary_mode": "release",
            "environment": {k: v for k, v in os.environ.items() if
                k.startswith("Malloc") or k in {"DEVELOPER_DIR", "DYLD_INSERT_LIBRARIES",
                "DYLD_LIBRARY_PATH", "NSZombieEnabled", "GITHUB_RUN_ID", "GITHUB_SHA",
                "RUNNER_OS", "RUNNER_ARCH", "ImageVersion"}},
            "protocol": {
                "clean": "fresh process; small warmup; initial malloc_zone_pressure_relief; no size-class priming",
                "primed": "same clean start; allocate, volatile-dirty, snapshot and free a payload-size destination block",
                "source": "posix_memalign(page size, payload + page size); initialize entire allocation; logical offset 0 or 1",
                "source_pattern": "byte i = 1 + (i % 251), over the complete logical payload",
                "destination_priming_allocator": "Data(bytes:count:) plus unique mutable borrow for Data; malloc for volatile-copy; posix_memalign for vm-copy",
                "copy_timer": "construction/allocation + copy only; excludes all validation and read-touching",
                "first_snapshot": "after copy returns and Data pointer is borrowed, before destination reads or zone lookup",
                "validation": "full known-pattern comparison after source free; no freed memory read",
                "summary": "within-pair (copy stage - copy before_copy) - (no-copy stage - no-copy before_copy)",
                "limits": "allocator/VM counter discriminator; no assumed cause, whole-player estimate, or traced Data implementation"},
            "sources": {}, "compilers": {}, "binaries": {}, "compiled_artifacts": {}
        }
        save(self.output / "manifest.json", self.manifest)
        save(self.output / "orders.json", self.orders)

    def command(self, argv, name: str, timeout=120) -> bytes:
        argv = [str(item) for item in argv]
        started = time.monotonic()
        try:
            result = subprocess.run(argv, cwd=ROOT, capture_output=True, timeout=timeout)
            stdout, stderr, returncode = result.stdout, result.stderr, result.returncode
            timed_out = False
        except subprocess.TimeoutExpired as error:
            stdout, stderr, returncode = error.stdout or b"", error.stderr or b"", None
            timed_out = True
        logs = self.output / "logs"
        logs.mkdir(exist_ok=True)
        out, err = logs / f"{name}.stdout.log", logs / f"{name}.stderr.log"
        out.write_bytes(stdout)
        err.write_bytes(stderr)
        self.commands.append({"argv": argv, "cwd": str(ROOT), "returncode": returncode,
            "timed_out": timed_out, "seconds": time.monotonic() - started,
            "stdout": str(out.relative_to(self.output)), "stdout_sha256": sha(stdout),
            "stderr": str(err.relative_to(self.output)), "stderr_sha256": sha(stderr)})
        save(self.output / "commands.json", self.commands)
        if returncode != 0:
            raise RuntimeError(f"{name} failed: returncode={returncode}, timeout={timed_out}\n"
                               + (stdout + stderr).decode(errors="replace")[-8000:])
        return stdout

    def preserve_compiled(self, path: Path, label: str) -> None:
        data = path.read_bytes()
        relative = Path("binaries") / (path.name + ".base64.txt")
        target = self.output / relative
        target.parent.mkdir(exist_ok=True)
        target.write_bytes(base64.b64encode(data) + b"\n")
        self.manifest["compiled_artifacts"][label] = {
            "base64_path": str(relative), "decoded_bytes": len(data), "sha256": sha(data)}
        save(self.output / "manifest.json", self.manifest)

    def prepare(self) -> None:
        if platform.system() != "Darwin":
            raise RuntimeError("This probe requires native macOS; no substitute measurement is supported")
        if KYOTO.exists():
            raise RuntimeError(f"Kyoto is available at {KYOTO}; this isolated-host runner does not implement its show/logs/wait protocol. Run the exact compiler commands through Kyoto and qualify completion before adapting this runner.")
        limitation = f"Kyoto unavailable on this isolated host ({KYOTO} absent); compiling this standalone probe directly."
        print(limitation, flush=True)
        (self.output / "build-coordination.txt").write_text(limitation + "\n")
        self.manifest["build_coordination"] = limitation
        sources = self.output / "sources"
        sources.mkdir()
        paths = [(HERE / name, name) for name in SOURCE_NAMES]
        paths.append((ROOT / ".github/workflows/font-copy-residency.yml", "font-copy-residency.yml"))
        if (ROOT / "AGENTS.md").is_file():
            paths.append((ROOT / "AGENTS.md", "AGENTS.md"))
        for original, name in paths:
            shutil.copyfile(original, sources / name)
            self.manifest["sources"][str(original.relative_to(ROOT))] = sha(original.read_bytes())
        (sources / "module.modulemap").write_text('module FontCopyProbe { header "Probe.h" export * }\n')
        self.manifest["modulemap_sha256"] = sha((sources / "module.modulemap").read_bytes())
        for key, argv in {
            "revision": ["git", "rev-parse", "HEAD"],
            "worktree_status": ["git", "status", "--porcelain"],
            "macos": ["sw_vers"], "kernel": ["uname", "-a"],
            "xcode": ["xcodebuild", "-version"],
            "hardware": ["sysctl", "hw.model", "hw.memsize", "hw.pagesize", "machdep.cpu.brand_string"],
            "sdk_path": ["xcrun", "--sdk", "macosx", "--show-sdk-path"],
            "sdk_version": ["xcrun", "--sdk", "macosx", "--show-sdk-version"]
        }.items():
            self.manifest[key] = self.command(argv, key).decode().strip()
        for name in ("swiftc", "clang"):
            path = self.command(["xcrun", "--find", name], f"find-{name}").decode().strip()
            version = self.command([path, "--version"], f"version-{name}").decode()
            self.manifest["compilers"][name] = {"path": path, "version": version,
                                                 "sha256": sha(Path(path).read_bytes())}
        save(self.output / "manifest.json", self.manifest)
        sdk = self.manifest["sdk_path"]
        build = self.output / "build"
        build.mkdir()
        clang = self.manifest["compilers"]["clang"]["path"]
        swift = self.manifest["compilers"]["swiftc"]["path"]
        obj = build / "Probe.o"
        # C volatile accesses use identical optimized machine code in both Swift configurations.
        self.command([clang, "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", "-isysroot", sdk,
                      "-c", sources / "Probe.c", "-o", obj], "compile-c", 180)
        self.manifest["c_object_sha256"] = sha(obj.read_bytes())
        self.preserve_compiled(obj, "c_object")
        for mode, optimization in (("debug", "-Onone"), ("release", "-O")):
            binary = build / f"probe-{mode}"
            self.command([swift, "-swift-version", "6", "-parse-as-library", optimization,
                "-sdk", sdk, "-I", sources, "-module-cache-path", self.output / "module-cache",
                sources / "Probe.swift", obj, "-o", binary], f"compile-{mode}", 240)
            self.binaries[mode] = binary
            self.preserve_compiled(binary, mode)
            dependencies = self.command(["otool", "-L", binary], f"dependencies-{mode}").decode()
            self.manifest["binaries"][mode] = {"sha256": sha(binary.read_bytes()),
                "size_bytes": binary.stat().st_size, "dependencies": dependencies}
            save(self.output / "manifest.json", self.manifest)

    def validate(self, row: dict, expected: dict) -> None:
        for name in ("payload_bytes", "source_alignment", "cache", "cohort", "action"):
            if row[name] != expected[name]:
                raise ValueError(f"Observation argument mismatch: {name}")
        count = row["payload_bytes"]
        quotient, remainder = divmod(count, 251)
        checksum = quotient * 251 * 252 // 2 + remainder * (remainder + 1) // 2
        if row["source_read_checksum"] != checksum:
            raise ValueError("Source byte pattern/read-touch mismatch")
        if row["source_page_offset"] != (0 if row["source_alignment"] == "aligned" else 1):
            raise ValueError("Source alignment mismatch")
        if row["source_allocation_bytes"] != count + row["page_size"]:
            raise ValueError("Source allocation request mismatch")
        if row["priming_performed"] != (row["cache"] == "primed"):
            raise ValueError("Priming mismatch")
        if row["action"] == "copy":
            if (row["contents_valid_after_source_release"] is not True or row["validated_bytes"] != count
                    or row["destination_read_checksum"] != checksum):
                raise ValueError("Full copied payload did not survive source release")
            if row["cohort"] == "vm-copy" and (row["vm_copy_result"] != 0
                    or row["destination_allocation"]["page_offset"] != 0):
                raise ValueError("Explicit vm_copy alignment/result mismatch")
        elif row["validated_bytes"] != 0 or row["contents_valid_after_source_release"] is not None:
            raise ValueError("No-copy control unexpectedly validated destination bytes")
        if set(row["stages"]) != set(STAGES) or any(v["task_info_result"] != 0
                or v["task_info_count"] < row["task_info_required_count"] for v in row["stages"].values()):
            raise ValueError("Missing stage or TASK_VM_INFO failure")
        stamps = [row["stages"][name]["wall_nanoseconds"] for name in STAGES]
        if stamps != sorted(stamps):
            raise ValueError("Snapshot timestamps out of order")

    def run(self) -> None:
        for expected in self.orders:
            name = f"{expected['sequence']:04d}-{expected['mode']}-{expected['group']}-pair{expected['pair']}-{expected['action']}"
            stdout = self.command([self.binaries[expected["mode"]], expected["payload_bytes"],
                expected["source_alignment"], expected["cache"], expected["cohort"], expected["action"]], name, 60)
            row = json.loads(stdout)
            self.validate(row, expected)
            observation = {"order": expected, "observation": row, "stdout_sha256": sha(stdout)}
            self.rows.append(observation)
            with (self.output / "observations.jsonl").open("a") as stream:
                stream.write(json.dumps(observation, sort_keys=True, allow_nan=False) + "\n")
            if (expected["sequence"] + 1) % 60 == 0:
                print(f"Validated {expected['sequence'] + 1}/{len(self.orders)} fresh processes", flush=True)

    def summarize(self) -> None:
        groups = {}
        for item in self.rows:
            order = item["order"]
            if order["mode"] == "release":
                groups.setdefault(order["group"], {}).setdefault(order["pair"], {})[order["action"]] = item["observation"]
        summary = {"schema_version": 1, "performance_mode": "release", "release_pairs_per_group": 6,
            "debug_observations": 60, "release_observations": 360,
            "all_420_observations_validated": len(self.rows) == 420,
            "units": "bytes, except copy_wall_nanoseconds",
            "effect": "paired copy-minus-no-copy change from each process's before_copy checkpoint",
            "interpretation": "Descriptive discriminator; an immediate counter decrease is not by itself evidence of less owned storage or a specific VM/allocator mechanism.",
            "groups": {}}
        lines = ["# Foundation Data copy residency probe", "",
            "Release only: six balanced fresh-process AB/BA pairs per condition. Debug: one correctness pair per condition.", "",
            "All deltas below are paired copy-minus-no-copy changes from each process's before_copy checkpoint (MiB).", "",
            "| Condition | Live malloc after copy | RSS after copy | RSS after destination touch | Footprint after copy | Reused primed address |",
            "|---|---:|---:|---:|---:|---:|"]
        for name, pairs in groups.items():
            if len(pairs) != 6 or any(set(pair) != {"copy", "no-copy"} for pair in pairs.values()):
                raise ValueError("Incomplete release pairs")
            effects = {}
            for stage in STAGES[4:]:
                effects[stage] = {}
                for metric in METRICS:
                    effects[stage][metric] = describe([
                        (pair["copy"]["stages"][stage][metric] - pair["copy"]["stages"]["before_copy"][metric])
                        - (pair["no-copy"]["stages"][stage][metric] - pair["no-copy"]["stages"]["before_copy"][metric])
                        for pair in pairs.values()])
            copies = [pair["copy"] for pair in pairs.values()]
            reused = sum(item["destination_reused_primed_address"] for item in copies)
            details = {"paired_effects": effects, "reused_primed_address_count": reused,
                "destination_page_offsets": [item["destination_allocation"]["page_offset"] for item in copies],
                "destination_zone_names": [item["destination_allocation"]["zone_name"] for item in copies],
                "copy_wall_nanoseconds": describe([p["copy"]["copy_wall_nanoseconds"] - p["no-copy"]["copy_wall_nanoseconds"] for p in pairs.values()]),
                "no_copy_priming_changes": {stage: {metric: describe([
                    p["no-copy"]["stages"][stage][metric] - p["no-copy"]["stages"]["after_source_initialization"][metric]
                    for p in pairs.values()]) for metric in METRICS}
                    for stage in ("priming_block_live", "priming_block_freed")}}
            summary["groups"][name] = details
            mib = lambda stage, metric: effects[stage][metric]["median"] / 1_048_576
            lines.append(f"| {name} | {mib('after_copy', 'malloc_bytes_in_use'):.3f} | {mib('after_copy', 'resident_size'):.3f} | {mib('after_destination_read_touch', 'resident_size'):.3f} | {mib('after_copy', 'phys_footprint'):.3f} | {reused}/6 |")
        lines += ["", "The full JSON contains every requested VM counter, later touch/release checkpoints, pair ranges, actual alignment/zone names, and priming-live/free deltas.",
                  "These measurements do not trace the Foundation implementation or establish whole-player memory savings.", ""]
        save(self.output / "summary.json", summary)
        (self.output / "summary.md").write_text("\n".join(lines))
        self.manifest.update(complete=True, completed_utc=datetime.now(timezone.utc).isoformat(),
                             validated_observations=len(self.rows))
        save(self.output / "manifest.json", self.manifest)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--validate-inputs", action="store_true", help="Check only local inputs/order; do not compile or execute")
    args = parser.parse_args()
    if args.validate_inputs:
        for name in SOURCE_NAMES:
            if not (HERE / name).is_file():
                raise ValueError(f"Missing source: {name}")
        orders = plan()
        print(json.dumps({"input_hashes": {name: sha((HERE / name).read_bytes()) for name in SOURCE_NAMES},
                          "observations": len(orders), "debug": 60, "release": 360}, sort_keys=True))
        return
    if args.output is None:
        parser.error("--output is required for a native run")
    study = Study(args.output)
    try:
        study.prepare()
        study.run()
        study.summarize()
    except BaseException as error:
        study.manifest.update(error=repr(error), validated_observations=len(study.rows))
        save(study.output / "manifest.json", study.manifest)
        raise


if __name__ == "__main__":
    main()
