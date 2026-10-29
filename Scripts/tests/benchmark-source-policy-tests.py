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


PLAYLIST = load("PlaylistDeduplication")
SUBTITLE = load("SubtitleCandidateStreaming")
CHECKPOINT = load("CheckpointConstruction")
IDENTITIES = load("CheckpointIdentities")


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

    def playlist(self, changed, regression_only, broken_boundary=False):
        historical = {p: (p + "\n").encode() for p in PLAYLIST.SOURCES}
        store = next(p for p in historical if p.endswith("PlaybackSessionStore.swift"))
        historical[store] = b"record\npublic protocol PlaybackSessionStoring: Sendable {\n}\n"
        current = dict(historical)
        for path in changed:
            current[path] = b"// current\n" + current[path]
        if broken_boundary:
            current[store] = b"no extraction boundary"
        self.write_current(current)
        output = self.root / "playlist"
        output.mkdir()
        run = PLAYLIST.Run(output)
        manifest = {"head": "test-checkout"}
        with patch.object(PLAYLIST, "ROOT", self.root), patch.object(
            PLAYLIST.subprocess, "check_output",
            side_effect=lambda args, **kwargs: historical[args[-1].split(":", 1)[1]],
        ):
            PLAYLIST.snapshots(run, manifest, regression_only)
        for variant in ("baseline", "candidate"):
            for path in PLAYLIST.SOURCES:
                entry = manifest[variant + "_sources"][path]
                expected = current[path] if variant == "candidate" or (
                    regression_only and not path.endswith("PlaylistMutation.swift")) else historical[path]
                self.assertEqual((output / entry["full_snapshot"]).read_bytes(), expected)
                self.assertEqual(entry["full_sha256"], PLAYLIST.digest(expected))
                self.assertEqual(entry["compiled_sha256"], PLAYLIST.digest(
                    (output / entry["compiled_snapshot"]).read_bytes()))
                self.assertEqual(entry["differs_from_historical"], expected != historical[path])
                use_current = variant == "candidate" or (
                    regression_only and not path.endswith("PlaylistMutation.swift"))
                self.assertEqual(entry["origin"], "current-worktree" if use_current else "pinned-baseline")
                self.assertEqual(entry["source_revision"], "test-checkout" if use_current else PLAYLIST.BASELINE)

    def test_playlist_current_support_and_complete_provenance(self):
        self.playlist(PLAYLIST.SOURCES, True)

    def test_playlist_historical_support_drift_is_rejected(self):
        for path in PLAYLIST.SOURCES:
            if path.endswith("PlaylistMutation.swift"):
                continue
            with self.subTest(path=path), tempfile.TemporaryDirectory() as directory:
                self.root = Path(directory)
                with self.assertRaisesRegex(RuntimeError, "Unrelated benchmark dependency changed"):
                    self.playlist([path], False)

    def test_playlist_historical_unchanged_support_is_accepted(self):
        self.playlist([p for p in PLAYLIST.SOURCES if p.endswith("PlaylistMutation.swift")], False)

    def test_playlist_regression_keeps_extraction_guard(self):
        with self.assertRaisesRegex(RuntimeError, "extraction boundary changed"):
            self.playlist([], True, broken_boundary=True)

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

    def subtitle(self, changed, regression_only, corrupt=None, unchanged_matcher=False):
        historical = {p: (p + "\n").encode() for p in SUBTITLE.SOURCES}
        current = dict(historical)
        matcher = next(p for p in historical if p.endswith("ExternalSubtitleMatcher.swift"))
        for path in changed:
            current[path] = b"// current\n" + current[path]
        if not unchanged_matcher:
            current[matcher] = b"// candidate\n" + current[matcher]
        self.write_current(current)
        baseline_dir = self.root / "historical"
        baseline_dir.mkdir()
        for path, data in historical.items():
            (baseline_dir / Path(path).name).write_bytes(data + (b"corruption" if path == corrupt else b""))
        args = argparse.Namespace(output=self.root / "subtitle", baseline_dir=baseline_dir,
                                  regression_only=regression_only)
        runner = SUBTITLE.Runner(args)
        runner.manifest["checkout_head"] = "test-checkout"
        harness = {name: b"fixture" for name in (
            "Harness.swift", "CHeapProbe/heap.c", "CHeapProbe/include/CHeapProbe.h")}
        with patch.object(SUBTITLE, "ROOT", self.root), patch.object(
            SUBTITLE, "SOURCES", {p: SUBTITLE.sha(data) for p, data in historical.items()}
        ), patch.object(runner, "command", side_effect=AssertionError("No subprocess allowed")):
            runner.snapshot_sources(harness)
        for variant in ("baseline", "candidate"):
            for path in historical:
                use_current = variant == "candidate" or (regression_only and path != matcher)
                expected = current[path] if use_current else historical[path]
                entry = runner.manifest["sources"][variant][path]
                self.assertEqual((runner.output / entry["snapshot"]).read_bytes(), expected)
                self.assertEqual(entry["sha256"], SUBTITLE.sha(expected))
                self.assertEqual(entry["differs_from_historical"], expected != historical[path])
                self.assertEqual(entry["origin"], "current-worktree" if use_current else "pinned-baseline")
                self.assertEqual(entry["source_revision"], "test-checkout" if use_current else SUBTITLE.BASELINE)
        if regression_only:
            with self.assertRaisesRegex(ValueError, "cannot qualify historical performance"):
                runner.measure()

    def test_subtitle_current_support_and_complete_provenance(self):
        self.subtitle(list(SUBTITLE.SOURCES), True)

    def test_subtitle_each_historical_support_drift_is_rejected(self):
        for path in SUBTITLE.SOURCES:
            if path.endswith("ExternalSubtitleMatcher.swift"):
                continue
            with self.subTest(path=path), tempfile.TemporaryDirectory() as directory:
                self.root = Path(directory)
                with self.assertRaisesRegex(ValueError, "A shared dependency changed"):
                    self.subtitle([path], False)

    def test_subtitle_pinned_hashes_checked_before_substitution(self):
        for mode in (False, True):
            for path in SUBTITLE.SOURCES:
                with self.subTest(regression=mode, path=path), tempfile.TemporaryDirectory() as directory:
                    self.root = Path(directory)
                    with self.assertRaisesRegex(ValueError, "Pinned baseline SHA-256 mismatch"):
                        self.subtitle([], mode, corrupt=path)

    def test_subtitle_unchanged_matcher_is_rejected_in_both_modes(self):
        for mode in (False, True):
            with self.subTest(regression=mode), tempfile.TemporaryDirectory() as directory:
                self.root = Path(directory)
                with self.assertRaisesRegex(ValueError, "Candidate matcher is unchanged"):
                    self.subtitle([], mode, unchanged_matcher=True)

    def test_subtitle_historical_unchanged_support_is_accepted(self):
        self.subtitle([], False)


class CheckpointIdentityPolicyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()

    def stage(self, regression, drift=None, mutate_after_capture=False):
        module = IDENTITIES
        current = {path: (path + " current\n").encode() for path in module.CORE}
        historical = {path: (path + " historical\n").encode() for path in module.CORE}
        # Only the reviewed natural-order support and focal implementation differ.
        for path in (module.CORE[0], module.CORE[2]):
            historical[path] = current[path]
        pins = {path: module.sha256(data) for path, data in current.items()}
        if drift:
            current[drift] += b"unreviewed"
        here = self.root / "Benchmarks/CheckpointIdentities"
        here.mkdir(parents=True)
        for name in ("Harness.swift", "run.py"):
            (here / name).write_bytes(b"captured harness")
        caller = "Sources/IlliquidPlayer/Player/PlaybackController.swift"
        for path, data in (current | {p: b"captured test" for p in module.TESTS} | {caller: b"caller"}).items():
            destination = self.root / path
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(data)
        args = argparse.Namespace(output=self.root / "out", baseline=module.BASELINE,
                                  regression_only=regression, swift="swift")
        runner = module.Runner(args)

        def capture(argv, *unused):
            self.assertEqual(argv[:2], ["git", "show"])
            if mutate_after_capture:
                for path in current:
                    (self.root / path).write_bytes(b"changed after capture")
            path = argv[-1].split(":", 1)[1]
            return historical.get(path, b"historical caller")

        with patch.object(module, "ROOT", self.root), patch.object(module, "HERE", here), \
                patch.object(module, "__file__", str(here / "run.py")), \
                patch.object(module, "REGRESSION_SHA256", pins), \
                patch.object(module.platform, "platform", return_value="policy-fixture"), \
                patch.object(runner, "command", return_value="fixture-head"), \
                patch.object(runner, "capture", side_effect=capture):
            runner.prepare()
        for path in module.CORE:
            self.assertEqual((runner.output / "historical" / path).read_bytes(), historical[path])
            for variant in module.VARIANTS:
                use_current = variant == "candidate" or (regression and path in module.CORE[:-1])
                expected = current[path] if use_current else historical[path]
                self.assertEqual((runner.output / variant / "Sources/IlliquidCore" / Path(path).name).read_bytes(), expected)
                self.assertEqual(runner.sources[variant]["repository_sources"][path], module.source_hashes(expected))
        for variant in module.VARIANTS:
            for path in module.TESTS:
                self.assertEqual((runner.output / variant / path).read_bytes(), b"captured test")
        return runner

    def test_current_support_snapshot_symmetry_and_historical_focal_source(self):
        self.stage(True, mutate_after_capture=True)

    def test_historical_mode_still_rejects_support_drift(self):
        with self.assertRaisesRegex(AssertionError, "Unintended dependency difference"):
            self.stage(False)

    def test_each_unreviewed_current_source_is_rejected(self):
        for path in IDENTITIES.CORE:
            with self.subTest(path=path), tempfile.TemporaryDirectory() as temporary:
                self.root = Path(temporary).resolve()
                with self.assertRaisesRegex(AssertionError, "Unreviewed regression source"):
                    self.stage(True, drift=path)

    def test_regression_requires_pinned_baseline(self):
        args = argparse.Namespace(output=self.root / "out", baseline="0" * 40, regression_only=True)
        with self.assertRaisesRegex(ValueError, "pinned historical baseline"):
            IDENTITIES.Runner(args)
        self.assertFalse(args.output.exists())

    def test_regression_measure_and_sample_are_rejected(self):
        args = argparse.Namespace(output=self.root / "out", baseline=IDENTITIES.BASELINE, regression_only=True)
        runner = IDENTITIES.Runner(args)
        with self.assertRaisesRegex(ValueError, "cannot measure historical performance"):
            runner.measure()
        with self.assertRaisesRegex(ValueError, "cannot measure historical performance"):
            runner.sample("baseline", 1, "unchanged", 1)

    def test_main_regression_skips_timing_and_preserves_full_qualification(self):
        for regression in (False, True):
            with self.subTest(regression=regression), patch.object(IDENTITIES, "Runner") as constructor:
                argv = ["run.py", "--output", str(self.root / "out")]
                if regression:
                    argv.append("--regression-only")
                with patch.object(IDENTITIES.sys, "argv", argv):
                    IDENTITIES.main()
                runner = constructor.return_value
                runner.prepare.assert_called_once()
                runner.build_and_test.assert_called_once()
                runner.finish.assert_called_once()
                self.assertEqual(runner.measure.call_count, 0 if regression else 1)
                self.assertEqual(constructor.call_args.args[0].regression_only, regression)


if __name__ == "__main__":
    unittest.main()
