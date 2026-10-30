#!/usr/bin/env python3
"""Portable source-policy negative controls; no native commands or builds."""
import importlib.util
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("auxiliary_runner", Path(__file__).with_name("run.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)

# Independent inventories: changes to the runner's allowlist or revision pins
# must not silently broaden what these negative controls accept.
BASELINE = "6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635"
TARGET = "c1ef6aff6060ad35decbc6dce0c224164be941a2"
FOCAL = {
    "Sources/IlliquidNativePlayback/Media/FFmpegDemuxer.swift",
    "Sources/IlliquidNativePlayback/Media/FFmpegInputExecutor.swift",
}
SUPPORT = {
    "Sources/IlliquidNativePlayback/Media/FFmpegPacket.swift",
    "Sources/IlliquidNativePlayback/Playback/PacketQueue.swift",
    "Sources/IlliquidNativePlayback/Playback/FixedRingBuffer.swift",
}
FONT = "Sources/IlliquidNativePlayback/Subtitles/FontAttachmentStore.swift"
C = "Sources/CFFmpeg/include/ffmpeg_shim.h"
SHARED = SimpleNamespace(FULL_SOURCES=sorted(FOCAL | SUPPORT | {FONT}),
                         C_SOURCES=[C], PRESENTATION="presentation.swift", BITMAP="bitmap.swift")


class SourcePolicyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        paths = SHARED.FULL_SOURCES + SHARED.C_SOURCES + [SHARED.PRESENTATION, SHARED.BITMAP]
        self.historical = {path: f"historical:{path}\n".encode() for path in paths}
        self.target = {path: f"font-policy-target:{path}\n".encode() for path in FOCAL}
        self.reviewed = {path: (runner.ROOT / path).read_bytes() for path in SUPPORT}
        self.current = {**self.historical, **self.target, **self.reviewed}
        for path, raw in self.current.items():
            target = self.root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(raw)
        self.subject = runner.Runner.__new__(runner.Runner)
        self.subject.args = SimpleNamespace(current_support_regression=True)
        self.subject.output = self.root / "output"
        self.subject.sources = {}
        self.subject.receipt = {}
        self.subject.observations = []

    def git_show(self, argv, cwd):
        self.assertEqual(argv[:2], ["git", "show"])
        revision, path = argv[2].split(":", 1)
        self.assertEqual(cwd, self.root)
        if revision == BASELINE:
            return self.historical[path]
        self.assertEqual(revision, TARGET)
        return self.target[path]

    def stage(self):
        with patch.object(runner, "ROOT", self.root), patch.object(
                runner.subprocess, "check_output", side_effect=self.git_show):
            return self.subject.prepare_sources(SHARED)

    def change(self, path):
        (self.root / path).write_bytes(b"changed current support\n")

    def test_fixed_policy_inventory(self):
        self.assertEqual(runner.BASELINE, BASELINE)
        self.assertEqual(runner.REGRESSION_TARGET, TARGET)
        self.assertEqual(runner.FOCAL, FOCAL)
        self.assertEqual(set(runner.CURRENT_SUPPORT), SUPPORT)
        for path in SUPPORT:
            self.assertEqual(runner.CURRENT_SUPPORT[path], runner.sha(self.reviewed[path]))

    def test_current_support_is_identical_and_historical_archive_is_retained(self):
        staged = self.stage()
        for path in SUPPORT:
            self.assertEqual(staged["baseline"][path], self.reviewed[path].decode())
            self.assertEqual(staged["baseline"][path], staged["candidate"][path])
            self.assertEqual((self.subject.output / "sources/baseline" / path).read_bytes(), self.historical[path])
        overrides = {row["path"]: row for row in self.subject.receipt["support_overrides"]}
        self.assertEqual(set(overrides), SUPPORT)
        for path in SUPPORT:
            self.assertEqual(overrides[path]["historical_sha256"], runner.sha(self.historical[path]))
            self.assertEqual(overrides[path]["both_arms_sha256"], runner.sha(self.reviewed[path]))
        for path in FOCAL:
            self.assertEqual(staged["baseline"][path].encode(), self.historical[path])
            self.assertEqual(staged["candidate"][path].encode(), self.target[path])
            self.assertNotEqual(staged["baseline"][path], staged["candidate"][path])

    def test_strict_historical_rejects_each_support_drift(self):
        self.subject.args.current_support_regression = False
        for path in SUPPORT:
            with self.subTest(path=path):
                self.change(path)
                with self.assertRaisesRegex(ValueError, "Unrelated production dependency changed"):
                    self.stage()
                (self.root / path).write_bytes(self.historical[path])

    def test_strict_historical_accepts_unchanged_support_without_overrides(self):
        self.subject.args.current_support_regression = False
        for path in SUPPORT:
            (self.root / path).write_bytes(self.historical[path])
        staged = self.stage()
        self.assertNotIn("support_overrides", self.subject.receipt)
        self.assertEqual(self.subject.receipt["comparison_mode"], "strict-historical")
        for path in SUPPORT:
            self.assertEqual(staged["baseline"][path].encode(), self.historical[path])

    def test_regression_rejects_unrelated_font_and_c_support_drift(self):
        for path in (FONT, C):
            with self.subTest(path=path):
                self.change(path)
                with self.assertRaisesRegex(ValueError, "Unrelated production dependency changed"):
                    self.stage()
                (self.root / path).write_bytes(self.historical[path])

    def test_noop_baseline_substitution_or_changed_target_is_rejected(self):
        for path in FOCAL:
            for value in (self.historical[path], b"modified focal implementation\n"):
                with self.subTest(path=path, value=value):
                    (self.root / path).write_bytes(value)
                    with self.assertRaisesRegex(ValueError, "Pinned regression target changed"):
                        self.stage()
                    (self.root / path).write_bytes(self.target[path])

    def test_unreviewed_support_is_rejected(self):
        for path in SUPPORT:
            with self.subTest(path=path):
                self.change(path)
                with self.assertRaisesRegex(ValueError, "Reviewed regression support changed"):
                    self.stage()
                (self.root / path).write_bytes(self.reviewed[path])

    def test_timing_is_rejected_before_any_native_command(self):
        with self.assertRaisesRegex(ValueError, "Timing is prohibited"):
            self.subject.invoke("candidate", {}, "timing", "auxiliary", 1, 1, "forbidden")
        self.subject.observations = [{"mode": "timing"}]
        with self.assertRaisesRegex(ValueError, "Timing observations cannot qualify"):
            self.subject.summarize()


if __name__ == "__main__":
    unittest.main(verbosity=2)
