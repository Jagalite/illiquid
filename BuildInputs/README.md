# Pinned native build inputs

This SDK is for the disposable GitHub macOS 26 ARM64 release runner. It is a
minimal snapshot of the reviewed native dylibs, headers, pkg-config metadata
and FFmpeg CLI, not an app download or a local Homebrew installer. FFmpeg 8.1.2
is rebuilt from the pinned source with `--disable-coreimage`: its unused CoreImage
filters pulled OpenGL into the app. Other libraries retain their reviewed Homebrew
identities. Decoder, encoder and demuxer lists are unchanged.

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
signs the embedded libraries. Only FFmpeg has been rebuilt from source; this is
not a claim that every native dependency has been rebuilt.

`system-pkgconfig/` describes the zlib and bzip2 already supplied by the macOS
SDK/system, for transitive pkg-config discovery. It contains no Apple binaries
or headers and does not select extra Homebrew copies of these libraries.

To reproduce the FFmpeg variant locally without replacing Homebrew's active keg:

```sh
Scripts/build-native-ffmpeg.sh /opt/homebrew/Cellar/ffmpeg/8.1.2-illiquid1
export PKG_CONFIG_PATH=/opt/homebrew/Cellar/ffmpeg/8.1.2-illiquid1/lib/pkgconfig
export PATH=/opt/homebrew/Cellar/ffmpeg/8.1.2-illiquid1/bin:$PATH
Scripts/build-illiquid-app.sh --adhoc
```

The prefix must not already exist. A rebuild can produce different binary hashes;
packaging intentionally rejects any mismatch with the reviewed lock. The bundled
SDK is the exact locked input for CI. Build configuration and source binding are
recorded in `DependencySources/receipts/ffmpeg-illiquid-build.json`; the original
Homebrew recipe and the modified recipe are both retained.

The app build script prefers the reviewed FFmpeg prefix when it is installed
and `PKG_CONFIG_PATH` is unset. In that mode it also resolves transitive dylibs
from the SDK's pinned keg directories before following Homebrew's moving `opt`
links. The native-input hash lock still verifies the complete packaged closure;
this does not refresh the lock or modify installed Homebrew links. Explicit
toolchain selections remain respected. An OpenGL-linked host FFmpeg fails
preflight before compiling the app.
