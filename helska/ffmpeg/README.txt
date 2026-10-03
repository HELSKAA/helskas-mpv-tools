HELSKA'S MPV TOOLS - bundled FFmpeg
=======================

The bundle looks for its FFmpeg executable here:

    helska/ffmpeg/ffmpeg.exe     (Windows)
    helska/ffmpeg/ffmpeg         (macOS / Linux)

FFmpeg powers two features:

  * copying the current subtitle's audio to the clipboard
    (Ctrl+E, Ctrl+Shift+E, and the audio-boost menu)
  * preloading an EMBEDDED subtitle track for tone colours
    (Ctrl+T when the selected subtitle lives inside the video file)

If ffmpeg(.exe) is not found here, those two features fall back to whatever
"ffmpeg" is installed on your PATH. Every other feature works regardless.


WHY THIS FOLDER IS EXCLUDED FROM THE GIT REPOSITORY
---------------------------------------------------
A single FFmpeg binary is larger than GitHub's 100 MiB per-file limit, so the
repository ships without it. The download-ready bundle on the project's
Releases page DOES include FFmpeg - the simplest fix is to grab that release
.zip instead of the plain source checkout.

Want to add FFmpeg yourself? Drop a build into this folder under one of the
names above and restart mpv.

FFmpeg is licensed separately from Helska's MPV Tools (usually the GPL,
sometimes the LGPL, depending on the build). See THIRD-PARTY-NOTICES.md at
the bundle root.
