# Illiquid native dependency source package

This companion package supplies source inputs for the 20 components behind the
26 non-system runtime libraries recorded in `source-manifest.json`. It also
contains the two pinned Swift build/test dependency sources, GLib's
GObject-introspection build resource, installed Homebrew recipes and sanitized
installation receipts. Original library SHA-256 values identify inputs before
Illiquid's install-name rewriting and signing. Consult the project's
`Scripts/native-dependencies.lock.json` and release bundle provenance as well.

## Verification and scope

From the matching Illiquid source repository:

```sh
python3 Scripts/verify-corresponding-source.py /path/to/illiquid-redistribution
```

All downloaded release archives are bound to the installed recipe checksums.
x264 is a snapshot of commit `b35605ace3ddf7c1a5d67a2eb553f034aef41d55`
from the GitHub mirror, with its own recorded archive checksum. GLib's missing
patch was recovered from Homebrew core commit
`ff1e14952dfa8b4f7f46250dfa15189e79f9d68e`; that historical formula matches
the installed recipe after removing bottle/livecheck metadata and blank lines.
All four OpenSSL patches are present with their installed-recipe checksums.
Recipe `inreplace` edits and all configure/build/install commands are preserved.

Some upstream source archives contain font test corpora. This package omits font
binaries and files inside upstream test-font directories; each omitted member is
listed in the manifest. The runtime library source and build scripts remain
unchanged. Original archive checksums and modified build-source archive
checksums are distinguished. These corpora are not inputs to the runtime builds;
font-corpus tests cannot run from this package. Separately downloaded formula
font/media test assets and Linux-only Perl resources are excluded. Their URLs
remain in the original recipes for reference and are not redistribution grants.
Do not run `brew test` or Linux builds against those excluded resources.

The project's fixture generator uses its own pinned Noto Sans font and includes
its OFL notice. No macOS font or generated fixture media is supplied here.

## Rebuild on macOS

Use a separate macOS 26 ARM64 build machine, full Xcode including the Metal
Toolchain, and Homebrew. Installation receipts record Homebrew 6.0.4, upstream
compiler/build-host metadata and runtime package versions. Xcode/SDK, Apple
system libraries, Homebrew, make, Meson, Ninja, CMake, Python, pkgconf and other
general build tools are external prerequisites. Recipes describe their required
build dependencies. Non-distributed helper libraries such as Cairo, ICU,
libunistring and json-c may be needed for tools in an upstream package even when
not linked into the distributed runtime library; Homebrew resolves those.

Prepare a local source-only tap and serve this package without altering the
installed formulas:

```sh
python3 prepare-build-tap.py /tmp/illiquid-source-tap
cd /tmp/illiquid-source-tap
git init
git add .
git -c user.name=Jagalite -c user.email=Jagalite@users.noreply.github.com \
  commit -m 'Pinned Illiquid dependency build recipes'
brew tap --custom-remote jagalite/illiquid-source file:///tmp/illiquid-source-tap
# In a separate terminal, from this companion package directory:
python3 -m http.server 8765 --bind 127.0.0.1
# On the isolated build machine:
HOMEBREW_NO_AUTO_UPDATE=1 brew install --build-from-source \
  jagalite/illiquid-source/ffmpeg jagalite/illiquid-source/libass
```

The tap generator verifies checksums, binds archive and patch URLs to the local
server, updates archive checksums where font corpora were excluded, and qualifies
included dependency names. The original installed recipes remain unmodified in
`recipes/`. The GLib patch's `@@HOMEBREW_PREFIX@@` tokens are expanded by
Homebrew's patch DSL. The generator does not install anything itself. Preserve
its tap and build logs with a release's provenance. A tar-based x264 rebuild can
have a different Git-derived version string; fetch the exact recorded Git commit
with full upstream history when identical Git-derived version metadata matters.

After installing the rebuilt dependencies, use the project's BUILDING and
DISTRIBUTING instructions to build Illiquid. The original native input lock will
normally reject freshly compiled binary hashes. Review the new native closure,
collect notices/source for any newly distributed versions or libraries, qualify
playback, then deliberately refresh the lock. Do not bypass its checks to label
the old binary as a rebuild. This package was integrity-checked and its patch
application and generated recipe syntax validated; all 20 dependencies have not
been rebuilt or proven byte-identical to the original Homebrew bottles.

## Distribution

Publish this archive beside a matching binary and the matching Illiquid source
archive, with checksums and an explicit source download link. A local package or
an upstream homepage alone does not make source available to binary recipients.
Keep these exact archives available for every binary release they accompany.
The project source supplies complete original code and app build/installation
scripts; this package supplies its dependency sources and recipes. Third-party
licenses remain their own. The project retains copyright/license documents under
`Licenses/ThirdParty/`; these must also accompany the binary. This package contains
upstream OpenSSL and GLib test keys/certificates: they are public test data, not Illiquid
credentials, and must never be used as production secrets.

Upstream rendered PDFs and font-bearing fuzz corpora are also omitted; the
manifest records every excluded member. These artifacts are not runtime build
inputs. All retained source files remain byte-identical to their upstream inputs.

Non-code upstream images/media are omitted as well, with every omission listed.
The local tap disables Graphite2's font-corpus harness and skips libpng's image
test step; its original installed recipes are retained for comparison. Runtime
source and library build/install commands remain otherwise unchanged. These
exclusions restrict upstream asset/test coverage, rather than project playback tests.

The generated HarfBuzz recipe explicitly disables optional rendered documentation
so that omitted artwork is not required by an installed gtk-doc tool.
