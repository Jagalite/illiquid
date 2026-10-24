"""Compile/run preference controls without the product, GUI, or user domains.

Run through Kyoto because this compiles Swift. Product .build is untouched.
"""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("swiftc"), "requires macOS Swift SDK")
class PreferenceIsolationTests(unittest.TestCase):
    def test_production_preference_resolver_and_adapter(self):
        with tempfile.TemporaryDirectory(prefix="illiquid-preference-controls-") as temporary:
            executable = Path(temporary) / "preferences"
            result = subprocess.run([
                "swiftc", "-swift-version", "6", "-parse-as-library",
                str(ROOT / "Sources/IlliquidApp/App/AppPreferences.swift"),
                str(ROOT / "Sources/IlliquidApp/App/PlaybackChromePreferences.swift"),
                str(ROOT / "Sources/IlliquidApp/UI/PlayerInterfaceScale.swift"),
                str(HERE / "test_preferences_core.swift"), "-o", str(executable),
            ], capture_output=True, text=True, timeout=180)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("Preference controls passed:", result.stdout)
            print(result.stdout.strip())


if __name__ == "__main__":
    unittest.main()
