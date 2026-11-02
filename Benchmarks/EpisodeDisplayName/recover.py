#!/usr/bin/env python3
"""Restart measurements from qualified executables after an infrastructure failure.

No compilation occurs. Tests are explicitly inherited from --qualified-run;
complete output parity is checked again with the task-private --runtime. The
frozen inputs/run.py supplies Study.command/measure/benchmark/update unchanged.
Its compiler-dependent constructor and qualification/build methods are never
called. A fresh study is initialized explicitly, with ROOT set to this checkout
and new calibration plus twelve equal-work AB/BA pairs at 150 ms. Interrupted
observations are preserved only below references/ and never pooled into results.

The runtime directory must contain flat shared libraries, runtime-manifest.json,
and original-verification.json describing their independently checked identity.
Use --interrupted-run for any additional failed restart whose records should be
retained alongside the qualified, interrupted run.
"""
from __future__ import annotations

import argparse
import copy
import gzip
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import shutil
import sys
import time
import traceback
from types import SimpleNamespace

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
VARIANTS = ("baseline", "candidate")


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()


def read_json(path):
    return json.loads(path.read_bytes())


def safe_relative(value):
    path = Path(value)
    if path.is_absolute() or ".." in path.parts or not path.parts:
        raise ValueError(f"Invalid evidence-relative path: {value}")
    return path


def check_file(path, expected):
    raw = path.read_bytes()
    if sha(raw) != expected["sha256"] or ("bytes" in expected and len(raw) != expected["bytes"]):
        raise ValueError(f"Hash or size drift: {path}")
    if "git_blob" in expected:
        blob = hashlib.sha1(f"blob {len(raw)}\0".encode() + raw).hexdigest()
        if blob != expected["git_blob"]:
            raise ValueError(f"Git blob drift: {path}")
    return raw


def complete_jsonl_prefix(path):
    """ENOSPC may leave one truncated final record; earlier records must parse."""
    lines = path.read_bytes().splitlines()
    records = []
    for index, line in enumerate(lines):
        try:
            records.append(json.loads(line))
        except (ValueError, UnicodeError):
            if index != len(lines) - 1:
                raise ValueError(f"Malformed nonfinal record in {path}")
            break
    return records


def checked_command_log(root, record):
    if record["returncode"] != 0:
        raise ValueError(f"Inherited qualification command failed: {record['label']}")
    outputs = []
    for stream in ("stdout", "stderr"):
        path = root / safe_relative(record[stream])
        raw = path.read_bytes()
        if path.name.endswith(".gz"):
            raw = gzip.decompress(raw)
        if sha(raw) != record[stream + "_sha256"]:
            raise ValueError(f"Inherited qualification log changed: {path}")
        outputs.append(raw)
    return b"\n".join(outputs)


def retain_reference(source, destination):
    """Keep raw interrupted records, including an empty/truncated failure.json."""
    excluded = {"work", "build", ".build", "cache", "module-cache", "__pycache__"}
    files = {}
    for directory, names, filenames in os.walk(source):
        names[:] = sorted(name for name in names if name not in excluded)
        for name in sorted(filenames):
            path = Path(directory) / name
            if path.is_symlink() or path.suffix not in {".json", ".jsonl", ".log", ".txt", ".gz", ".swift", ".py"}:
                continue
            relative = path.relative_to(source)
            raw = path.read_bytes()
            target = destination / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(raw)
            files[relative.as_posix()] = {"bytes": len(raw), "sha256": sha(raw)}
    return {"source": str(source), "files": files}


def prepare(args):
    qualified, output, runtime = args.qualified_run.resolve(), args.output.resolve(), args.runtime.resolve()
    if output.exists():
        raise ValueError(f"Use a new output directory: {output}")
    if platform.system() != "Linux":
        raise ValueError("This recovery path verifies Linux shared-library identities; use run.py on macOS")
    original = read_json(qualified / "manifest.json")
    inputs = original["input_sources"]
    for relative, expected in inputs.items():
        check_file(qualified / "inputs" / safe_relative(relative), expected)
    # Require the current source, driver, runner and every test to match the
    # exact inputs from which the retained executables were built.
    current = {"candidate/MediaNameRecognition.swift": ROOT / "Sources/IlliquidCore/MediaLibrary/MediaNameRecognition.swift",
               "Driver.swift": HERE / "Driver.swift", "run.py": HERE / "run.py",
               "baseline/manifest.json": HERE / "baseline/manifest.json",
               "baseline/MediaNameRecognition.swift": HERE / "baseline/MediaNameRecognition.swift"}
    current.update({name: ROOT / name for name in inputs if name.startswith("Tests/")})
    for name, path in current.items():
        check_file(path, inputs[name])

    commands = complete_jsonl_prefix(qualified / "commands.jsonl")
    by_label = {row["label"]: row for row in commands}
    tests = read_json(qualified / "tests.json")
    expected_runs = {(variant, configuration) for variant in VARIANTS for configuration in ("debug", "release")}
    if (len(tests) != 4 or {(row["variant"], row["configuration"]) for row in tests} != expected_runs
            or any(row.get("passed") is not True or type(row.get("count")) is not int or row["count"] <= 0 for row in tests)
            or len({row["count"] for row in tests}) != 1):
        raise ValueError("Four matching successful baseline/candidate debug/release test runs are required")
    required_labels = ["baseline-provenance", "swift-version"]
    for test in tests:
        label = f"tests-{test['variant']}-{test['configuration']}"
        text = checked_command_log(qualified, by_label[label]).decode(errors="replace")
        counts = re.findall(r"Test run with (\d+) tests?", text)
        if not counts or int(counts[-1]) != test["count"]:
            raise ValueError(f"Inherited test count mismatch: {label}")
        required_labels.append(label)
    for variant in VARIANTS:
        required_labels += [f"build-{variant}", f"bin-path-{variant}", f"list-{variant}", f"verify-{variant}"]
    for label in required_labels:
        checked_command_log(qualified, by_label[label])
    if not original.get("baseline_git_history_verified"):
        raise ValueError("Recovery requires previously verified baseline Git provenance")
    pinned = read_json(qualified / "inputs/baseline/manifest.json")
    provenance = gzip.decompress((qualified / by_label["baseline-provenance"]["stdout"]).read_bytes())
    if sha(provenance) != pinned["source"]["sha256"]:
        raise ValueError("Inherited baseline provenance differs from the pinned source")

    parity = read_json(qualified / "parity.json")
    receipts = json.loads(gzip.decompress((qualified / "verification-receipts.json.gz").read_bytes()))
    if (parity.get("equal") is not True or parity.get("exact_utf8") is not True
            or sha(canonical(receipts)) != parity["sha256"]
            or len(receipts) != parity["receipts"]
            or sum(len(row["labels"]) for row in receipts) != parity["labels"]):
        raise ValueError("Inherited complete-output qualification is missing or changed")
    cases = read_json(qualified / "cases.json")
    binaries = read_json(qualified / "binaries.json")
    if set(binaries) != set(VARIANTS):
        raise ValueError("Both qualified executables are required")
    for variant in VARIANTS:
        check_file(Path(binaries[variant]["path"]), binaries[variant])
        for mode, expected in (("list", cases), ("verify", receipts)):
            record = by_label[f"{mode}-{variant}"]
            raw = (qualified / record["stdout"]).read_bytes()
            if record["stdout"].endswith(".gz"):
                raw = gzip.decompress(raw)
            if json.loads(raw) != expected:
                raise ValueError(f"Inherited {mode} result differs for {variant}")

    runtime_manifest = read_json(runtime / "runtime-manifest.json")
    runtime_check = read_json(runtime / "original-verification.json")
    if (runtime_check.get("complete") is not True
            or runtime_check["canonical_receipts_sha256"] != parity["sha256"]
            or any(runtime_check["binaries"][v]["sha256"] != binaries[v]["sha256"] for v in VARIANTS)):
        raise ValueError("The supplied runtime was not verified with these executables and outputs")
    libraries = {}
    for source, expected in runtime_check["required_libraries"].items():
        if expected["in_surviving_runtime"]:
            name = Path(source).name
            declared = runtime_manifest["files"][name]
            if declared["sha256"] != expected["sha256"] or declared["bytes"] != expected["bytes"]:
                raise ValueError(f"Runtime identity receipts disagree: {name}")
            path = runtime / name
            if path.is_symlink():
                raise ValueError(f"Use task-private copied runtime files, not shared symlinks: {path}")
        else:
            path = Path(expected["resolved_path"])
        check_file(path, expected)
        libraries[str(path.resolve())] = {"bytes": expected["bytes"], "sha256": expected["sha256"]}
    if set(runtime_manifest["files"]) != {Path(path).name for path, info in runtime_check["required_libraries"].items() if info["in_surviving_runtime"]}:
        raise ValueError("Runtime library inventory does not match its qualification receipt")

    # Import only after its snapshot and current counterpart pass hash checks.
    spec = importlib.util.spec_from_file_location("frozen_episode_display_name_study", qualified / "inputs/run.py")
    frozen = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(frozen)
    frozen.ROOT = ROOT
    study = frozen.Study.__new__(frozen.Study)
    study.args = SimpleNamespace(pairs=12, target_ms=150.0)
    study.output, study.work = output, output / "work"
    output.mkdir(parents=True)
    study.environment = os.environ.copy()
    for key in ("LANG", "LC_ALL", "LC_COLLATE", "LC_CTYPE", "TZ", "SWIFT_DETERMINISTIC_HASHING", "SDKROOT", "DEVELOPER_DIR"):
        value = original["environment"].get(key)
        if value is None:
            study.environment.pop(key, None)
        else:
            study.environment[key] = value
    study.environment.update(LD_LIBRARY_PATH=str(runtime), TERM="dumb", NO_COLOR="1")
    if study.environment.get("LD_PRELOAD") or study.environment.get("LD_AUDIT"):
        raise ValueError("Unrecorded dynamic-loader injection prevents a matched recovery")
    temporary = study.work / "tmp"
    temporary.mkdir(parents=True)
    study.environment["TMPDIR"] = str(temporary)
    study.sequence, study.packages, study.binaries, study.expected = 0, {}, {}, {}
    study.swift = None  # Deliberately unavailable/unused; no compiler is invoked.
    study.manifest = copy.deepcopy(original)
    study.manifest.update(complete=False, status="recovering", started_utc=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        arguments={"qualified_run": str(qualified), "output": str(output), "runtime": str(runtime),
                   "interrupted_run": [str(path.resolve()) for path in args.interrupted_run], "pairs": 12, "target_ms": 150.0},
        platform=platform.platform(), uname=platform.uname()._asdict(), python=sys.version, cpu_count=os.cpu_count(),
        environment={key: study.environment.get(key) for key in original["environment"]})
    study.manifest.pop("finished_utc", None)
    study.manifest.pop("error", None)
    study.manifest["swift"] = {**original["swift"], "provenance": "inherited from qualified build; compiler not invoked or required in recovery"}
    study.manifest["recovery"] = {"qualified_run": str(qualified), "runtime": str(runtime),
        "frozen_runner_sha256": inputs["run.py"]["sha256"], "runner_ROOT_override": str(ROOT),
        "methods_reused_unchanged": ["Study.command", "Study.measure", "Study.benchmark", "Study.update"],
        "constructor_bypassed": "Study.__new__ used to initialize a measurement-only instance without pretending a compiler exists",
        "compilation_performed": False, "tests": "inherited from four hash-checked successful test logs",
        "parity": "pending fresh complete verification", "old_samples_included": 0,
        "new_calibration": True, "runtime_libraries": libraries}
    if hasattr(os, "sched_getaffinity"):
        study.manifest["cpu_affinity"] = sorted(os.sched_getaffinity(0))
    if hasattr(os, "getloadavg"):
        study.manifest["load_average_start"] = os.getloadavg()
    study.update()

    references = []
    for index, reference in enumerate([qualified, *[path.resolve() for path in args.interrupted_run]]):
        if not reference.is_dir() or output.is_relative_to(reference):
            raise ValueError(f"Invalid interrupted-run reference: {reference}")
        retained = retain_reference(reference, output / "references" / f"interrupted-{index + 1}")
        retained["purpose"] = "raw infrastructure-failure history only; no timings reused"
        references.append(retained)
    frozen.save(output / "references.json", references)
    shutil.copytree(qualified / "inputs", output / "inputs")
    recovery_raw = Path(__file__).read_bytes()
    (output / "inputs/recover.py").write_bytes(recovery_raw)
    study.manifest["input_sources"]["recover.py"] = frozen.record(recovery_raw)
    for name in ("runtime-manifest.json", "original-verification.json"):
        shutil.copyfile(runtime / name, output / name)
    frozen.save(output / "tests.json", [{**row, "inherited": True, "qualified_run": str(qualified)} for row in tests])
    new_binaries = {}
    for variant in VARIANTS:
        target = study.work / "bin" / variant / "EpisodeDisplayNameProbe"
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(binaries[variant]["path"], target)
        check_file(target, binaries[variant])
        study.binaries[variant] = target
        new_binaries[variant] = {"path": str(target), "sha256": binaries[variant]["sha256"],
                                 "inherited_from": binaries[variant]["path"]}
        # Confirm the loader resolves this private runtime and the same checked
        # system libraries; checking files alone would not prove they were used.
        loaded = study.command(["ldd", target], f"runtime-dependencies-{variant}").decode()
        if "not found" in loaded:
            raise ValueError(f"Unresolved runtime dependency for {variant}")
        paths = {str(Path(path).resolve()) for path in re.findall(r"(?:=>\s+)?(/[^\s(]+)\s+\(", loaded)}
        if paths != set(libraries):
            raise ValueError(f"Resolved runtime library inventory changed for {variant}: {sorted(paths ^ set(libraries))}")
    frozen.save(output / "binaries.json", new_binaries)
    study.manifest["head"] = study.command(["git", "rev-parse", "HEAD"], "recovery-head").decode().strip()
    study.manifest["worktree"] = study.command(["git", "status", "--short"], "recovery-worktree").decode()
    study.update()
    return study, frozen, cases, receipts, parity


def verify(study, frozen, original_cases, original_receipts, original_parity):
    for variant in VARIANTS:
        cases = json.loads(study.command([study.binaries[variant], "--list"], f"list-{variant}"))
        receipts = json.loads(study.command([study.binaries[variant], "--verify"], f"verify-{variant}", compressed=True))
        if cases != original_cases or receipts != original_receipts:
            raise ValueError(f"Fresh {variant} full-output parity differs from the qualified run")
    by_name = {row["name"]: row for row in receipts}
    if len(by_name) != len(receipts) or len({case["name"] for case in cases}) != len(cases) or not cases:
        raise ValueError("Invalid workload or receipt inventory")
    for receipt in receipts:
        value = sum((index + 1) * len(label.encode("utf-8")) for index, label in enumerate(receipt["labels"]))
        if value != receipt["checksum"]:
            raise ValueError("Fresh receipt checksum differs from its complete UTF-8 output")
    for case in cases:
        receipt = by_name[case["name"]]
        if len(receipt["labels"]) != case["batch_size"] or case["batch_size"] <= 0:
            raise ValueError("Fresh output batch size differs from its workload")
        study.expected[case["name"]] = {"batch_size": case["batch_size"], "checksum": receipt["checksum"]}
    if study.expected != original_parity["expected"]:
        raise ValueError("Fresh measurement expectations differ from qualified outputs")
    complete = canonical(receipts)
    (study.output / "verification-receipts.json.gz").write_bytes(gzip.compress(complete, mtime=0))
    frozen.save(study.output / "parity.json", {**original_parity, "freshly_reverified": True,
        "runtime_directory": study.manifest["recovery"]["runtime"], "sha256": sha(complete)})
    frozen.save(study.output / "cases.json", cases)
    study.manifest["selected_cases"] = cases
    study.manifest["recovery"]["parity"] = "freshly reverified: both full inventories and exact UTF-8 receipts match qualified outputs"
    study.update()
    print(f"PASS recovered executables: {len(receipts)} exact receipts; "
          f"{original_parity['labels']} labels. Four test runs are inherited; none rerun.", flush=True)
    return cases


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--qualified-run", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--runtime", required=True, type=Path)
    parser.add_argument("--interrupted-run", action="append", type=Path, default=[])
    args = parser.parse_args()
    study = frozen = None
    try:
        study, frozen, cases, receipts, parity = prepare(args)
        cases = verify(study, frozen, cases, receipts, parity)
        # This is the original benchmark method from the hash-pinned input
        # snapshot: fresh calibration, fresh observations, unchanged statistics.
        study.benchmark(cases)
        study.manifest.update(complete=True, status="measured", finished_utc=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
        if hasattr(os, "getloadavg"):
            study.manifest["load_average_end"] = os.getloadavg()
        study.update()
        return 0
    except Exception as error:
        if study is not None:
            frozen.save(study.output / "failure.json", {"error": str(error), "traceback": traceback.format_exc()})
            study.manifest.update(complete=False, status="failed", error=str(error))
            study.update()
        print(str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
