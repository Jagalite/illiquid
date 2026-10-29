#!/usr/bin/env python3
"""Source-policy controls only: no Swift, compiler, Git or network commands."""
import argparse
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


if __name__ == "__main__":
    unittest.main()
