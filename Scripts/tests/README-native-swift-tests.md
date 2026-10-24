# Native release Swift Testing runner

From the repository root, the coordinating parent can queue a build and focused
execution together after the source is stable:

```sh
python3 /Volumes/seed1/Projects/kyoto/kyoto.py submit --resource "$PWD/.build" -- \
  Scripts/tests/run-native-swift-tests.sh --build --jobs 2 \
  --filter 'PlaybackCoordinatorTests|NativePlaybackFoundationTests'
```

Replace the regex with the intended suite/test selection. Repeated `--filter`
arguments select alternative matches; omit filters for all Swift Testing tests.
The runner uses `--no-parallel`. These are Swift Testing arguments, not XCTest
selectors. The wrapper requires a valid JUnit XML receipt with at least one
completed, unskipped test and no failures; zero-match runs fail. Inspect the
reported count and names to establish that the intended tests matched. The
wrapper does not run XCTest tests.

The build command is `swift build -c release --build-tests
--force-resolved-versions -Xswiftc -enable-testing`, with an explicit package path
and optional `--jobs`. Release tests use `@testable` imports, so the explicit
testing flag is required.
`ILLIQUID_SWIFTPM_DISABLE_SANDBOX=1` adds `--disable-sandbox`, matching
`Scripts/run-app.sh`. SwiftPM's `--show-bin-path` locates the resulting binary:
`IlliquidPackageTests.xctest/Contents/MacOS/IlliquidPackageTests` beneath that
directory. The wrapper runs from the repository root, including when invoked
from another directory.

The generated `IlliquidPackageTests.derived/runner.swift` selects
`Testing.__swiftPMEntryPoint()` for `--testing-library swift-testing`. The local
Swift Testing source in `.build/checkouts/swift-testing/Sources/Testing/ABI/EntryPoints/EntryPoint.swift`
parses `--filter`, `--no-parallel`, and `--xunit-output`. On macOS, the inner
Mach-O file is normally a **bundle**, even when its executable permission is set.
It cannot be executed directly. The wrapper checks its Mach-O type and uses the
selected toolchain's `usr/libexec/swift/pm/swiftpm-testing-helper` with
`--test-bundle-path <inner-Mach-O-path> --testing-library swift-testing` for a
bundle. A Mach-O executable is invoked directly; unknown formats fail closed.
See [Swift Testing's standard bundle-loader instructions](https://github.com/swiftlang/swift-testing/blob/main/Documentation/CommandlineDebugging.md).

The helper is resolved relative to `xcrun --find swift`; platform paths come from
`xcrun --show-sdk-platform-path`. After those system-tool launches, the wrapper
sets DYLD on the loader/executable itself using `/usr/bin/env`, avoiding the
launch boundary that can strip `DYLD_*` during `swift test`. `DYLD_LIBRARY_PATH`
contains pinned native directories, the release binary directory, and the
platform's `Developer/usr/lib`. `DYLD_FRAMEWORK_PATH` contains the release binary
directory, platform `Developer/Library/Frameworks`, and platform
`Developer/Library/PrivateFrameworks` when present. The Xcode paths provide
`libXCTestSwiftSupport.dylib` and its framework dependencies; the release path
provides package frameworks such as Sparkle. The wrapper does not compile a
custom loader or invoke XCTest's harness.

The wrapper uses `Scripts/lib/native-sdk-environment.sh` and
`BuildInputs/native-sdk.json`. It intentionally replaces inherited
`PKG_CONFIG_PATH` and `ILLIQUID_NATIVE_LIBRARY_PATH` with the pinned SDK selections,
and runtime DYLD library/framework paths with the selections described above.
Other test environment variables are retained.
It requires the pinned FFmpeg pkg-config directory, the pinned FFmpeg/libass
libraries, and `libx265.216.dylib` (currently in
`/opt/homebrew/Cellar/x265/4.2/lib`). It fails if those paths or the executable are
missing. Like `run-app.sh`, unavailable transitive pinned directories allow dyld's
installed-library fallback; this wrapper reports them. Therefore the search-path
selection does not prove that every loaded transitive library matches the SDK.
These are path checks, not native-input hash verification. It neither installs
libraries nor changes Homebrew links; see
[the SDK inputs](../../BuildInputs/README.md) for provenance.

For separate compilation and execution receipts, queue these in order, inspecting
the first result before submitting the second:

```sh
python3 /Volumes/seed1/Projects/kyoto/kyoto.py submit --resource "$PWD/.build" -- \
  Scripts/tests/run-native-swift-tests.sh --build-only --jobs 2
python3 /Volumes/seed1/Projects/kyoto/kyoto.py submit --resource "$PWD/.build" -- \
  Scripts/tests/run-native-swift-tests.sh --skip-build \
  --filter 'PlaybackCoordinatorTests|NativePlaybackFoundationTests'
```

`--skip-build` makes no SwiftPM calls and uses `.build/release`; the parent must
verify that this binary matches the intended source, toolchain and SDK. Do not
reuse a prior compilation after source changes without rebuilding. Serialize
builds sharing `.build`. Use Kyoto's default queue and inspect `show JOB_ID`,
`logs JOB_ID`, and `wait JOB_ID` for each receipt. The wrapper does not submit
itself or change queue policy.

Logs distinguish build success/failure, build-only completion, build skipping,
and execution success/failure. Each execution retains a uniquely named
`illiquid-native-swift-tests.XXXXXX/results.xml` under `${TMPDIR:-/tmp}` and prints
its absolute path. Failed runs retain their directory too, even if the loader
failed before writing XML. Build and test failures retain their command's
exit status; argument/path or receipt-validation errors return 2. A build-only success is compilation
evidence. An execution summary qualifies only the selected tests, and does not
establish live UI interaction or presentation qualification.

Verification on 2026-10-23 reused the existing release bundle without rebuilding.
Its inner Mach-O SHA-256 was
`177aa7b961fffe0127af34270fcf5824f91f00196e67e91b392b63c543d454ee`.
The focused command was:

```sh
python3 /Volumes/seed1/Projects/kyoto/kyoto.py submit \
  --resource /Volumes/seed2/Projects/illiquid/.build -- \
  /bin/bash Scripts/tests/run-native-swift-tests.sh --skip-build \
  --filter AgentUIProtocolTests
```

Job `46a7881d7d274c8bb0291634c627d3bb` executed all six tests: five passed,
`invalidTargetGeometryIsNotPublished()` failed at `AgentUIProtocolTests.swift:109`,
and the wrapper returned 1. An extreme finite CGRect was accepted instead of
returning nil. This establishes actual Swift Testing execution, and leaves the
source-level test gate failing. Its XML receipt is
`/var/folders/p2/hs2582qs5672qbvtm4z5_9840000gn/T/illiquid-native-swift-tests.EVhN4f/results.xml`.

With the same command prefix, filter
`AgentUIProtocolTests/everyGateIsRequired` in job
`994ebf3a8cfe4a7aaccc64ea6fe105c1` passed with `matched=1 executed=1 failures=0`,
exit 0. Filter `^__IlliquidNoSuchTest__$` in job
`79a8b266cdb34b5b8fb8c7c5416be5be` matched zero tests and returned 69, preserving
Swift Testing's no-tests failure despite its console saying zero tests passed.
The passing subset does not qualify the full suite.

Earlier receipts remain intact: `3bf2f5a3b75f4afa85b96732966360ac` compiled tests
then failed direct bundle execution (126); `f8ea044bd4d64a64a7f23ad15af2e4ce`
used the standard loader but lacked `libXCTestSwiftSupport.dylib` search paths
(133); `1ec764f6917949d2b6479b8d553b184c` also needed platform private frameworks
for `XCTestCore` (133). Kyoto logs reside under
`/Users/jagatranvo/.local/state/kyoto/<JOB_ID>.log`. `show`, `logs`, and `wait`
were inspected for each new job. No packaging or live UI qualification follows
from these receipts.
