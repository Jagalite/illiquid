#!/usr/bin/env python3
"""Check the release-input gate without depending on installed native libraries."""
import copy
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch
import tempfile

spec = importlib.util.spec_from_file_location(
    "native_provenance", Path(__file__).resolve().parents[1] / "record-native-dependencies.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class DependencyLockTests(unittest.TestCase):
    def setUp(self):
        self.provenance = {"architecture": "arm64", "sourceRevision": "example", "packages": [{
            "package": "libavcodec", "version": "62", "sha256": "binary",
            "pkgConfigSHA256": "flags", "publicHeadersSHA256": "headers",
            "nativeConfiguration": "--enable-decoder=test", "library": "/host/path/libavcodec.dylib",
        }], "nativeLibraryInputs": [{"name": "libcodec.1.dylib", "sha256": "transitive",
                                     "architectures": ["arm64"], "library": "/host/libcodec.1.dylib"}]}

    def test_source_and_install_location_do_not_change_input_identity(self):
        expected = module.dependency_lock(self.provenance)
        self.provenance["sourceRevision"] = "new-code"
        self.provenance["packages"][0]["library"] = "/another/path/libavcodec.dylib"
        self.provenance["nativeLibraryInputs"][0]["library"] = "/another/path/libcodec.1.dylib"
        module.verify_lock(self.provenance, expected)

    def test_binary_header_flags_and_configuration_changes_are_rejected(self):
        expected = module.dependency_lock(self.provenance)
        for field in ("version", "sha256", "pkgConfigSHA256", "publicHeadersSHA256", "nativeConfiguration"):
            with self.subTest(field=field):
                changed = copy.deepcopy(self.provenance)
                changed["packages"][0][field] = "changed"
                with self.assertRaisesRegex(ValueError, "libavcodec"):
                    module.verify_lock(changed, expected)

    def test_missing_package_or_different_architecture_is_rejected(self):
        expected = module.dependency_lock(self.provenance)
        changed = copy.deepcopy(self.provenance)
        changed["packages"] = []
        with self.assertRaisesRegex(ValueError, "libavcodec"):
            module.verify_lock(changed, expected)

        changed = copy.deepcopy(self.provenance)
        changed["architecture"] = "x86_64"
        with self.assertRaisesRegex(ValueError, "architecture"):
            module.verify_lock(changed, expected)

    def test_transitive_changes_additions_and_removals_are_rejected(self):
        expected = module.dependency_lock(self.provenance)
        for field in ("sha256", "architectures", "name"):
            with self.subTest(field=field):
                changed = copy.deepcopy(self.provenance)
                changed["nativeLibraryInputs"][0][field] = "changed"
                with self.assertRaisesRegex(ValueError, "libcodec.1.dylib"):
                    module.verify_lock(changed, expected)
        changed = copy.deepcopy(self.provenance)
        changed["nativeLibraryInputs"] = []
        with self.assertRaisesRegex(ValueError, "libcodec.1.dylib"):
            module.verify_lock(changed, expected)
        changed = copy.deepcopy(self.provenance)
        changed["nativeLibraryInputs"].append({"name": "extra.dylib", "sha256": "extra", "architectures": ["arm64"]})
        with self.assertRaisesRegex(ValueError, "extra.dylib"):
            module.verify_lock(changed, expected)

    def test_closure_cycles_system_references_and_loader_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            first, second = root / "first.dylib", root / "second.dylib"
            first.write_bytes(b"first")
            second.write_bytes(b"second")
            references = {first: [str(first), "@loader_path/second.dylib", "/usr/lib/libSystem.B.dylib"],
                          second: [str(first)]}
            with patch.object(module, "linked_libraries", side_effect=lambda path: references[path]), \
                 patch.object(module, "run", return_value="arm64"):
                result = module.native_library_closure([first], [root])
            self.assertEqual([item["name"] for item in result], ["first.dylib", "second.dylib"])

    def test_ambiguous_rpath_and_conflicting_basename_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            one, two = root / "one", root / "two"
            one.mkdir()
            two.mkdir()
            first, second = one / "same.dylib", two / "same.dylib"
            first.write_bytes(b"one")
            second.write_bytes(b"two")
            with self.assertRaisesRegex(ValueError, "ambiguous"):
                module.resolve_library("@rpath/same.dylib", first, [one, two])
            with patch.object(module, "run", return_value="arm64"), \
                 self.assertRaisesRegex(ValueError, "Conflicting library basename"):
                module.library_inputs([first, second])
            second.unlink()
            self.assertEqual(module.resolve_library("@rpath/same.dylib", first, [one, two]), first)


if __name__ == "__main__":
    unittest.main()
