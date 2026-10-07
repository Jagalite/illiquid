# Third-party notices

Illiquid uses FFmpeg, libass and their non-system runtime dependencies. Each
component retains its copyright and license terms. The collection under
`Licenses/ThirdParty/` includes unchanged installed notices and 114 additional
copyright, license, author and patent documents from the matching upstream
sources, including nested component notices. Source-file copyright/license
headers remain in the companion source archives.

[The dependency inventory](Licenses/dependency-inventory.json) identifies exact
versions, original library hashes and collected document hashes. The
[corresponding-source manifest](Licenses/corresponding-source-manifest.json)
identifies source archives, recipe hashes, patches and intentionally excluded
upstream test-font assets. Build/test revisions also appear in `Package.resolved`.

| Component | Version | Runtime license / notice location |
| --- | --- | --- |
| FFmpeg | 8.1.2 | GPL-3.0-or-later build; `ffmpeg/upstream/LICENSE.md` and GPL/LGPL texts |
| libass | 0.17.5 | ISC; `libass/upstream/COPYING` |
| dav1d | 1.5.3 | BSD-2-Clause; `dav1d/upstream/COPYING` |
| FreeType | 2.14.3 | FreeType License (FTL); `freetype/upstream/docs/FTL.TXT`, GPL alternative and component notices |
| FriBidi | 1.0.16 | LGPL-2.1-or-later library; `fribidi/upstream/COPYING` |
| gettext/libintl | 1.0 | LGPL-2.1-or-later libintl; `gettext/upstream/gettext-runtime/intl/COPYING.LIB`; other upstream tools retain GPL terms |
| GLib | 2.88.2 | LGPL-2.1-or-later with per-file terms; `glib/upstream/COPYING` and `LICENSES/` |
| Graphite2 | 1.3.15 | LGPL/GPL/MPL/MIT alternatives described in `graphite2/upstream/LICENSE` and `COPYING` |
| HarfBuzz | 14.2.1 | MIT; `harfbuzz/upstream/COPYING`, nested notices |
| LAME | 3.100 | LGPL-2.0-or-later; `lame/upstream/COPYING` and `LICENSE` |
| libpng | 1.6.58 | libpng license; `libpng/upstream/LICENSE`, nested notices |
| libunibreak | 7.0 | zlib; `libunibreak/upstream/LICENCE` |
| libvmaf | 3.1.0 | BSD-2-Clause-Patent; `libvmaf/upstream/LICENSE` |
| libvpx | 1.16.0 | BSD-3-Clause; `libvpx/upstream/LICENSE`, PATENTS and nested notices |
| OpenSSL | 3.6.3 | Apache-2.0; `openssl@3/upstream/LICENSE.txt`, nested notices |
| Opus | 1.6.1 | BSD-3-Clause and included component terms; `opus/upstream/COPYING` |
| PCRE2 | 10.47 (package revision 1) | BSD-3-Clause and included component terms; `pcre2/upstream/LICENCE.md`, COPYING, SLJIT notice |
| SVT-AV1 | 4.1.0 | BSD-3-Clause/BSD-2-Clause components; `svt-av1/upstream/LICENSE.md`, LICENSE-BSD2.md and PATENTS.md |
| x264 | r3222, b35605a | GPL-2.0-or-later; `x264/upstream/COPYING` |
| x265 | 4.2 | GPL-2.0-or-later and nested component terms; `x265/upstream/COPYING` |

Paths in the table are relative to `Licenses/ThirdParty/`. The original native
closure has 26 libraries across these 20 components. Runtime license summaries
do not replace per-file terms. FFmpeg enables `--enable-gpl` and
`--enable-version3`, without `--enable-nonfree`; see its recorded configuration
and [upstream licensing guidance](https://ffmpeg.org/legal.html).

Portions of this software are copyright © 1996–2026 The FreeType Project
(https://freetype.org). All rights reserved.

Swift Testing and Swift Syntax are build/test dependencies under Apache 2.0 with
the Swift runtime library exception. Their license texts and available notice
are under `Licenses/ThirdParty/`, and exact pinned source archives accompany the
native source package. Homebrew recipes retain Homebrew core's BSD-2-Clause
license in `homebrew-core-LICENSE.txt` and the companion `recipes/LICENSE.txt`.

The fixture font is unmodified Noto Sans, pinned in
`TestFixtures/Fonts/provenance.json`. Copyright 2018 The Noto Project Authors;
licensed under SIL Open Font License 1.1. Its complete notice is in
`TestFixtures/Fonts/OFL.txt` and `Licenses/ThirdParty/noto-sans-OFL.txt`. The font
retains OFL-1.1 and is not covered by the project's GPL grant. Generated attached
font fixtures must carry the OFL sidecar written by the generator. MacOS system
fonts and rendered PDF/DOCX artifacts are excluded from the public export.

## Binary release requirements

App assembly embeds this notice collection. Publish the matching original
project source and companion dependency-source archive beside each binary, with
checksums and an explicit source download link. See
[Documentation/CORRESPONDING_SOURCE.md](Documentation/CORRESPONDING_SOURCE.md).
Verify the final bundle's closure against the source manifest and native lock;
changed dependencies require refreshed sources/notices and qualification.
Archive integrity and patch checks passed for this package; a fresh rebuild of
all dependencies and byte-for-byte reproduction of Homebrew bottles has not been
performed. Source preparation does not establish runtime or notarization readiness.

## Sparkle 2.10.0

Sparkle provides update checking and installation. The official SwiftPM binary
artifact is pinned by version, source revision and SHA-256 in its package
manifest; `Package.resolved` records the revision. Its complete license notices,
including bundled third-party components, are in `Licenses/ThirdParty/Sparkle/LICENSE`.
Source: https://github.com/sparkle-project/Sparkle/tree/2.10.0
