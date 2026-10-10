import copy
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import subprocess
import sys
import unittest

spec = importlib.util.spec_from_file_location("installed_state", Path(__file__).with_name("installed_state.py"))
state = importlib.util.module_from_spec(spec)
spec.loader.exec_module(state)


class InstalledStateTests(unittest.TestCase):
    def fixture(self, root, label, executable=b"old executable", position=42, sign=False):
        app = root / f"{label}.app"
        (app / "Contents/MacOS").mkdir(parents=True)
        (app / "Contents/MacOS/Illiquid").write_bytes(executable)
        (app / "Contents/MacOS/Illiquid").chmod(0o755)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleExecutable": "Illiquid", "CFBundleIdentifier": "test.illiquid",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": label, "CFBundleVersion": label,
        }))
        package = root / f"{label}.zip"
        package.write_bytes(label.encode())
        preferences = root / f"{label}.plist"
        preferences.write_bytes(plistlib.dumps({"Illiquid.volume": 25,
            "Illiquid.history": json.dumps({"track": {"title": "Main"}}).encode()}))
        session = root / f"{label}.json"
        session.write_text(json.dumps({"position": position, "playlist": ["a.mkv", "b.mkv"]}))
        if sign:
            subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(app)],
                           check=True, capture_output=True)
        return state.snapshot(app, package, {"current": preferences}, {"current": session})

    def test_rejects_same_executable_despite_changed_build_numbers(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaisesRegex(ValueError, "Same executable"):
                state.compare(self.fixture(root, "1"), self.fixture(root, "2"))

    @unittest.skipUnless(sys.platform == "darwin", "requires real macOS Mach-O signing")
    def test_resigned_version_bump_has_same_payload_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "fixture.c"
            source.write_text("int main(void) { return 0; }\n")
            executable = root / "fixture"
            subprocess.run(["/usr/bin/clang", str(source), "-o", str(executable)], check=True, capture_output=True)
            code = executable.read_bytes()
            before = self.fixture(root, "1", code, sign=True)
            after = self.fixture(root, "2", code, sign=True)
            self.assertNotEqual(before["application"]["executable_sha256"], after["application"]["executable_sha256"])
            self.assertEqual(before["application"]["payload_sha256"], after["application"]["payload_sha256"])
            with self.assertRaisesRegex(ValueError, "Same executable payload"):
                state.compare(before, after)

    def test_distinct_artifacts_preserve_state_and_allow_new_fields(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            before = self.fixture(root, "1")
            after = self.fixture(root, "2", b"new executable")
            after["state"]["preferences"]["current"]["Illiquid.history"]["$json_data"]["track"]["trackID"] = 2
            self.assertEqual(state.compare(before, after), [])

    def test_detects_changed_resume_state(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            failures = state.compare(self.fixture(root, "1"), self.fixture(root, "2", b"new", position=0))
            self.assertEqual(failures, ["state.sessions.current.position: value/type changed"])

    def test_missing_keys_reordered_playlists_and_boolean_type_changes_fail(self):
        self.assertTrue(state.differences({"x": 1}, {}))
        self.assertTrue(state.differences(["a", "b"], ["b", "a"]))
        self.assertTrue(state.differences(True, 1))

    def test_additional_migration_expectations_are_required_when_provided(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            before, after = self.fixture(root, "1"), self.fixture(root, "2", b"new")
            expected = {"preferences": {"current": {"Illiquid.migrated": True}}}
            self.assertTrue(state.compare(before, after, expected))
            after["state"]["preferences"]["current"]["Illiquid.migrated"] = True
            self.assertEqual(state.compare(before, after, expected), [])

    def test_rejects_reused_package(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            before, after = self.fixture(root, "1"), self.fixture(root, "2", b"new")
            after["package"] = copy.deepcopy(before["package"])
            with self.assertRaisesRegex(ValueError, "Same package"):
                state.compare(before, after)

    def test_binary_data_and_named_inputs_are_unambiguous(self):
        self.assertIn("$base64_data", state.canonical(b"\xff"))
        self.assertEqual(state.named_paths(["current=/tmp/file=1.plist"])["current"], Path("/tmp/file=1.plist"))
        with self.assertRaises(ValueError):
            state.named_paths(["same=a", "same=b"])


if __name__ == "__main__":
    unittest.main()
