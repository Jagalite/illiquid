#!/usr/bin/env python3
"""Noncompiling source-policy controls; no Swift invocation or evidence mutation."""
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("reachability", Path(__file__).with_name("run.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class PolicyTests(unittest.TestCase):
    def setUp(self):
        self.focal = runner.ANALYZER
        self.support = Path(next(iter(runner.REGRESSION_SUPPORT_SHA256)))
        self.other = runner.CORE
        self.original = {self.focal: b"historical focal", self.support: b"old support", self.other: b"unchanged"}
        self.current = {self.focal: b"reviewed focal", self.support: b"reviewed support", self.other: b"unchanged"}
        pins = {
            "REGRESSION_BASELINE_FOCAL_SHA256": runner.digest(self.original[self.focal]),
            "REGRESSION_CANDIDATE_FOCAL_SHA256": runner.digest(self.current[self.focal]),
            "REGRESSION_SUPPORT_SHA256": {str(self.support): runner.digest(self.current[self.support])},
        }
        for name, value in pins.items():
            context = patch.object(runner, name, value)
            context.start()
            self.addCleanup(context.stop)

    def validate(self, mode="regression", commit=None):
        runner.validate_sources(commit or runner.REGRESSION_BASELINE, self.original, self.current, mode)

    def test_reviewed_support_accepted(self):
        self.validate()

    def test_default_historical_rejects_support_drift(self):
        for mode in ("test", "benchmark"):
            with self.assertRaises(RuntimeError):
                self.validate(mode)

    def test_historical_unchanged_support_accepted(self):
        self.current[self.support] = self.original[self.support]
        self.validate("benchmark")

    def test_unreviewed_support_drift_rejected(self):
        self.current[self.other] += b"drift"
        with self.assertRaises(RuntimeError):
            self.validate()

    def test_allowlisted_file_content_drift_rejected(self):
        self.current[self.support] += b"drift"
        with self.assertRaises(RuntimeError):
            self.validate()

    def test_replaced_baseline_commit_rejected(self):
        with self.assertRaises(RuntimeError):
            self.validate(commit="f" * 40)

    def test_replaced_baseline_focal_rejected(self):
        self.original[self.focal] = self.current[self.focal]
        with self.assertRaises(RuntimeError):
            self.validate()

    def test_noop_candidate_rejected(self):
        self.current[self.focal] = self.original[self.focal]
        with self.assertRaises(RuntimeError):
            self.validate()

    def test_unreviewed_candidate_rejected(self):
        self.current[self.focal] += b"drift"
        with self.assertRaises(RuntimeError):
            self.validate()

    def test_file_set_drift_rejected(self):
        self.current[Path("extra.swift")] = b"extra"
        with self.assertRaises(RuntimeError):
            self.validate()

    def test_timing_and_partial_qualification_options_rejected(self):
        for flag in ("--rounds", "--iterations", "--target-ms", "--configuration", "--variant"):
            for spelling in (flag, flag + "=10"):
                with self.subTest(spelling=spelling), self.assertRaises(RuntimeError):
                    runner.validate_mode("regression", [spelling])
        runner.validate_mode("regression", ["--baseline-ref", runner.REGRESSION_BASELINE])
        runner.validate_mode("benchmark", ["--rounds", "10"])

    def test_regression_never_measures(self):
        # Exercise the real differential entrypoint with fake binaries/output;
        # reject any command other than the complete verify and workload list.
        import argparse
        import tempfile
        import json
        calls = []
        def command(args, *unused, **kwargs):
            calls.append(args[1])
            if args[1] == "verify":
                return json.dumps({"graphs": [{"complete": True}], "reports": [1, 2]}).encode()
            if args[1] == "list":
                return b'{"workloads":["control","graph"]}'
            raise AssertionError("Timing command attempted")
        with tempfile.TemporaryDirectory() as temporary, patch.object(runner, "build_dependencies", return_value=Path("shared")), patch.object(runner, "build", return_value=Path("binary")), patch.object(runner, "command", side_effect=command):
            out = Path(temporary)
            runner.benchmark(out, argparse.Namespace(mode="regression"), {})
            self.assertEqual(calls, ["verify", "list", "verify", "list"])
            self.assertTrue((out / "verification-summary.json").is_file())
            self.assertFalse((out / "measurements.jsonl").exists())


if __name__ == "__main__":
    unittest.main()
