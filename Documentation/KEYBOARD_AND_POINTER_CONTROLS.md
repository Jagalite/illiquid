# Keyboard and Pointer Controls

Superplayr routes shortcuts through native controls first. A focused search
field, text view, button, or timeline keeps its standard AppKit behavior; the
window-level player shortcuts do not take those events.

## Keyboard

| Input | Action |
| --- | --- |
| Space | Play or pause |
| Left / Right | Seek backward / forward 5 seconds |
| Shift-Left / Shift-Right | Seek backward / forward 1 second |
| Option-Left / Option-Right | Previous / next frame, when the backend supports it |
| Up / Down | Raise / lower volume by 5% |
| Option-Up / Option-Down | Raise / lower volume by 1% |
| Page Up / Page Down | Previous / next chapter |
| Shift-Page Up / Shift-Page Down | Seek backward / forward 10 minutes |
| Shift-Delete | Undo the latest coalesced seek sequence |
| Command-Left / Command-Right | Previous / next playlist item |
| F | Toggle fullscreen outside text entry |
| M | Mute or unmute outside text entry |
| I | Show Playback Inspector |
| Shift-? | Show the shortcut reference |
| Escape | Dismiss transient player UI, then leave fullscreen |
| Command-Option-P | Show or hide the playlist |
| Command-Option-T | Toggle Always on Top |

Unsupported backend operations are omitted or ignored consistently. In
particular, the native backend does not currently expose frame stepping, so the
Option-Arrow route is inactive there.

## Video surface

| Input | Action |
| --- | --- |
| Single click | Play or pause |
| Double click | Toggle fullscreen without also toggling playback |
| Right click | Open the capability-filtered native playback menu |
| Auxiliary button 3 / 4 | Previous / next playlist item |
| Horizontal trackpad scroll | Seek in 5-second increments |
| Vertical trackpad scroll | Adjust volume |
| File drop | Replace the playlist |
| Option-file drop | Append to the playlist |

Small pointer jitter does not remount hidden controls. Intentional movement
reveals them and starts a 2.5-second deadline. Pausing or opening the sidebar
uses that same ordinary hide deadline. The controls stay pinned only while the
user is actively interacting with chrome, a popover, search field, resize
handle, menu, sheet, or accessibility control.

## Timeline and playlist

- The timeline supports native click-to-seek, keyboard/accessibility
  adjustment, coalesced preview scrubbing, and one exact commit on release.
- Scrolling over the timeline previews relative seeks and commits the final
  target exactly when the gesture ends.
- Hovering shows time and the active chapter title. Chapter markers and the
  backend's coarse cache percentage are drawn in the detached AppKit leaf.
- Press the duration label to toggle total and remaining time.
- A playlist row's single click selects it. Double click starts it. Restart is
  an explicit context-menu action.
