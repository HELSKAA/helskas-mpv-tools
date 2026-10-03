HELSKA'S MPV TOOLS - temporary_files
========================

This folder is the bundle's own scratch space.

Every feature that has to write a short-lived working file writes it HERE
instead of scattering files across the operating system's temporary folder.
Files appear and remove themselves automatically as you use the features:

  * Screenshots (Ctrl+S / Ctrl+Shift+S) are written here, placed on the
    clipboard, and then deleted again immediately.
  * Extracted audio clips (Ctrl+E / Ctrl+Shift+E) are written here and kept
    only until the clipboard stops pointing at them (so you can still paste
    the file), then deleted automatically.
  * The Chinese tone-colour / Hanzi-conversion tracks and the "preload-subs"
    track use short-lived files here that are removed when the track is
    switched off or mpv closes. Because these ARE shown in mpv's track list,
    they are named to read clearly there, e.g. "Tone colors (sub 2).ass" or
    "Preloaded subs (sub 2).srt".

Only files inside this folder are ever removed, and never this README, so
nothing else on your computer is ever touched. Files keep their normal,
friendly names - for example an extracted audio clip is named like
"<video>_<start>-<end>_<hash>.mp3", exactly as it appears when you paste it.

This README is permanent and is never deleted. You can safely empty this
folder at any time; the next action simply creates a fresh file.

The ".helska-session-<pid>" entries are not junk: they are tiny one-line
markers that tell a second mpv window which files are still in use, and they
vanish when that mpv closes. Fine to leave them alone.

If you ever see a working file left behind, it only means mpv was force-quit
before the cleanup could run - it is removed on the next launch, and deleting
it yourself is always safe.
