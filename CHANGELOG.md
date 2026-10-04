# Changelog

All notable changes to Helska's MPV Tools are recorded here. The project uses
[Semantic Versioning](https://semver.org/).

## [1.0.1] - 2026-10-04

### Added
- `CHANGELOG.md`.
- Unit tests for the tone-colour helper (`tests/test_tone_colors.py`) and a
  minimal CI workflow that runs them on Linux and Windows.
- The release zip now carries FFmpeg's GPLv3 license text and a written source
  offer (`FFmpeg-COPYING.GPLv3.txt`, `FFmpeg-SOURCE-OFFER.txt`) inside
  `helska/ffmpeg/`, next to the binary; the zip root stays `helska.lua` +
  `helska/`.

### Changed
- Named the bundled FFmpeg build explicitly (gyan.dev "essentials" 9.0.2, GPLv3)
  in `MANIFEST.txt`, `THIRD-PARTY-NOTICES.md` and `helska/ffmpeg/README.txt`.
- Unified the per-script config readers/writers so every module parses
  `helska.conf` the same way: comments may start with `#` or `;`, and duplicate
  active keys collapse to a single line.
- The Console "unknown action" note is logged at verbose level instead of as a
  warning.

### Fixed
- Docs no longer call the Ctrl+J picker a "font / size" picker - it selects the
  subtitle font only.

## [1.0.0] - 2026-10-03

- First public release: the Console (TAB) plus seven features - tone-coloured
  Chinese subtitles, audio / subtitle / frame clipboards, subtitle extraction,
  folder playback and a subtitle font picker. FFmpeg, OpenCC and a portable
  Python are bundled.
