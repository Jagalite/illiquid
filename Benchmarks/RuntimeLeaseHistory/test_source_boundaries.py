#!/usr/bin/env python3
"""Qualify prepare() dependency boundaries without compiling Swift."""
from __future__ import annotations

import argparse
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

import run


class SourceBoundaryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="lease-source-boundary-")
        self.addCleanup(self.temporary.cleanup)
        directory = Path(self.temporary.name)
        self.root = directory / "repository"
        self.prefix = b"public enum ExecutorKind: String { case input }\n"
        self.baseline = {
            "metadata": b"// baseline runtime metadata\n",
            "identity": b"// identical identity source\n",
            "track": b"// identical media track source\n",
            "events": self.prefix + b"\npublic struct EffectResultKind: Codable {}\n",
        }
        for key, data in self.baseline.items():
            self.write_source(key, data)
        test_source = self.root / run.TEST_SOURCE
        test_source.parent.mkdir(parents=True, exist_ok=True)
        test_source.write_text("// identical focused tests\n")
        self.args = argparse.Namespace(
            output=directory / "output", baseline="baseline", swift=str(directory / "swift"))
        self.root_patch = mock.patch.object(run, "ROOT", self.root)
        self.command_patch = mock.patch.object(run, "command", self.command)
        self.root_patch.start()
        self.command_patch.start()
        self.addCleanup(self.root_patch.stop)
        self.addCleanup(self.command_patch.stop)

    def write_source(self, key: str, data: bytes) -> None:
        path = self.root / run.SOURCES[key]
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

    def command(self, args: list, output: Path) -> subprocess.CompletedProcess:
        # Only provenance lookups are stubbed. prepare() still reads, extracts,
        # hashes, writes, and validates every source and manifest on disk.
        if args[-1] == "--version":
            stdout = "source-boundary test compiler\n"
        elif args[0] == "xcrun":
            stdout = str(Path(self.args.swift).with_name("swiftc"))
        elif args[3] == "rev-parse":
            stdout = "candidate\n" if args[-1] == "HEAD" else "baseline\n"
        elif args[3] == "show":
            relative = args[-1].split(":", 1)[1]
            key = next(key for key, path in run.SOURCES.items() if path == relative)
            stdout = self.baseline[key].decode()
        else:
            raise AssertionError(f"Unexpected subprocess: {args}")
        return subprocess.CompletedProcess(args, 0, stdout, "")

    def test_uncompiled_remainder_can_differ_but_full_receipts_are_kept(self) -> None:
        candidate = self.baseline["events"] + b"// changed effect completion contract\n"
        self.write_source("events", candidate)
        manifest = run.prepare(self.args)
        hashes = manifest["source_sha256"]
        events_path = run.SOURCES["events"]
        self.assertNotEqual(hashes["baseline"][events_path], hashes["candidate"][events_path])
        self.assertEqual(hashes["baseline"]["ExecutorKind exact prefix"],
                         hashes["candidate"]["ExecutorKind exact prefix"])
        for variant, full in [("baseline", self.baseline["events"]), ("candidate", candidate)]:
            self.assertEqual((self.args.output / "production-sources" / variant / events_path).read_bytes(), full)
            compiled = self.args.output / variant / "Sources/IlliquidPlaybackCore/ExecutorKind.swift"
            self.assertEqual(compiled.read_bytes(), self.prefix + b"\n")
        self.assertEqual(run.prepare(self.args), manifest)

    def test_changed_compiled_prefix_is_rejected(self) -> None:
        self.write_source("events", self.baseline["events"].replace(b"case input", b"case output"))
        with self.assertRaisesRegex(ValueError, "Dependency changed.*ExecutorKind prefix"):
            run.prepare(self.args)

    def test_each_complete_compiled_dependency_must_match(self) -> None:
        for key in ["identity", "track"]:
            with self.subTest(dependency=key):
                self.args.output = Path(self.temporary.name) / f"output-{key}"
                self.write_source(key, self.baseline[key] + b"// changed\n")
                with self.assertRaisesRegex(ValueError, "Dependency changed"):
                    run.prepare(self.args)
                self.write_source(key, self.baseline[key])

    def test_missing_or_ambiguous_source_boundary_is_rejected(self) -> None:
        for index, candidate in enumerate([
            b"// prefix moved\n" + self.baseline["events"],
            self.prefix,
            self.baseline["events"] + b"\npublic struct EffectResultKind: Codable {}\n",
        ]):
            with self.subTest(boundary=index):
                self.args.output = Path(self.temporary.name) / f"output-boundary-{index}"
                self.write_source("events", candidate)
                with self.assertRaisesRegex(ValueError, "ExecutorKind source boundary changed"):
                    run.prepare(self.args)

    def test_resume_still_rejects_changes_to_the_uncompiled_remainder(self) -> None:
        run.prepare(self.args)
        self.write_source("events", self.baseline["events"] + b"// changed after preparation\n")
        with self.assertRaisesRegex(ValueError, "Candidate source changed after preparation"):
            run.prepare(self.args)


if __name__ == "__main__":
    unittest.main()
