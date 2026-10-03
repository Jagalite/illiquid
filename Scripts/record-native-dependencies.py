#!/usr/bin/env python3
"""Record native build inputs and verify the reviewed direct/transitive input lock."""
import argparse
import ctypes
import hashlib
import json
import re
from pathlib import Path
import subprocess
import shutil
import tempfile


def run(*args):
    return subprocess.check_output(args, text=True, timeout=30).strip()


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def native_configuration(name, library):
    if name == "libass":
        return None  # libass has no public build-configuration string API.
    loaded = ctypes.CDLL(str(library))
    function = getattr(loaded, name.removeprefix("lib") + "_configuration")
    function.argtypes = []
    function.restype = ctypes.c_char_p
    return function().decode("utf-8")


def header_digest(name):
    root = Path(run("pkg-config", "--variable=includedir", name)) / ("ass" if name == "libass" else name)
    headers = sorted(root.rglob("*.h"))
    if not headers:
        raise ValueError("No public headers found for " + name)
    value = hashlib.sha256()
    for header in headers:
        value.update(str(header.relative_to(root)).encode() + b"\0")
        value.update(bytes.fromhex(digest(header)))
    return value.hexdigest()


def linked_libraries(path):
    return [re.split(r"\s+\(compatibility version", line.strip())[0]
            for line in run("otool", "-L", str(path)).splitlines()[1:] if line.strip()]


def system_library(reference):
    return reference.startswith(("/usr/lib/", "/System/Library/", "/Library/Apple/System/"))


def resolve_library(reference, owner, search_directories):
    if reference.startswith("@loader_path/"):
        candidates = [owner.parent / reference.removeprefix("@loader_path/")]
    elif reference.startswith("@rpath/"):
        # Standalone native-input collection has no executable runpath stack.
        # Reject ambiguity instead of choosing a different host library silently.
        name = reference.removeprefix("@rpath/")
        candidates = [directory / name for directory in search_directories]
    elif reference.startswith("/"):
        candidates = [Path(reference)]
    else:
        raise ValueError(f"Unresolved dependency {reference} in {owner}")
    resolved = {path.resolve(strict=True) for path in candidates if path.is_file()}
    if len(resolved) != 1:
        raise ValueError(f"Missing or ambiguous dependency {reference} in {owner}")
    return resolved.pop()


def library_inputs(paths):
    """Fingerprint original inputs, before install_name_tool or signing changes."""
    by_name = {}
    for path in paths:
        path = Path(path).resolve(strict=True)
        record = {"name": path.name, "sha256": digest(path),
                  "architectures": sorted(run("lipo", "-archs", str(path)).split()),
                  "library": str(path)}
        previous = by_name.get(path.name)
        if previous is not None and previous["sha256"] != record["sha256"]:
            raise ValueError("Conflicting library basename: " + path.name)
        by_name[path.name] = record
    return [by_name[name] for name in sorted(by_name)]


def native_library_closure(roots, search_directories):
    pending = [Path(path).resolve(strict=True) for path in roots]
    seen = set()
    while pending:
        owner = pending.pop()
        if owner in seen:
            continue
        seen.add(owner)
        if len(seen) > 512:
            raise ValueError("Native dependency closure exceeds 512 libraries")
        for reference in linked_libraries(owner):
            if not system_library(reference):
                pending.append(resolve_library(reference, owner, search_directories))
    return library_inputs(seen)


def dependency_lock(provenance):
    """Relocatable direct and transitive identities, without source-tree state."""
    return {
        "schemaVersion": 2,
        "architecture": provenance["architecture"],
        "packages": [{key: package[key] for key in (
            "package", "version", "sha256", "pkgConfigSHA256", "publicHeadersSHA256", "nativeConfiguration"
        )} for package in provenance["packages"]],
        "libraries": [{key: library[key] for key in ("name", "sha256", "architectures")}
                      for library in provenance["nativeLibraryInputs"]],
    }


def verify_lock(provenance, expected):
    actual = dependency_lock(provenance)
    if expected == actual:
        return
    expected_packages = {item["package"]: item for item in expected.get("packages", [])}
    actual_packages = {item["package"]: item for item in actual["packages"]}
    changed = sorted(name for name in expected_packages.keys() | actual_packages.keys()
                     if expected_packages.get(name) != actual_packages.get(name))
    if expected.get("architecture") != actual["architecture"]:
        changed.insert(0, "architecture")
    if expected.get("schemaVersion") != actual["schemaVersion"]:
        changed.insert(0, "lock schema")
    expected_libraries = {item["name"]: item for item in expected.get("libraries", [])}
    actual_libraries = {item["name"]: item for item in actual["libraries"]}
    changed.extend(sorted(name for name in expected_libraries.keys() | actual_libraries.keys()
                          if expected_libraries.get(name) != actual_libraries.get(name)))
    raise ValueError("Native dependency lock mismatch: " + ", ".join(changed)
                     + ". Review and qualify changed inputs before explicitly refreshing the lock.")


def collect(bundle=None, input_libraries=None):
    root = Path(__file__).resolve().parent.parent
    packages = []
    for name in ("libavformat", "libavfilter", "libavcodec", "libavutil", "libswscale", "libswresample", "libass"):
        library = Path(run("pkg-config", "--variable=libdir", name)) / (name + ".dylib")
        pc = Path(run("pkg-config", "--variable=pcfiledir", name)) / (name + ".pc")
        packages.append({
            "package": name, "version": run("pkg-config", "--modversion", name),
            "cflags": run("pkg-config", "--cflags", name),
            "linkFlags": run("pkg-config", "--libs", name),
            "library": str(library.resolve(strict=True)), "sha256": digest(library),
            "pkgConfigSHA256": digest(pc),
            "publicHeadersSHA256": header_digest(name),
            "nativeConfiguration": native_configuration(name, library),
            "linkedLibraries": run("otool", "-L", str(library)).splitlines()[1:],
        })
    result = {
        "schemaVersion": 1,
        "purpose": "Native build provenance; versions and hashes must be compared across release hosts.",
        "sourceRevision": run("git", "-C", str(root), "rev-parse", "HEAD"),
        "sourceDirty": bool(run("git", "-C", str(root), "status", "--porcelain")),
        "trackedDiffSHA256": hashlib.sha256(subprocess.check_output(
            ["git", "-C", str(root), "diff", "HEAD", "--binary"], timeout=30
        )).hexdigest(),
        "untrackedSourceHashes": {
            name: digest(root / name)
            for name in subprocess.check_output(
                ["git", "-C", str(root), "ls-files", "--others", "--exclude-standard", "-z",
                 "--", "Sources", "Tests", "Scripts", "Resources", "Package.swift"], timeout=30
            ).decode().split("\0") if name and (root / name).is_file()
        },
        "architecture": run("uname", "-m"), "macOS": run("sw_vers", "-productVersion"),
        "swift": run("swift", "--version"), "sdk": run("xcrun", "--show-sdk-version"),
        "ffmpegCLIExecutable": str(Path(shutil.which("ffmpeg")).resolve(strict=True)),
        "ffmpegCLIConfiguration": run("ffmpeg", "-hide_banner", "-buildconf"),
        "packages": packages,
    }
    result["nativeLibraryInputs"] = library_inputs(input_libraries) if input_libraries else native_library_closure(
        [package["library"] for package in packages],
        sorted({Path(package["library"]).parent for package in packages}
               | {Path("/opt/homebrew/lib"), Path("/usr/local/lib")}),
    )
    if bundle:
        framework_root = bundle / "Contents" / "Frameworks"
        if not framework_root.is_dir():
            raise ValueError("Bundle has no Contents/Frameworks directory")
        result["bundledLibrariesBeforeSigning"] = [
            {"name": path.name, "sha256": digest(path)}
            for path in sorted(framework_root.glob("*.dylib"))
        ]
        bundled_names = {item["name"] for item in result["bundledLibrariesBeforeSigning"]}
        input_names = {item["name"] for item in result["nativeLibraryInputs"]}
        if bundled_names != input_names:
            raise ValueError("Bundle/input library inventory mismatch: " + ", ".join(sorted(bundled_names ^ input_names)))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--bundle", type=Path)
    parser.add_argument("--input-library", type=Path, action="append",
                        help="Original library copied by packaging; repeat for its complete input closure")
    parser.add_argument("--verify-lock", type=Path)
    parser.add_argument("--write-lock", type=Path,
                        help="Explicitly refresh the reviewed native-input lock; does not qualify a build")
    args = parser.parse_args()
    value = collect(args.bundle, args.input_library)
    if args.verify_lock:
        verify_lock(value, json.loads(args.verify_lock.read_text()))
    if args.write_lock:
        args.write_lock.write_text(json.dumps(dependency_lock(value), indent=2, sort_keys=True) + "\n")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", dir=args.output.parent, delete=False) as stream:
            temporary = Path(stream.name)
            json.dump(value, stream, indent=2, sort_keys=True)
            stream.write("\n")
        temporary.replace(args.output)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
