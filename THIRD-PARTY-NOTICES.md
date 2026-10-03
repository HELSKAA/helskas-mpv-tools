# Third-party notices

The Lua scripts, documentation and glue code that make up Helska's MPV Tools
are released under the MIT License (see `LICENSE`). The bundle also ships
third-party software, which stays under its own license:

| Component | Location | License | Notes |
| --- | --- | --- | --- |
| OpenCC | `helska/OpenCC/` | Apache-2.0 | Full text: `helska/OpenCC/LICENSE.txt`. Upstream: https://github.com/BYVoid/OpenCC |
| Python 3.11 (embeddable) | `helska/python/` | PSF License | Full text: `helska/python/LICENSE.txt`. Upstream: https://www.python.org/ |
| pypinyin | `helska/python/Lib/site-packages/pypinyin/` | MIT | Text below. Upstream: https://github.com/mozillazg/python-pinyin |
| FFmpeg | `helska/ffmpeg/` (release zip only) | GPL / LGPL (depends on the build) | See `helska/ffmpeg/README.txt`. Upstream: https://ffmpeg.org/ |

## FFmpeg

FFmpeg is **not** stored in this repository: a single FFmpeg binary is larger
than GitHub's 100 MiB per-file limit. The download-ready bundle on the
**Releases** page does include an FFmpeg build, so the audio-clip and
subtitle-extraction features work out of the box.

FFmpeg is licensed separately from Helska's MPV Tools, and the license depends
on the build: most prebuilt Windows binaries (gyan.dev, BtbN) are under the
**GPL**, some under the **LGPL**. If you redistribute this bundle, keep
FFmpeg's own license and copyright notices intact and comply with the terms of
the build you ship. If you are not sure which build is included, or GPL
redistribution is a concern, delete `helska/ffmpeg/` and install FFmpeg
yourself - the scripts fall back to whatever `ffmpeg` is on your `PATH`.

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
