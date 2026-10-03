# Manual playback checklist

Record the app version, macOS version, Mac model/architecture, display setup,
FFmpeg and libass builds, and test-media identifiers with the results. Use media that is
legal to test and redistribute. Repeat the smoke section on both Apple Silicon
and Intel when shipping a universal build.

## Capability baseline

This checklist targets the native Apple runtime. Supported capabilities are local
files, relative/exact/preview seeking, audio/subtitle tracks (including embedded
PGS/DVD/DVB bitmaps), external text and VobSub pairs, subtitle/audio delay, audio-device selection, automatic BWDIF deinterlacing,
chapters, and hardware-decoding policy. PiP is conditional
on platform support. A checkbox is a qualification task, not a recorded pass.

Remote streams, playback speed, frame stepping, screenshots, image adjustments, manual deinterlacing overrides, and general video filters are currently
unsupported by the runtime. Controls for them must remain hidden or disabled;
direct commands must report unsupported capability without changing playback.
Feature acceptance for these belongs to the findings register until implemented.

SDR P010 can compose captions into ten-bit RGB for PiP. Automated GPU tests
establish precision through compositor output; the local Apple renderer returns
a BGRA8 displayed buffer, so ten-bit display precision remains unqualified.
PQ/HLG P010 with declared BT.709/BT.2020 primaries and supported matrix can
compose captions with 203-nit reference white. Automated renderer readback retains
P010; physical brightness and tone mapping remain unqualified. Unknown color
metadata and unsupported formats retain video-only fallback.

- [ ] Qualify SDR ten-bit PiP gradients, text/bitmap captions, seek, entry/exit,
      and eight/ten-bit source replacement on each supported display/GPU.
- [ ] Establish actual displayed precision separately from compositor readback.
- [ ] Qualify PQ/HLG caption white and colored/transparent captions across HDR/SDR
      displays, tone mapping, resize, seeking and real PiP entry/exit.

## Bundle and launch smoke test

- [ ] `Scripts/verify-app.sh --require-signature` passes for the packaged app.
- [ ] The app launches from Finder on a clean account without mpv or Homebrew
      installed.
- [ ] The video renders inside the application window; no separate mpv window
      appears.
- [ ] File → Open File… (`⌘O`) uses the native file panel and adds an MKV to
      the active source tab; selecting the file starts playback.
- [ ] File → Add Folder… (`⌘⇧O`) uses a directory-only native panel and adds
      the selected folder to the active source tab.
- [ ] A remote URL is rejected with a local-files-only explanation and leaves
      existing playback intact.
- [ ] Quit (`⌘Q`) while stopped, paused, and actively playing exits cleanly with
      no hang, crash report, or surviving helper process.

## Formats, tracks, and subtitles

- [ ] Top- and bottom-field-first motion reconstructs with correct field order
      and doubled cadence; progressive sections retain their original cadence.
- [ ] Interlaced seeks, pause/resume, format transitions and EOF show no stale
      fields or duplicated tail. Repeat with audio and subtitles active.
- [ ] Interlaced ten-bit and VideoToolbox transfer paths preserve color/precision;
      measure CPU, memory and missed display deadlines on representative hardware.
- [ ] Unsupported/oversized interlaced input reports source-field fallback and
      remains playable. Do not infer physical quality from synthetic field tests.

- [ ] Embedded PGS/DVD/DVB palettes, transparency and placement match an independent
      reference, including non-square pixels and resized windows.
- [ ] A PGS cue spanning more than five seconds survives forward/backward seeks;
      clear sets and DVD expiry remove it without resurrecting earlier captions.
- [ ] Forced-only filters mixed bitmap events; explicitly selecting the same track
      reveals its full contents. Audio-track changes preserve that choice.
- [ ] Switching bitmap/text/Off tracks and entering/leaving SDR PiP releases old
      captions and preserves the selected source. Repeat during seek and pause.
- [ ] DVB page timeouts, acquisition/mode changes, selected composition pages and
      repeated backward seeks preserve the correct captions without stale regions.
- [ ] Cropped PGS objects retain the correct source pixels, composition position,
      forced flag, clear behavior and palette updates during seeks and resizing.
- [ ] External VobSub IDX/SUB pairs load their declared language tracks, restore
      the saved language, and preserve subtitle timing through seek and replacement.
      Record malformed/missing pairs separately; synthetic tests alone do not
      qualify real-media compatibility.

- [ ] An MKV with multiple audio tracks plays and exposes every audio track.
- [ ] Switching audio tracks during playback changes audio and keeps A/V sync.
- [ ] An MKV with embedded ASS subtitles renders the selected subtitle track
      with expected styling and timing.
- [ ] Embedded subtitle Off/None selection hides subtitles and selection can be
      restored.
- [ ] An external SRT subtitle loads, appears in the selector, and renders in
      sync.
- [ ] An external ASS subtitle loads, appears in the selector, and preserves its
      styling.
- [ ] Closely named external subtitles beside a video are detected; unrelated
      subtitle files are not attached automatically.
- [ ] An MP4 opens, plays, seeks, and reports a sensible duration.
- [ ] A file with missing or unusual title, duration, language, or track metadata
      does not crash the app and uses restrained fallback labels.
- [ ] Unsupported or corrupt media shows a minimal actionable error and leaves
      the app ready to open another file.

## Folder playlist behavior

- [ ] Opening a folder containing numbered episodes creates a temporary sidebar
      playlist containing supported media from that directory only.
- [ ] Nested-directory media is not included in the non-recursive folder scan.
- [ ] Natural localized sorting places Episode 2 before Episode 10.
- [ ] Unsupported files and hidden metadata files do not appear as episodes.
- [ ] Opening a second folder replaces the prior temporary playlist.
- [ ] When no folder history exists, the first item in the configured playlist
      order starts (newest added first by default).
- [ ] Reopening a known folder restores its last watched episode when that file
      still exists.
- [ ] If the remembered episode no longer exists, the first available file
      starts without an error loop.
- [ ] Dragging a folder onto the player replaces the playlist and starts or
      restores the correct episode.
- [ ] Dragging one supported file onto the player opens it.
- [ ] Dragging unsupported content gives appropriate feedback without stopping
      the current item unexpectedly.
- [ ] Next File (`⌘→`) advances exactly one episode and updates selection.
- [ ] Previous File (`⌘←`) moves back exactly one episode and updates selection.
- [ ] Next/previous behavior at the first and last item matches the documented
      boundary policy and never indexes outside the playlist.
- [ ] Clicking a sidebar episode opens it and persists the prior episode's
      playback position.
- [ ] Hiding and showing the playlist preserves current playback and its saved
      visibility is restored on relaunch.

## Playback controls and state

- [ ] Space toggles play/pause while the video area, controls, and playlist have
      focus, except while a text-entry control legitimately consumes Space.
- [ ] Play/pause from the floating control bar stays synchronized with the menu
      command and observable state.
- [ ] Left Arrow seeks backward by the documented interval.
- [ ] Right Arrow seeks forward by the documented interval.
- [ ] Timeline scrubbing seeks accurately near the beginning, middle, and end.
- [ ] Current position and duration update without high-frequency UI jitter.
- [ ] Stop stops decoding/rendering and leaves the app in a state that can play
      the same or a different file.
- [ ] Volume changes are audible and the displayed value follows the engine.
- [ ] Mute toggles without losing the stored nonzero volume.
- [ ] Pause, seek, volume, mute, and track changes do not block window
      interaction or beachball the main thread.
- [ ] Playback reaching end-of-file transitions cleanly and follows the intended
      next-episode policy once, without double advancement.

## Resume and persistence

- [ ] Quitting with a standalone file open and relaunching automatically opens
      that file and restores its saved playback position.
- [ ] Quitting with a folder playlist open and relaunching automatically
      rebuilds that folder playlist, selects its last watched episode, and
      restores the episode position.
- [ ] Opening a different file or folder replaces the next-launch restore
      target; an unavailable target retains its saved session for a later retry
      without an automatic retry loop.
- [ ] Closing a partially watched file and reopening it restores the last saved
      position within the documented tolerance.
- [ ] Finished or nearly finished media follows the intended restart-versus-
      resume threshold.
- [ ] Positions are isolated by normalized file URL; two same-named files in
      different folders do not share progress.
- [ ] Volume, mute, and sidebar visibility survive app relaunch.
- [ ] The last watched episode is remembered independently for two folders.
- [ ] Moving or deleting a remembered file fails gracefully without corrupting
      other saved positions.
- [ ] Window size and position restore on a valid display and are clamped to a
      visible screen after the display arrangement changes.
- [ ] Force-quitting after at least ten seconds of progress restores within the
      checkpoint tolerance from the atomic Application Support session file.
- [ ] A historical remote-session record is never reconnected automatically
      on relaunch by the local-only runtime.
- [ ] Large history loads leave the startup view responsive. Finder opens
      received during loading retain arrival order; quitting during loading
      does not construct a late player or reopen a window.
- [ ] Replacing media at a remembered path starts the new content at zero with
      default track settings and retains the previous history separately.
      Repeat on local storage, a mounted share, and a retargeted symbolic link.
- [ ] Locate transfers resume/settings only when the replacement has the same
      verified filesystem version. Test a rename and a different file; a
      cross-volume copy may have a different identity and must not be assumed
      equivalent.
- [ ] Missing version metadata shows a persistent explanation, starts at zero,
      and leaves old history untouched while still permitting EOF advancement.

## Chapters and subtitle sync

- [ ] Embedded chapters appear with useful fallback names and selecting one
      seeks to its exact start time.
- [ ] Current chapter selection follows playback across chapter boundaries.
- [ ] Subtitle delay changes independently and resets to zero.
- [ ] Signed audio delay from −10 to +10 seconds works through seek, pause,
      track change and reset. Check audible lip-sync separately from timestamp tests.
- [ ] Unsupported adjustment and capture commands respect the
      capability baseline above.

## Decoder, display, and audio output

- [ ] With configured 5.1 and 7.1 HDMI/USB outputs, use spoken channel-ID media
      to verify every speaker, especially center/LFE and rear versus side pairs.
      Record negotiated PCM diagnostics separately from audible speaker identity.
- [ ] Repeat device/default changes and Audio MIDI speaker-layout changes during
      play, pause, seek and track replacement. New PCM layout/clock state must
      converge without losing the current transport intent or hanging workers.
- [ ] Stereo, missing/unknown speaker layouts and disconnected outputs downmix
      conservatively. Check center dialogue and surround contributions by listening;
      encoded passthrough remains unsupported.

- [ ] Automatic hardware decoding reports the actual native decoder and pixel
      format; unsupported media reports software fallback.
- [ ] Compatibility and software-only decoding honor their policies and report
      the actual selected path without claiming unavailable image filters.
- [ ] Moving between displays updates the reported display, refresh ceiling,
      and ICC profile without a permanent blank frame.
- [ ] SDR output uses the display ICC profile and does not claim EDR is active.
- [ ] PQ and HLG media on an EDR-capable display activates EDR with appropriate
      target primaries/transfer; an SDR-only display falls back gracefully.
- [ ] During pause, audio/video enqueue remains demand-driven; measure subtitle
      observation and other background work separately (see S-013).
- [ ] Animated/karaoke ASS remains smooth at 24/30/60 fps during UI activity.
      Record actual displayed subtitle timing separately from callback counts.
      Pause, resize, change subtitle delay, obscure/reveal and minimize/restore
      the window: captions redraw without resuming periodic paused work.
- [ ] Playback reaches EOF with subtitles Off, absent, or visible; media-time
      observer replacement does not duplicate completion or delay it indefinitely.
- [ ] Settings lists actual output devices, applies the saved preference, and
      reports the current selection. Disconnecting an explicit output attempts
      System Default and reports any selection failure without claiming success.
- [ ] Repeated system audio-output changes flush/re-preroll at the current
      position, preserve pause/play intent, and recover A/V sync. Repeat with
      Bluetooth, headphones, and HDMI; record route and timing evidence.

## Network, system integration, and mini-player

- [ ] Remote URLs and network manifests cannot bypass the local-input policy.
- [ ] Local files cannot follow implicit external references.
- [ ] The native app does not load mpv configuration, scripts, youtube-dl hooks,
      or expose an mpv IPC endpoint.
- [ ] Control Center/Now Playing shows title, duration, position, and rate only
      while a session is active.
- [ ] Play, pause, toggle, skip, seek-position, next, and previous media-key
      commands perform the matching player action and are removed after stop.
- [ ] Active playback prevents idle system/display sleep; pausing releases the
      assertion. System sleep checkpoints and pauses, then resumes only if the
      session was active before sleep.
- [ ] Enter Mini Player creates a compact floating all-Spaces window; Exit Mini
      Player restores the prior frame, level, behavior, size limits, aspect,
      and sidebar visibility.
- [ ] Playback Inspector accurately reports lifecycle, source, buffer, decoder,
      HDR/display, audio output, tracks, chapters, and bounded diagnostics.

## Window, fullscreen, input, and controls

- [ ] Fullscreen (`⌘F`) enters and exits native macOS fullscreen from the menu.
- [ ] The standard green window control enters and exits the same fullscreen
      state, with UI state kept in sync.
- [ ] Resizing the window repeatedly during playback keeps the correct aspect
      ratio, renders continuously, and does not flash a separate surface.
- [ ] Moving the window between Retina displays and displays with different
      refresh rates/scales keeps rendering sharp and stable.
- [ ] The floating control bar remains above video and adapts at narrow, wide,
      and fullscreen sizes without clipping important controls.
- [ ] Playback controls, toolbar items, and standard window buttons disappear
      together while playing after pointer inactivity.
- [ ] Moving the pointer makes hidden controls reappear promptly.
- [ ] Controls auto-hide after the normal deadline while paused or while the
      sidebar is open, but remain visible while a menu/popover or active
      manipulation is in use.
- [ ] Auto-hide does not steal keyboard focus or make shortcuts unavailable.
- [ ] The control bar does not permanently obscure visible subtitles; subtitles
      and controls remain usable together near the bottom edge.
- [ ] Hover states, tooltips, keyboard focus rings, VoiceOver labels, and reduced
      motion behavior are appropriate for every control.
- [ ] The glass controls and material fallback path remain legible in light,
      dark, increased-contrast, and reduced-transparency appearances.

## Lifecycle and reliability stress

- [ ] Close the application window during playback; decoding, render callbacks,
      event handling, and audio stop cleanly.
- [ ] Quit the application during active playback; it exits without crash or
      delayed callback into released Swift/AppKit objects.
- [ ] Repeatedly switch files at least 25 times across MKV and MP4 samples; the
      video surface remains embedded and controls reflect only the current file.
- [ ] Alternate next and previous rapidly; stale load/track events do not replace
      the current file's state.
- [ ] Enter/exit fullscreen, resize, seek, and switch tracks during file changes;
      no crash, deadlock, blank permanent surface, or runaway CPU occurs.
- [ ] Sleep and wake the Mac during paused and active playback; the player
      remains controllable with synchronized audio/video afterward.
- [ ] Disconnect headphones or change the system audio output during playback;
      playback recovers or reports a restrained error.
- [ ] After closing the last window or quitting, Activity Monitor shows no
      Superplayr process and no file remains unnecessarily locked.

## Result notes

Tester:

Date:

Build/version:

Machine and macOS:

Media set:

Failures and reproduction steps:

## Filesystem preparation and shortcut discovery

- [ ] Open the same file through a symlink and canonical path; verify history and
      playlist identity agree. Retarget the alias and verify the next open uses
      the new file without applying unrelated resume settings.
- [ ] Stop, replace the source or quit while a Finder request is preparing;
      verify no late source or folder tab appears.
- [ ] Drop files while changing/closing tabs; additions stay with the original
      surviving tab and never appear in the newly selected tab.
- [ ] Expand several healthy folders together, then repeat on a slow mount;
      loading completes or reports a bounded failure without freezing controls.
- [ ] Open Help → Keyboard Shortcuts using menus and keyboard-only navigation;
      unsupported operations are absent and Done restores focus.
- [ ] Run the U-008 pseudo-localization sequence after selecting release languages;
      record actual clipping, mixed-direction filenames and focus behavior.

## U-007 end-to-end accessibility sequence (unqualified)

Record the exact package hash, macOS/build, VoiceOver settings and appearance.
Run once with keyboard only and once with VoiceOver. Repeat the affected surfaces
with Reduce Motion, Reduce Transparency and Increase Contrast enabled.

1. Use the File menu to add a test file, navigate to its source row and start it.
   Record initial focus, the row's name and the play/pause announcement.
2. Let controls hide, reveal them, then reach the timeline using keyboard focus.
   Adjust it in both directions; record announced time/units and confirm that
   native slider adjustment does not also trigger global seeking or volume.
3. Select audio, text subtitles, bitmap subtitles and Off from the track controls.
   Record selected-state announcements and focus after each popover closes.
4. Change source tabs and files, then open shortcut help and dismiss it. Confirm
   focus returns to a visible usable control and no hidden chrome receives focus.
5. Open a deliberately unavailable test source. Reach the persistent recovery
   actions, exercise Retry and Locate, then dismiss. Record announcement timing,
   action order and restored focus; do not rely on the transient OSD alone.
6. Enter/leave fullscreen and PiP, then return to the timeline and track controls.
   Record focus restoration, hidden-control exposure and caption readability.
7. Quit using the keyboard from both playing and recovery states. Record any
   inaccessible modal UI or shutdown delay. Attach results to U-007/V-002; these
   instructions and automated focus tests are not a recorded accessibility pass.
