HELSKA'S MPV TOOLS - temporary_files
====================================

This is the bundle's scratch folder. Features write their short-lived working
files here and delete them automatically: screenshots (Ctrl+S / Ctrl+Shift+S),
extracted audio clips (Ctrl+E / Ctrl+Shift+E), and the Chinese tone-colour /
conversion / preload subtitle tracks.

Only files inside this folder are ever removed, never this README, so nothing
else on your computer is ever touched. You can empty this folder at any time.

The ".helska-session-<pid>" entries are tiny markers that tell a second mpv
window which files are still in use; they disappear when that mpv closes.

A file left behind just means mpv was force-quit before cleanup ran: it is
removed on the next launch, and deleting it yourself is always safe.
