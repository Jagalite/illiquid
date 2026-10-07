> Historical development note imported from `/Users/jagatranvo/Projects/superplayr/Documentation/Qualification/SidebarContrast/README.md`. Its dates, validation results and relative evidence links describe that checkout, not the reconciled build.

# Sidebar contrast over black presentation bars — 2026-09-06

The Sources header, tools and file rows now select their foreground using local
bounds. Fully outside-video text uses the existing light fallback. Regions that
straddle the image/crop edge include proportional black canvas samples in their
contrast inputs and palette cache key, with at most 128 added samples. Glass
material, opacity and layout are unchanged.

Validation:

- 33 focused color/theme tests passed, including new letterbox, pillarbox, crop,
  Fill, edge-coverage and bounded-allocation cases (`color-tests.log`).
- Architecture checks passed.
- The full release run executed 793 tests / 111 suites and failed three native
  thumbnail checks (`full-tests.log`). All three also failed an isolated recheck
  without changed deadlines (`thumbnail-recheck.log`). These failures remain open;
  this is not an all-green release qualification.
- Failed tests: `timelineThumbnailDecodesWithoutUsingThePlaybackSession`,
  `timelineThumbnailDrainsTheOnlyFrameAtEndOfFile`, and
  `clearingThumbnailCacheReopensReplacedContentAtTheSamePath`. Their images were
  unavailable within the existing bounded thumbnail path. Similar deadline
  failures were already recorded in the prior readback/thumbnail investigation;
  the exact current host contribution is not isolated by this UI task.

Commands used release tests with `--no-parallel`; the build used one compiler job,
`-Xswiftc -gnone --disable-index-store`. Full and isolated fixture runs set
`SUPERPLAYR_NATIVE_FIXTURE_DIR` and `SUPERPLAYR_NATIVE_REQUIRE_FIXTURES=1`.
System output stayed muted. The screen-history service was unavailable, so the
user's original screen was not visually inspected. Geometry/color assertions
are separate from physical glass appearance and packaged-app smoke testing.

Packaged validation completed: the normal isolated release packaging script built
`dist/parity/Platinum.app`; its arm64/27-image audit and ad hoc signature checks
passed. A separately identified benchmark copy, with history disabled and audio
muted, passed playback-clock, paused-clock, six exact seeks and shutdown checks
(`packaged-smoke.json`). Executable/fixture hashes are in `build.json`.

The smoke used a 960×800-point window with the sidebar visible and chrome pinned.
The owned-window screenshot `letterbox-sidebar.png` was visually inspected: the
Sources header and add-file/folder buttons are light and readable over the upper
black bar. This captured sidebar had no source tabs, so populated-row and tools
coverage comes from code review and geometry/color tests, not that screenshot.
The three thumbnail-test failures remain open despite the packaged smoke passing.

Reproduction after preparing the isolated benchmark bundle:

```sh
caffeinate -di python3 Scripts/profile-platinum-app.py \
  --app dist/parity-benchmark/Platinum.app \
  --fixture TestFixtures/SeekPerformance/h264-1080p-gop10.mp4 \
  --output /tmp/sidebar-smoke.json --show-sidebar --pin-chrome \
  --window-size 960x800 --capture-window /tmp/sidebar-window.png
```
