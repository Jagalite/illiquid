# Corresponding source and release assets

The companion `illiquid-redistribution` directory contains checksum-bound source
inputs for every native component in the reviewed dependency closure, the exact
installed build recipes, applicable patches, sanitized receipts and pinned Swift
build/test sources. Its README documents source rebuilding, external toolchain
prerequisites, font exclusions and the limits of verification.

```sh
python3 Scripts/verify-corresponding-source.py /path/to/illiquid-redistribution
```

The manifest in `Licenses/corresponding-source-manifest.json` must match the
companion manifest. It records original input library hashes before install-name
rewriting/signing. The native lock identifies the same 26 libraries. All source
inputs and notices are hash-checked; GLib and all four OpenSSL patches apply
cleanly. Generated Homebrew recipes pass Ruby syntax checking. Font-excluded
archives retain every other source file unchanged. These checks do not assert a
successful rebuild of all dependency packages or binary reproducibility.

For a binary release, provide three adjacent downloadable artifacts: the binary,
the exact Illiquid source archive from the public commit, and the matching
companion source archive. Publish checksums and a visible source download link
alongside the binary. Never use a source archive from a different dependency
build. Preserve old matching source packages while their binaries remain offered.
Use `Scripts/build-platinum-app.sh` and the distribution instructions to build,
rewrite install names, embed licenses, sign, audit, and package the app. The
companion package covers dependency build inputs; the project source includes
all original code and app build/install scripts. macOS SDK/system libraries and
general-purpose build tools remain external prerequisites.

Rebuilt libraries usually have different hashes. Review changed binaries and
closure, regenerate their provenance/notices/source manifest, qualify playback,
and then refresh the lock deliberately. Do not bypass the original lock or
claim that assembled source inputs prove a reproducible release.

The public source excludes raw qualification logs/traces, private desktop
recordings, planning artifacts and rendered PDF/DOCX documents. Original icon
and two concept images are owner-confirmed project artwork. Noto Sans is supplied
under OFL-1.1 for the generated attached-font fixture; its notice is retained.
Upstream test-font corpora and separately downloaded formula test media are
excluded from the companion package and are not required for runtime builds.
No generated media or macOS system font is part of the public source export.

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
