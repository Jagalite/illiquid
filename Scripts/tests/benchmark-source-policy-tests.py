#!/usr/bin/env python3
"""Source-policy controls only: no Swift, compiler, Git or network commands."""
import argparse
from contextlib import ExitStack
import json
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "Benchmarks" / name / "run.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


CHECKPOINT = load("CheckpointConstruction")


class SourcePolicyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def write_current(self, files):
        for relative, data in files.items():
            destination = self.root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(data)

    def checkpoint(self, changed, regression_only, boundary_count=1, suffix_drift=False):
        self.root = self.root.resolve()
        historical = {p: (p + "\n").encode() for p in CHECKPOINT.CORE + [CHECKPOINT.PLAYER]}
        store = next(p for p in historical if p.endswith("PlaybackSessionStore.swift"))
        marker = b"\n/// A versioned, atomic Application Support document"
        historical[store] = b"record and protocol" + marker + b"\ndisk store"
        current = dict(historical)
        for path in changed:
            current[path] = b"// current\n" + current[path]
        current[store] = current[store].replace(marker, marker * boundary_count)
        if suffix_drift:
            current[store] += b"changed disk store outside compiled prefix"
        self.write_current(current)
        harness = {p: (p + " captured\n").encode() for p in CHECKPOINT.TESTS}
        here = self.root / "Benchmarks/CheckpointConstruction"
        harness.update({str((here / name).relative_to(self.root)): b"harness"
                        for name in ("Driver.swift", "run.py")})
        self.write_current(harness)
        output = self.root / "checkpoint"
        output.mkdir()
        run = CHECKPOINT.Run(output)
        manifest = {"head": "test-checkout"}

        def historical_source(args, *unused, **kwargs):
            # Live inputs change after their first capture. Neither variant may
            # reread them, including tests later copied into separate packages.
            self.write_current({p: b"changed after capture" for p in current | harness})
            return historical[args[-1].split(":", 1)[1]]

        with patch.object(CHECKPOINT, "ROOT", self.root), patch.object(
            CHECKPOINT, "HERE", here
        ), patch.object(CHECKPOINT, "__file__", str(here / "run.py")), patch.object(
            run, "command", side_effect=historical_source
        ):
            variants = CHECKPOINT.stage(run, manifest, regression_only)
        for path, raw in historical.items():
            entry = manifest["historical_sources"][path]
            self.assertEqual((output / entry["full_snapshot"]).read_bytes(), raw)
            self.assertEqual(entry["source_revision"], CHECKPOINT.BASELINE)
            self.assertEqual(entry["full_sha256"], CHECKPOINT.digest(raw))
            self.assertEqual(entry["compiled_sha256"], CHECKPOINT.digest(
                raw.split(marker)[0] + b"\n" if path == store else raw))
        for variant in ("baseline", "candidate"):
            for path in historical:
                use_current = variant == "candidate" or (regression_only and path in CHECKPOINT.CORE)
                expected = current[path] if use_current else historical[path]
                compiled = expected.split(marker)[0] + b"\n" if path == store else expected
                entry = manifest["sources"][variant][path]
                self.assertEqual((output / entry["full_snapshot"]).read_bytes(), expected)
                self.assertEqual((output / entry["compiled_snapshot"]).read_bytes(), compiled)
                self.assertEqual(entry["full_sha256"], CHECKPOINT.digest(expected))
                self.assertEqual(entry["compiled_sha256"], CHECKPOINT.digest(compiled))
                self.assertEqual(entry["origin"], "current-worktree" if use_current else "pinned-baseline")
                self.assertEqual(entry["source_revision"], "test-checkout" if use_current else CHECKPOINT.BASELINE)
                self.assertEqual(entry["differs_from_historical"], expected != historical[path])
        for path, data in harness.items():
            self.assertEqual((output / "sources" / Path(path).name).read_bytes(), data)
            self.assertEqual(manifest["harness_sha256"][path], CHECKPOINT.digest(data))
        return run, variants, harness

    def test_checkpoint_current_support_provenance_and_captured_test_symmetry(self):
        run, variants, harness = self.checkpoint(CHECKPOINT.CORE + [CHECKPOINT.PLAYER], True)
        summary = {}
        log = ("Test Suite 'PlaybackCheckpointIndexHintTests' passed at timestamp\n"
               "  Executed 6 tests, with 0 failures (0 unexpected)\n"
               "Test run with 22 tests in 3 suites passed")
        with patch.object(run, "command", return_value=log) as command:
            CHECKPOINT.test(run, variants, summary)
        self.assertEqual([call.args[1] for call in command.call_args_list], [
            "tests-baseline-debug", "tests-baseline-release",
            "tests-candidate-debug", "tests-candidate-release"])
        self.assertEqual(len(summary["tests"]), 4)
        for variant in variants:
            for path in CHECKPOINT.TESTS:
                self.assertEqual((run.output / "build" / f"{variant}-tests" / path).read_bytes(), harness[path])

    def test_checkpoint_historical_unchanged_support_is_accepted(self):
        self.checkpoint([CHECKPOINT.PLAYER], False)

    def test_checkpoint_each_historical_support_drift_is_rejected(self):
        for path in CHECKPOINT.CORE:
            with self.subTest(path=path), tempfile.TemporaryDirectory() as directory:
                self.root = Path(directory)
                with self.assertRaisesRegex(RuntimeError, "Unrelated benchmark dependency changed"):
                    self.checkpoint([path], False)

    def test_checkpoint_historical_full_source_guard_includes_uncompiled_suffix(self):
        with self.assertRaisesRegex(RuntimeError, "Unrelated benchmark dependency changed"):
            self.checkpoint([], False, suffix_drift=True)

    def test_checkpoint_extraction_rejects_missing_or_duplicate_boundary(self):
        for mode in (False, True):
            for count in (0, 2):
                with self.subTest(regression=mode, count=count), tempfile.TemporaryDirectory() as directory:
                    self.root = Path(directory)
                    with self.assertRaisesRegex(RuntimeError, "extraction boundary changed"):
                        self.checkpoint([], mode, boundary_count=count)

    def test_checkpoint_missing_test_execution_is_rejected(self):
        for log in ("", "Test run with 0 tests passed", "Test run with 22 tests passed",
                    "Test Suite 'PlaybackCheckpointIndexHintTests' passed\n"
                    "Executed 5 tests, with 0 failures\nTest run with 22 tests passed"):
            with self.subTest(log=log), tempfile.TemporaryDirectory() as directory:
                self.root = Path(directory)
                run, variants, _ = self.checkpoint([], True)
                with patch.object(run, "command", return_value=log), self.assertRaises(RuntimeError):
                    CHECKPOINT.test(run, variants, {})

    def test_checkpoint_regression_measurement_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, "cannot qualify historical performance"):
            CHECKPOINT.measure(None, None, argparse.Namespace(regression_only=True), {})
        with patch.object(CHECKPOINT.sys, "argv", ["run.py", "--output", str(self.root / "out"),
                          "--regression-only", "--mode", "benchmark"]):
            with self.assertRaises(SystemExit) as error:
                CHECKPOINT.main()
        self.assertEqual(error.exception.code, 2)
        self.assertFalse((self.root / "out").exists())

    def test_checkpoint_regression_defaults_to_tests_without_build_or_measure(self):
        output = self.root / "out"
        with ExitStack() as stack:
            stack.enter_context(patch.object(CHECKPOINT.sys, "argv", [
                "run.py", "--output", str(output), "--regression-only"]))
            stack.enter_context(patch.object(CHECKPOINT.shutil, "which", return_value="swift"))
            stack.enter_context(patch.object(CHECKPOINT.Run, "command", return_value="fixture"))
            stage = stack.enter_context(patch.object(CHECKPOINT, "stage", return_value={}))
            test = stack.enter_context(patch.object(CHECKPOINT, "test"))
            for name in ("build", "measure"):
                stack.enter_context(patch.object(CHECKPOINT, name, side_effect=AssertionError("No timing")))
            CHECKPOINT.main()
            self.assertTrue(stage.call_args.args[2])
            test.assert_called_once()
        for name in ("summary.json", "manifest.json"):
            value = json.loads((output / name).read_text())
            self.assertEqual(value["qualification"], "current-support-regression")
            self.assertFalse(value["performance_measured"])
        self.assertEqual(json.loads((output / "summary.json").read_text())["mode"], "tests")


if __name__ == "__main__":
    unittest.main()
