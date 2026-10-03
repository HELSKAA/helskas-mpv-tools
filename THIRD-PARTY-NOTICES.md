# Third-party notices

The Lua scripts, documentation and glue code that make up Helska's MPV Tools
are released under the MIT License (see `LICENSE`). The bundle also ships
third-party software, which stays under its own license:

| Component | Location | License | Notes |
| --- | --- | --- | --- |
| OpenCC | `helska/OpenCC/` | Apache-2.0 | Full text: `helska/OpenCC/LICENSE.txt`. Upstream: https://github.com/BYVoid/OpenCC |
| Python 3.11 (embeddable) | `helska/python/` | PSF License | Full text: `helska/python/LICENSE.txt`. Upstream: https://www.python.org/ |
| pypinyin | `helska/python/Lib/site-packages/pypinyin/` | MIT | Text below. Upstream: https://github.com/mozillazg/python-pinyin |
| FFmpeg | `helska/ffmpeg/` (release zip only) | GPLv3 | gyan.dev "essentials" build 9.0.2. License text and source offer ship in the release zip as `FFmpeg-COPYING.GPLv3.txt` / `FFmpeg-SOURCE-OFFER.txt`. Upstream: https://ffmpeg.org/ |

## FFmpeg

FFmpeg is **not** stored in this repository: a single FFmpeg binary is larger
than GitHub's 100 MiB per-file limit. The download-ready bundle on the
**Releases** page does include an FFmpeg build, so the audio-clip and
subtitle-extraction features work out of the box.

The shipped binary is the **gyan.dev "essentials" build of FFmpeg 9.0.2**,
configured with `--enable-gpl --enable-version3`. That makes it a **GPLv3**
build. To satisfy the GPL's redistribution terms, the release zip also carries
FFmpeg's license text (`FFmpeg-COPYING.GPLv3.txt`) and a written offer for the
corresponding source (`FFmpeg-SOURCE-OFFER.txt`) at its root.

If you would rather not redistribute a GPL binary, delete `helska/ffmpeg/` and
install FFmpeg yourself - the scripts fall back to whatever `ffmpeg` is on your
`PATH` (an LGPL build also works for the audio features).

FFmpeg license text and corresponding source: https://ffmpeg.org/legal.html

## pypinyin (MIT)

    The MIT License (MIT)

    Copyright (c) 2016 mozillazg, 闲耘 <hotoo.cn@gmail.com>

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in
    all copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.
