# Helska's MPV Tools

A small bundle of mpv scripts for Windows, shipped together so they just work:
tone-coloured Chinese subtitles, subtitle and audio tools, screenshots, font and
palette pickers. FFmpeg, OpenCC and a portable Python are bundled, so there is
nothing else to install.

<img width="1740" height="974" alt="example tone coloring" src="https://github.com/user-attachments/assets/098faa47-1f9d-471a-bd99-83fa486c41fc" />
<img width="1740" height="974" alt="example console" src="https://github.com/user-attachments/assets/239fa6a8-dc35-4899-bf70-174d909e82ad" />

## Download

Get **`helskas-mpv-tools-1.0.1-full.zip`** from the
[Releases page](https://github.com/HELSKAA/helskas-mpv-tools/releases/latest).

> Use the `-full` zip. GitHub also lists a "Source code" zip on every release —
> that one has no FFmpeg, so the audio and subtitle features won't work.

## Install

1. Unzip it, then copy **`helska.lua`** and the **`helska`** folder into mpv's
   `scripts` folder (`%APPDATA%\mpv\scripts\`).
2. Restart mpv.

On first launch the bundle clears Windows' "downloaded from the internet" flag
on its tools, so you shouldn't see a SmartScreen prompt.

## Keys

| Key | Action |
| --- | --- |
| `TAB` | open the Console — a menu of everything below |
| `Ctrl+E` | copy the current subtitle's audio to the clipboard |
| `Ctrl+Shift+E` | manual audio clip (1st press = start, 2nd = end) |
| `Alt+E` | audio-boost menu (gain for extracted clips) |
| `Ctrl+T` | toggle tone-coloured subtitles |
| `Ctrl+Alt+C` | toggle Simplified ⇄ Traditional |
| `Alt+T` | tone-colour palette |
| `Ctrl+Shift+X` | save the current subtitle track to a file |
| `Ctrl+.` / `Ctrl+,` | next / previous video in the folder |
| `Ctrl+S` | copy a frame (with subtitles) to the clipboard |
| `Ctrl+Shift+S` | copy a frame (without subtitles) |
| `Ctrl+J` | subtitle font picker |
| `Ctrl+C` | copy the current subtitle text |
| `Ctrl+A` | toggle auto-copy of every subtitle |

Change any key from the Console, or by hand in `helska/helska.conf`.

## Adding and removing features

The loader runs every `.lua` file inside `helska/`. Delete one to remove that
feature, drop one in to add it — nothing else breaks, even without the Console.

## Notes

- The bundled tools are Windows builds. The Lua features still run on
  macOS/Linux, falling back to a system Python + pypinyin and FFmpeg/OpenCC on
  your `PATH`.
- Built and tested on mpv 0.41.0.
- Working files go in `helska/temporary_files/` and clean themselves up.
- More detail and troubleshooting: `FEATURES.txt`.

## Files

`helska.lua` (loader) · `helska/` (scripts + tools) · `tools/` (release
helpers) · `FEATURES.txt` · `MANIFEST.txt` · `THIRD-PARTY-NOTICES.md`

MIT licensed. FFmpeg, OpenCC, Python and pypinyin keep their own licenses — see
`THIRD-PARTY-NOTICES.md`.
