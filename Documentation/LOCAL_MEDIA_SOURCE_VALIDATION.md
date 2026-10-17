# Local media identity and restore-request validation

## Scope

Independent audit of `main` at
`8c3cc3d4008d5d1b8d436bcf2d51d891382b6548` on October 17, 2026.
The subtitle-import fix was already covered by PR #9, so this investigation
moved to persistence/source identity and the product's load-request boundary.
No subtitle, metadata-recognition, decoder, renderer, queue or persistence-writer
implementation changes are included.

The two production files were copied from GitHub and their Git blob hashes
verified before running the baseline:

- `NormalizedFileURL.swift`: `ee5bb383869da68ec1f2cd842ae766603f7ef419`
- `MediaSource.swift`: `f0651daabf51d342e4d61e78f541415f38bd3951`

## Reproduced defects

### File authority is erased from a path-only identity

The baseline accepts `file://media-server.example/Movies/Feature.mkv`, drops its
host, and returns `file:///Movies/Feature.mkv`. It consequently compares equal
to an unrelated local file for persistence and resource-identity purposes.
Credentials and ports are also silently discarded. A `file:relative.mkv` URL
can become the current working directory rather than the named file in the
Linux Foundation baseline probe.

`URL.isFileURL` checks the scheme, not whether an authority is local. RFC 8089
separates local file URIs from non-local authorities; a mounted network share
can still be accessed through a local filesystem path.

The fix rejects unsupported authorities, credentials, ports and non-absolute
file paths before producing a local identity, and validates the original URL
before filesystem/symlink resolution can discard its authority.

### A decoded source label is trusted by restore authorization

The synthesized Codable representation can contain:

```json
{"localFile":{"_0":"https://media.example/Feature.mp4"}}
```

The baseline decodes this successfully and constructs a `.restoredSession`
`MediaLoadRequest`, because the request checks only the enum's `isRemote` flag.
Direct enum construction can likewise bypass the supported-scheme classifier.

The fix revalidates a source through `MediaSource(url:)` and requires that the
result agree with the supplied enum case before applying the existing origin
policy. It rejects inconsistent records rather than silently relabeling them.
The Codable representation is unchanged: valid saved sources remain compatible,
and malformed source values are rejected at authorization, not by changing the
session document schema.

These are confirmed identity/request-boundary defects. No end-to-end native
network playback or exploit has been demonstrated; downstream guards may also
reject malformed input. The change is not a complete URL-security audit.

## Compatibility policy

Only an absent/empty authority or case-insensitive `localhost` is accepted for
path-only local identities. Other hostnames (including a name that might resolve
to this computer), loopback IP authorities, credentials and ports are rejected.
This is a deliberately conservative application policy, not a claim that every
rejected URI is syntactically invalid under every file-URI extension. No DNS or
network lookup is introduced. Mounted shares use their local `/Volumes/...`
paths; normal local files, roots and directory flags remain supported.

Explicit HTTP/HTTPS playback remains supported, and remote sources still cannot
be silently restored. Relative references with a valid absolute local base are
accepted. Unicode, percent-encoded filenames, lexical dot-segment normalization,
and the separation between lexical identities and explicit symlink preparation
are covered by positive controls.

## Validation

Executed with Swift 6.2.1 on Linux using the unchanged production files and test
file in an isolated Foundation-only package:

- Baseline: the 11-method suite failed with 92 expectation failures.
- Patched: all 11 methods passed in debug and release, with warnings as errors.
  There are 43 parameterized cases plus five non-parameterized cases per run.
- The committed portable runner independently passed in both configurations.
- Mutation check: restoring only the old identity implementation produced 48
  expectation failures in its focused regression.
- Mutation check: removing only request revalidation produced 10 expectation
  failures in the malformed-decoded-source regression.
- Both complete configurations passed again after restoring the fixes.
- Shell syntax, workflow YAML structure and diff whitespace checks passed.

Run from the repository root:

```sh
bash Scripts/test-local-media-source-regressions.sh --jobs 2 -Xswiftc -warnings-as-errors
bash Scripts/test-local-media-source-regressions.sh -c release --jobs 2 -Xswiftc -warnings-as-errors
```

The script copies the actual two production files and repository test file
without transformations or stubs. Its temporary package avoids the native app's
macOS frameworks and external package downloads. The test file also belongs to
the normal `IlliquidCoreTests` target.

A separate macOS workflow uses the repository's existing macOS 26/Xcode 26.6 and
pinned checkout configuration. macOS CI results are recorded on the PR, not
assumed from the Linux run. Full application playback, UI restoration, mounted
network-volume behavior and runtime performance have not been measured locally.
No performance improvement or release qualification is claimed.

## References

- [Apple: URL.isFileURL](https://developer.apple.com/documentation/foundation/url/isfileurl)
- [RFC 8089, sections 1.1-3: local file URIs and operations](https://www.rfc-editor.org/rfc/rfc8089.html)
