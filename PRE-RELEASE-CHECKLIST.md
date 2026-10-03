# Pre-release smoke checklist

Run this on a **clean mpv install with no prior helska files**, and again on a
config that already has `helska/helska.conf`, before tagging a release. Tick
every row; if any row fails, do not ship.

## Setup
- [ ] mpv 0.41.0 installed, and `%APPDATA%\mpv\scripts\` is empty.
- [ ] Unzip the freshly built `helskas-mpv-tools-<version>-full.zip` into
      `%APPDATA%\mpv\scripts\` (so `helska.lua` and `helska\` sit there).
- [ ] Start mpv from a terminal so loader messages are visible.

## Loader / startup
- [ ] No line beginning `helska loader:` reports an error at startup.
- [ ] No "Unknown Helska Console action" spam in the log.
- [ ] No SmartScreen prompt for the bundled tools on first launch.

## Console (TAB)
- [ ] TAB opens the Console and lists every action in `FEATURES.txt`.
- [ ] Typing filters the list; Up/Down move the highlight; ESC closes.
- [ ] ENTER runs the highlighted action.
- [ ] `bind tones Ctrl+t` applies and is written to `helska.conf`.

## Per feature
- [ ] Ctrl+E         audio of the on-screen subtitle -> MP3 on the clipboard.
- [ ] Ctrl+Shift+E   manual clip: 1st press start, 2nd end; Left/Right nudges; Esc cancels.
- [ ] Alt+E          audio-boost menu changes gain of extracted clips only.
- [ ] Ctrl+T         tone-coloured subtitles appear; toggling off restores normal.
- [ ] Ctrl+Alt+C     Simplified <-> Traditional toggles and round-trips.
- [ ] Alt+T          palette editor accepts a #RRGGBB per tone and recolours.
- [ ] Ctrl+Shift+X   saves the selected subtitle track beside the video.
- [ ] Ctrl+. / Ctrl+, next / previous video, naturally sorted.
- [ ] Ctrl+S         frame with subtitles -> clipboard.
- [ ] Ctrl+Shift+S   frame without subtitles -> clipboard.
- [ ] Ctrl+J         subtitle font picker applies and persists.
- [ ] Ctrl+C         current subtitle text -> clipboard.
- [ ] Ctrl+A         auto-copy fires for each new subtitle.

## Config round-trip
- [ ] Change a binding in the Console; it survives an mpv restart.
- [ ] Hand-edit `helska.conf` to include a `#` comment, a `;` comment and a
      duplicate key; the Console still reads it, and rewriting the file
      collapses the duplicate to one line.

## Cleanup / multi-instance
- [ ] `helska/temporary_files/` empties itself after clips/captures.
- [ ] A second mpv window does not delete the first window's files.
- [ ] Force-quit mpv; leftovers are removed on the next launch.

## Release integrity
- [ ] Downloaded zip's `helska.lua` matches repo HEAD.
- [ ] `python -m pytest tests -q` is green.
- [ ] `helska/ffmpeg/` contains `FFmpeg-COPYING.GPLv3.txt` and `FFmpeg-SOURCE-OFFER.txt`, and the zip root holds only `helska.lua` + `helska/`.
- [ ] Every SHA-256 in `MANIFEST.txt` matches the shipped files.
