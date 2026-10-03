HELSKA'S MPV TOOLS - bundled FFmpeg
===================================

The bundle looks for its FFmpeg here:

    helska/ffmpeg/ffmpeg.exe     (Windows)
    helska/ffmpeg/ffmpeg         (macOS / Linux)

FFmpeg powers audio clips (Ctrl+E, Ctrl+Shift+E, the audio-boost menu) and
preloading an embedded subtitle track for tone colours (Ctrl+T). If it is not
found here, those features fall back to "ffmpeg" on your PATH.

This folder is not kept in the git repository (a single FFmpeg binary is larger
than GitHub's 100 MiB per-file limit). The release .zip includes it. To add
FFmpeg yourself, drop a build in here under one of the names above and restart
mpv.

The bundled binary is the gyan.dev "essentials" build of FFmpeg 9.0.2 (GPLv3).
FFmpeg is licensed separately from Helska's MPV Tools; the release .zip carries
its license text and a written source offer at its root. See
THIRD-PARTY-NOTICES.md at the bundle root.
