#!/usr/bin/env python3
"""Fail closed if production declarations move across the staging boundary."""
import importlib.util
from pathlib import Path
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("checkpoint_membership_runner", HERE / "run.py")
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class SessionSourceBoundaryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = (runner.ROOT / "Sources/IlliquidCore/Persistence/PlaybackSessionStore.swift").read_bytes()

    def test_current_production_record_and_protocol_are_copied_verbatim(self):
        result = runner.session_api(self.source)
        self.assertEqual(result, self.source.split(runner.SESSION_BOUNDARY)[0] + b"\n")
        self.assertIn(b"public struct PlaybackSessionRecord:", result)
        self.assertIn(b"public protocol PlaybackSessionStoring:", result)
        self.assertNotIn(b"public final class AtomicPlaybackSessionStore:", result)

    def test_missing_boundary_is_rejected(self):
        with self.assertRaises(ValueError):
            runner.session_api(self.source.replace(runner.SESSION_BOUNDARY, b"\n", 1))

    def test_duplicate_boundary_is_rejected(self):
        with self.assertRaises(ValueError):
            runner.session_api(self.source + runner.SESSION_BOUNDARY)

    def test_lost_storage_protocol_is_rejected(self):
        with self.assertRaises(ValueError):
            runner.session_api(self.source.replace(b"public protocol PlaybackSessionStoring:", b"protocol RemovedStoring:", 1))

    def test_moved_atomic_store_declaration_is_rejected(self):
        with self.assertRaises(ValueError):
            runner.session_api(self.source.replace(b"public final class AtomicPlaybackSessionStore:", b"public final class RenamedStore:", 1))


if __name__ == "__main__":
    unittest.main()
