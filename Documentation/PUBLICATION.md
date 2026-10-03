# Public source boundary

The public repository begins with a fresh initial commit under the owner's
GitHub identity. It contains the current source, tests, validation programs,
build/qualification scripts, architecture and user guides, dependency notices,
and approved original artwork. Internal Swift module and compatibility names
remain Superplayr/Platinum; the visible product is Illiquid.

The export does not contain the private repository's Git objects, branches,
checkpoint refs, author email history, desktop recordings, planning artifacts,
raw qualification outputs, profiling traces, generated media or rendered
PDF/DOCX documents. Original qualification evidence remains in the private
working repository. References to omitted evidence are labeled in exported
Markdown; historical reports are not current release qualification.
Local home/volume paths in retained first-party text are normalized. Third-party
license notices retain their copyright attribution without rewriting.

The icon and two concept PNGs are owner-confirmed original project art, recorded
in `Licenses/original-assets.json`. The sole supplied fixture font is pinned Noto
Sans under OFL-1.1. Its full notice and provenance accompany it. The fixture
generator attaches that font and writes an OFL sidecar, without copying system
fonts. Upstream test fonts are excluded from the companion dependency package.

`Scripts/prepare-public-repository.py` implements this export boundary and writes
an external receipt. It refuses an existing destination, excludes private
artifact classes and never copies `.git`. Review any policy change before using
it for another release. The exported commit and Git object database must be
rescanned before publication, using default credential rules without project
allowlists. Scan source-package extracted files as well; OpenSSL upstream test
keys/certificates are public test data and must never become production secrets.
A zero-alert scan is bounded evidence, not a guarantee.

See [CORRESPONDING_SOURCE.md](CORRESPONDING_SOURCE.md) for dependency source and
binary distribution. A prepared local source candidate does not mean it has
been pushed, signed with Developer ID, notarized or physically qualified for release.
