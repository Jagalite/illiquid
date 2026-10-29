#!/usr/bin/env python3
"""Non-compiling checks of source selection and qualification receipt policy."""
import copy
import contextlib
import io
import json
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace

SPEC = importlib.util.spec_from_file_location("batch_open", Path(__file__).with_name("run.py"))
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)


class SourcePolicyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.baseline = {
            path: subprocess.check_output(["git", "show", f"{runner.BASELINE}:{path}"], cwd=runner.ROOT)
            for path in (*runner.SOURCES, runner.CONTROLLER)
        }
        cls.current = {path: (runner.ROOT / path).read_bytes() for path in cls.baseline}

    def test_historical_guard_rejects_each_support_change(self):
        runner.select_sources(self.baseline, self.baseline, False)
        for path in runner.SOURCES:
            changed = dict(self.baseline)
            changed[path] += b"\n// support drift\n"
            with self.subTest(path=path), self.assertRaisesRegex(RuntimeError, "Shared dependency changed"):
                runner.select_sources(self.baseline, changed, False)

    def test_regression_preserves_focal_oracle_and_shares_current_support(self):
        sources = runner.select_sources(self.baseline, self.current, True)
        for path in runner.SOURCES:
            self.assertEqual(sources["baseline"][path], self.current[path])
            self.assertEqual(sources["baseline"][path], sources["candidate"][path])
        self.assertEqual(sources["baseline"][runner.CONTROLLER], self.baseline[runner.CONTROLLER])
        wrappers = {v: runner.extract(sources[v][runner.CONTROLLER], v)[0] for v in runner.VARIANTS}
        self.assertNotEqual(wrappers["baseline"], wrappers["candidate"])
        self.assertIn(b"preservedCurrent != nil", wrappers["baseline"])
        for field in ("selectedIndex", "preservesCurrent"):
            control = runner.negative_source(wrappers["candidate"], field)
            self.assertNotEqual(control, wrappers["candidate"])
            with self.assertRaisesRegex(RuntimeError, "not unique"):
                runner.negative_source(control, field)

    def test_extraction_rejects_missing_or_ambiguous_markers(self):
        for variant, source in (("baseline", self.baseline), ("candidate", self.current)):
            controller = source[runner.CONTROLLER]
            for changed in (controller.replace(runner.BLOCK_END.encode(), b""), controller + controller):
                with self.assertRaises(RuntimeError):
                    runner.extract(changed, variant)

    def test_exact_output_validation_rejects_missing_cases_and_bad_checksums(self):
        records = [{"label": str(i), "selectedIndex": i, "preservesCurrent": True} for i in range(2102)]
        value = {"status": "passed", "checks": 2102, "results": records,
                 "checksum": sum(((i + 1) << 1) | 1 for i in range(2102))}
        runner.validate_verification(value)
        for mutation in ("missing", "duplicate", "index", "preservation", "checksum"):
            changed = copy.deepcopy(value)
            if mutation == "missing":
                changed["results"].pop()
            elif mutation == "duplicate":
                changed["results"][1]["label"] = "0"
            elif mutation == "index":
                changed["results"][0]["selectedIndex"] = True
            elif mutation == "preservation":
                changed["results"][0]["preservesCurrent"] = 1
            else:
                changed["checksum"] += 1
            with self.subTest(mutation=mutation), self.assertRaises(RuntimeError):
                runner.validate_verification(changed)


class RegressionOrchestrationTests(unittest.TestCase):
    setUpClass = classmethod(SourcePolicyTests.setUpClass.__func__)
    # Replace ALL subprocesses; these are runner policy tests, not Swift evidence.
    def simulate(self, output, *, mismatched_output=False, accepts_control=False):
        records = [{"label": str(i), "selectedIndex": i, "preservesCurrent": True}
                   for i in range(2102)]
        verification = {"status": "passed", "checks": 2102, "results": records,
                        "checksum": sum(((i + 1) << 1) | 1 for i in range(2102))}
        workloads = [{"id": str(i)} for i in range(20)]
        commands = []

        def popen(argv, **kwargs):
            commands.append(argv)
            stdout, stderr, code = b"", b"", 0
            if argv[:2] == ["git", "show"]:
                stdout = self.baseline[argv[2].split(":", 1)[1]]
            elif argv[:2] == ["git", "rev-parse"]:
                stdout = b"simulated-head"
            elif argv[:2] == ["git", "status"]:
                pass
            elif argv == ["swiftc", "--version"]:
                stdout = b"SIMULATED - no compilation"
            elif argv[0] == "swiftc":
                Path(argv[argv.index("-o") + 1]).write_bytes(b"SIMULATED - never executed")
            elif argv[-1] == "verify":
                if "negative-controls" in argv[0] and not accepts_control:
                    stderr, code = b"incorrectResult: simulated deliberate mutation", 1
                else:
                    value = copy.deepcopy(verification)
                    if mismatched_output and "candidate-debug" in argv[0]:
                        # Same checksum and all cases; exact per-case equality must still fail.
                        value["results"][0]["selectedIndex"], value["results"][1]["selectedIndex"] = 1, 0
                    stdout = json.dumps(value).encode()
            elif argv[-1] == "list":
                stdout = json.dumps(workloads).encode()
            else:
                raise AssertionError(f"Unexpected subprocess (including timing): {argv}")

            class Process:
                pid = 0
                returncode = code

                def communicate(self, timeout):
                    return stdout, stderr

            return Process()

        actual_is_file = Path.is_file
        with patch.object(runner.platform, "uname", return_value=SimpleNamespace(_asdict=lambda: {"system": "SIMULATED"})), \
             patch.object(runner.subprocess, "Popen", popen), \
             patch.object(runner.shutil, "which", return_value="swiftc"), \
             patch.object(runner.sys, "platform", "linux"), \
             patch.object(runner.sys, "argv", ["run.py", "--regression-only", "--output", str(output)]), \
             patch.object(Path, "is_file", lambda path: False if str(path) == "/Volumes/seed1/Projects/kyoto/kyoto.py" else actual_is_file(path)), \
             contextlib.redirect_stdout(io.StringIO()):
            runner.main()
        return commands

    def test_regression_never_invokes_timing_and_keeps_full_receipts(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            self.simulate(output)
            summary = json.loads((output / "summary.json").read_text())
            self.assertEqual(summary["status"], "passed")
            self.assertFalse(summary["timings_collected"])
            self.assertEqual(len(summary["negative_controls"]), 2)
            self.assertEqual(len(summary["verification"]), 4)
            self.assertFalse((output / "measurements.jsonl").exists())
            self.assertFalse((output / "calibration.jsonl").exists())
            self.assertNotIn("wall_seconds", (output / "commands.jsonl").read_text())
            manifest = json.loads((output / "manifest.json").read_text())
            self.assertEqual(manifest["support_policy"], "identical-current")
            for path in runner.SOURCES:
                name = Path(path).name
                self.assertEqual((output / "sources/baseline" / name).read_bytes(),
                                 (output / "sources/candidate" / name).read_bytes())

    def test_exact_output_mismatch_fails_even_with_equal_checksum(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(RuntimeError, "verification output differs"):
                self.simulate(Path(directory), mismatched_output=True)

    def test_negative_control_must_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(RuntimeError, "control was not rejected"):
                self.simulate(Path(directory), accepts_control=True)


if __name__ == "__main__":
    unittest.main()
