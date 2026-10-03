# Pinned native build inputs

This SDK is for the disposable GitHub macOS 26 ARM64 release runner. It is a
minimal snapshot of the reviewed Homebrew dylibs, headers, pkg-config metadata
and FFmpeg CLI, not an app download or a local Homebrew installer.

`native-sdk.json` records all member hashes and binds this archive to the
matching upstream source manifest in `DependencySources/`. Native dependency
versions and individual terms are documented in `THIRD_PARTY_NOTICES.md` and
`Licenses/`; the matching source, recipes and patches are in `DependencySources/`.
The original project GPL license does not replace upstream dependency licenses.

Verify without installing:

```sh
ILLIQUID_VERIFY_SDK_ONLY=1 python3 Scripts/install-ci-native-sdk.py
```

The CI installer validates the archive, member inventory and safe paths before
replacing only these reviewed kegs on the ephemeral hosted runner. App assembly
then separately checks the original native lock, rewrites runtime paths and
signs the embedded libraries. A dependency source rebuild is not yet qualified.

`system-pkgconfig/` describes the zlib and bzip2 already supplied by the macOS
SDK/system, for transitive pkg-config discovery. It contains no Apple binaries
or headers and does not select extra Homebrew copies of these libraries.
