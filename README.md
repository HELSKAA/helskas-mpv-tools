# Helska's MPV Tools — an mpv script bundle (Windows)

> **⬇ Install in two steps (Windows).** Open the **Releases** page of this
> repository and download **`helskas-mpv-tools-<version>.zip`**, then extract it into
> mpv's `scripts/` folder and restart mpv. That zip is fully self-contained
> (FFmpeg + OpenCC + portable Python included) — no extra downloads.
>
> Cloning the repository instead? Everything is here **except the FFmpeg
> binary** (it is larger than GitHub's 100 MiB per-file limit) — see
> `helska/ffmpeg/README.txt` for how to add it.

A set of small, independent mpv scripts shipped as one tidy bundle.
Everything is **self-contained for Windows**: FFmpeg, OpenCC and a portable
Python (with pypinyin) are bundled, so tone-coloured Chinese subtitles and
Simplified/Traditional conversion work out of the box with full accuracy.

> New here? See **`FEATURES.txt`** for a complete, plain-language guide to
> every feature, the default keys, and where temporary files are stored.

## Install (Windows) — two steps

1. Copy **`helska.lua`** and the **`helska`** folder together into mpv's
   `scripts/` folder (the one that already contains `input.conf`).
2. Start (or restart) mpv. Done.

## Requirements

- **Windows** — the bundled FFmpeg / OpenCC / Python are Windows builds.
- A recent **mpv** — built and tested on **mpv 0.41.0**. Almost every feature
  works on much older builds too; the *Subtitle clipboard* feature needs a
  build that provides mpv's built-in `clipboard/text` property.

> If you used an older layout where the individual `helska_*.lua` files sat
> directly in `scripts/`, remove those old copies first so they do not load
> twice. With this bundle, only `helska.lua` is auto-run; everything else
> lives inside the `helska` folder.

The first time mpv starts, the bundle clears Windows' "downloaded from the
internet" flag on its bundled tools so you will not get a SmartScreen prompt.

The bundle also creates its own scratch folder, **`helska/temporary_files/`**
(shipped with a short `README.txt`). Features write their short-lived working
files there and delete them again automatically — see **`FEATURES.txt`** for
exactly when each one is cleaned up.

## What is inside

| Script | What it does | Default key |
| --- | --- | --- |
| Console | In-player menu of every action below | `TAB` |
| Audio → clipboard | Copy the current subtitle's audio to the clipboard as an MP3 | `Ctrl+E` |
| Audio → clipboard | Manual clip — 1st press = start, 2nd press = end | `Ctrl+Shift+E` |
| Audio → clipboard | Audio-boost menu (gain applied to extracted clips) | `Alt+E` |
| Chinese | Tone-coloured subtitles | `Ctrl+T` |
| Chinese | Simplified ⇄ Traditional conversion | `Ctrl+Alt+C` |
| Chinese | Tone-colour palette editor | `Alt+T` |
| Extract subtitle | Save the current subtitle track to a file | `Ctrl+Shift+X` |
| Playback | Play next / previous video in the folder | `Ctrl+.` / `Ctrl+,` |
| Screenshot | Copy a frame **with** subtitles to the clipboard | `Ctrl+S` |
| Screenshot | Copy a frame **without** subtitles | `Ctrl+Shift+S` |
| Subtitle font | Change subtitle font/size on the fly | `Ctrl+J` |
| Subtitle clipboard | Copy the current subtitle text to the clipboard | `Ctrl+C` |
| Subtitle clipboard | Toggle auto-copy of every subtitle | `Ctrl+A` |

Every command is also reachable from the Console (`TAB`), and every key is
rebindable in **`helska/helska.conf`** (created the first time you change a
binding or a tone setting, inside the `helska` folder) or from the Console
(`bind` / `unbind` / `defaultbind`).

## Disable or extend a feature

The loader **auto-discovers** every `*.lua` file inside `helska/`, so:

- **Disable** a feature by deleting its file (e.g.
  `helska_screenshot-clipboard.lua`) and restarting mpv. The rest of the
  bundle keeps working — even with `helska_console.lua` removed.
- **Add** a feature by dropping a `.lua` into `helska/`. There is no list to
  edit.

`FEATURES.txt` documents the small protocol a script uses to appear in the
Console (and where to place such a script).

## Dependencies

All bundled and Windows-only:

- **FFmpeg** → `helska/ffmpeg/` (audio clips, subtitle extraction). *Not kept
  in the git repository (per-file size limit) — it is included in the release
  zip, or drop your own `ffmpeg.exe` into that folder.*
- **OpenCC** → `helska/OpenCC/` (Simplified ⇄ Traditional; trimmed to just
  the dictionaries the bundle uses)
- **Python 3.11 (embeddable) + pypinyin** → `helska/python/` (Chinese tone
  colours; real pypinyin for accurate tones)

On macOS/Linux the bundle still runs all Lua features, but tone colours fall
back to a system Python with pypinyin (`python3 -m pip install pypinyin`),
and FFmpeg/OpenCC fall back to whatever is on your PATH.

## Files

- `README.md` — this file
- `FEATURES.txt` — complete feature guide, default keys, temp-file locations
- `MANIFEST.txt` — versions and SHA-256 checksums of the bundled tools
- `LICENSE` — MIT license for Helska's MPV Tools
- `THIRD-PARTY-NOTICES.md` — licenses of the bundled tools (FFmpeg, OpenCC,
  Python, pypinyin)
- `helska.lua` — loader (see install)
- `helska/` — all scripts + bundled tools
- `helska/temporary_files/` — self-cleaning scratch folder (see `FEATURES.txt`)
- `tools/` — release helpers (`build_release.ps1`, `check_github_limits.ps1`)

## Troubleshooting

- **Tone colours / conversion do nothing, or a tool is "not found":**
  the bundle looks for each tool next to the scripts (in `helska/`). If you
  only copied `helska.lua` and forgot the `helska` folder, the loader reports
  it on startup.
- **A Windows prompt about the bundled .exe:** restart mpv once; the bundle
  unblocks them automatically. If it persists, run the same command the loader
  uses, from inside `scripts/`:
  `powershell -NoProfile -Command "Get-ChildItem -LiteralPath 'helska' -Recurse -Force | Unblock-File"`.
- **Hear only static / no Chinese colouring:** make sure a subtitle track is
  actually selected, then toggle from the Console (`TAB`) or its hotkey.
- **Check startup log:** run mpv from a terminal (`mpv file.mkv`) and look
  for the `helska loader:` line.
