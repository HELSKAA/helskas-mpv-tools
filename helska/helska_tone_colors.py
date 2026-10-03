#!/usr/bin/env python3
import json
import os
import re
import sys
from pathlib import Path

try:
    from pypinyin import lazy_pinyin, Style
except Exception:
    print(json.dumps({"ok": False, "error": "pypinyin is not installed"}, ensure_ascii=False))
    sys.exit(2)

HAN_RE = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]")
SRT_TIME_RE = re.compile(
    r"^\s*(\d{1,2}):(\d{2}):(\d{2})[,.](\d{3})\s*-->\s*"
    r"(\d{1,2}):(\d{2}):(\d{2})[,.](\d{3})(?:\s+.*)?$"
)

COLORS = {
    1: "&H4F46EC&",  # #ec464f  tone 1: red
    2: "&H408FFF&",  # #ff8f40  tone 2: orange
    3: "&H43BF6C&",  # #6cbf43  tone 3: green
    4: "&HE6BA39&",  # #39bae6  tone 4: blue
    5: "&HFCFCFC&",  # #fcfcfc  neutral / toneless
}
NORMAL = "&HFCFCFC&"

DEFAULT_COLORS = dict(COLORS)

def normalize_hex(value):
    """Return a canonical #RRGGBB value or None."""
    value = str(value or "").strip().upper()
    if not value.startswith("#"):
        value = "#" + value
    if not re.fullmatch(r"#[0-9A-F]{6}", value):
        return None
    return value

def hex_to_ass(value):
    """Convert #RRGGBB to ASS BGR color syntax."""
    value = normalize_hex(value)
    if not value:
        return None
    r, g, b = value[1:3], value[3:5], value[5:7]
    return f"&H{b}{g}{r}&"

def apply_tone_colors(values):
    """Apply the five colors supplied by helska_chinese.lua for this build."""
    global NORMAL

    # Start every invocation from known defaults. The helper is normally a
    # fresh process, but this also keeps the function deterministic in tests.
    COLORS.clear()
    COLORS.update(DEFAULT_COLORS)

    if isinstance(values, list):
        for tone in range(1, 6):
            if tone - 1 < len(values):
                converted = hex_to_ass(values[tone - 1])
                if converted:
                    COLORS[tone] = converted
    elif isinstance(values, dict):
        for tone in range(1, 6):
            raw = values.get(str(tone), values.get(tone))
            converted = hex_to_ass(raw)
            if converted:
                COLORS[tone] = converted

    NORMAL = COLORS[5]

def ass_escape_text(text):
    return text.replace("\\", "＼").replace("{", "｛").replace("}", "｝")

def htmlish_to_plain(text):
    # Preserve line breaks but remove common SRT HTML styling; the generated
    # ASS owns the visual styling.
    text = re.sub(r"<br\s*/?>", "\n", text, flags=re.I)
    return re.sub(r"<[^>]+>", "", text)

def color_line(text, sandhi=False):
    readings = lazy_pinyin(
        list(text),
        style=Style.TONE3,
        neutral_tone_with_five=True,
        errors=lambda chars: list(chars),
        tone_sandhi=sandhi,
    )
    out = []
    last_color = None
    for ch, reading in zip(text, readings):
        tone = 0
        if HAN_RE.fullmatch(ch):
            m = re.search(r"([1-5])$", reading)
            if m:
                tone = int(m.group(1))
        color = COLORS.get(tone, NORMAL)
        if color != last_color:
            out.append(r"{\1c" + color + "}")
            last_color = color
        out.append(ass_escape_text(ch))
    return "".join(out)

def color_text(text, sandhi=False):
    # A multiline SRT cue must remain ONE ASS Dialogue event. Process each
    # visual line independently, then insert ASS's explicit newline escape.
    # This prevents a physical newline from ever splitting/corrupting an event.
    text = htmlish_to_plain(text)
    return r"\N".join(color_line(line, sandhi) for line in text.splitlines())

def ass_time(parts):
    hh, mm, ss, ms = map(int, parts)
    # ASS timestamps are centiseconds.
    cs = int(round(ms / 10.0))
    if cs >= 100:
        ss += 1
        cs -= 100
    if ss >= 60:
        mm += ss // 60
        ss %= 60
    if mm >= 60:
        hh += mm // 60
        mm %= 60
    return f"{hh}:{mm:02d}:{ss:02d}.{cs:02d}"

def parse_srt(text):
    text = text.replace("\r\n", "\n").replace("\r", "\n").lstrip("\ufeff")
    blocks = re.split(r"\n{2,}", text.strip())
    events = []
    for block in blocks:
        lines = block.split("\n")
        time_i = None
        match = None
        for i, line in enumerate(lines[:3]):
            m = SRT_TIME_RE.match(line)
            if m:
                time_i, match = i, m
                break
        if match is None:
            continue
        body = "\n".join(lines[time_i + 1:])
        if not body:
            continue
        events.append((ass_time(match.groups()[:4]), ass_time(match.groups()[4:]), body))
    return events

def decode_subtitle(path):
    data = Path(path).read_bytes()
    # UTF-8 covers the expected modern subtitle path; BOM-aware UTF-16 is a
    # useful fallback for Windows subtitle collections.
    for enc in ("utf-8-sig", "utf-16", "gb18030", "big5"):
        try:
            return data.decode(enc)
        except UnicodeDecodeError:
            pass
    return data.decode("utf-8", errors="replace")


ASS_OVERRIDE_RE = re.compile(r"(\{[^}]*\})")

def color_ass_visible_text(text, sandhi=False):
    """Color visible ASS text while preserving override blocks exactly."""
    pieces = ASS_OVERRIDE_RE.split(text)
    visible = []
    positions = []
    for pi, piece in enumerate(pieces):
        if not piece or (piece.startswith("{") and piece.endswith("}")):
            continue
        # \N, \n and \h are ASS escapes, not visible Hanzi. Preserve them.
        chunks = re.split(r"(\\[Nnh])", piece)
        for ci, chunk in enumerate(chunks):
            if not chunk or re.fullmatch(r"\\[Nnh]", chunk):
                continue
            for oi, ch in enumerate(chunk):
                if HAN_RE.fullmatch(ch):
                    visible.append(ch)
                    positions.append((pi, ci, oi))

    if not visible:
        return text

    readings = lazy_pinyin(
        visible, style=Style.TONE3, neutral_tone_with_five=True,
        errors=lambda chars: list(chars), tone_sandhi=sandhi,
    )
    tone_by_pos = {}
    for pos, reading in zip(positions, readings):
        m = re.search(r"([1-5])$", reading)
        tone_by_pos[pos] = int(m.group(1)) if m else 5

    rebuilt = []
    for pi, piece in enumerate(pieces):
        if not piece or (piece.startswith("{") and piece.endswith("}")):
            rebuilt.append(piece)
            continue
        chunks = re.split(r"(\\[Nnh])", piece)
        out_chunks = []
        last_color = None
        for ci, chunk in enumerate(chunks):
            if not chunk:
                continue
            if re.fullmatch(r"\\[Nnh]", chunk):
                out_chunks.append(chunk)
                last_color = None
                continue
            chars = []
            for oi, ch in enumerate(chunk):
                tone = tone_by_pos.get((pi, ci, oi))
                if tone is not None:
                    color = COLORS.get(tone, NORMAL)
                    if color != last_color:
                        chars.append(r"{\1c" + color + "}")
                        last_color = color
                chars.append(ch)
            out_chunks.append("".join(chars))
        rebuilt.append("".join(out_chunks))
    return "".join(rebuilt)

def build_ass_preserving(input_path, output_path, sandhi=False):
    """Preserve an ASS/SSA file and modify only Dialogue text fields."""
    text = decode_subtitle(input_path)
    lines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    in_events = False
    text_index = 9  # standard ASS default
    event_fields = 10
    count = 0
    out = []

    for line in lines:
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            in_events = stripped.lower() == "[events]"
            out.append(line)
            continue

        if in_events and line.lower().startswith("format:"):
            fmt = line.split(":", 1)[1]
            names = [x.strip().lower() for x in fmt.split(",")]
            if "text" in names:
                text_index = names.index("text")
                event_fields = len(names)
            out.append(line)
            continue

        if in_events and line.lower().startswith("dialogue:"):
            prefix, payload = line.split(":", 1)
            # Text is conventionally last, but honor the Events Format field.
            fields = payload.lstrip().split(",", event_fields - 1)
            if len(fields) >= event_fields and text_index < len(fields):
                fields[text_index] = color_ass_visible_text(fields[text_index], sandhi)
                line = prefix + ": " + ",".join(fields)
                count += 1
        out.append(line)

    if count == 0:
        raise ValueError("no ASS/SSA Dialogue events were found")
    Path(output_path).write_text("\n".join(out), encoding="utf-8-sig")
    return count

def build_ass(input_path, output_path, font, font_size, bold=0, italic=0,
              outline=1.65, outline_color="&H00000000&",
              shadow=0, shadow_color="&H00000000&", spacing=0, blur=0,
              alignment=2, margin_x=19, margin_y=34, sandhi=False):
    ext = Path(input_path).suffix.lower()
    if ext in (".ass", ".ssa"):
        return build_ass_preserving(input_path, output_path, sandhi)
    if ext != ".srt":
        raise ValueError("full-track mode supports external .srt, .ass and .ssa subtitles")

    events = parse_srt(decode_subtitle(input_path))
    if not events:
        raise ValueError("no SRT subtitle events were found")

    # Font size is intentionally kept in the ASS style instead of manual OSD
    # positioning. mpv/libass can apply its normal subtitle positioning to this
    # real subtitle track.
    font = str(font or "sans-serif").replace(",", " ")
    size = float(font_size or 55)
    margin_x = max(0, int(round(float(margin_x or 0))))
    margin_y = max(0, int(round(float(margin_y or 0))))
    bold = int(bold or 0)
    italic = int(italic or 0)
    outline = max(0.0, float(outline or 0))
    shadow = max(0.0, float(shadow or 0))
    spacing = float(spacing or 0)
    blur = max(0.0, float(blur or 0))
    alignment = int(alignment or 2)

    header = f"""[Script Info]
ScriptType: v4.00+
PlayResX: 1280
PlayResY: 720
ScaledBorderAndShadow: yes
WrapStyle: 0

[V4+ Styles]
Format: Name,Fontname,Fontsize,PrimaryColour,SecondaryColour,OutlineColour,BackColour,Bold,Italic,Underline,StrikeOut,ScaleX,ScaleY,Spacing,Angle,BorderStyle,Outline,Shadow,Alignment,MarginL,MarginR,MarginV,Encoding
Style: Default,{font},{size},&H00FCFCFC,&H000000FF,{outline_color},{shadow_color},{bold},{italic},0,0,100,100,{spacing},0,1,{outline},{shadow},{alignment},{margin_x},{margin_x},{margin_y},1

[Events]
Format: Layer,Start,End,Style,Name,MarginL,MarginR,MarginV,Effect,Text
"""
    lines = [header]
    for start, end, body in events:
        blur_tag = rf"{{\blur{blur:g}}}" if blur > 0 else ""
        lines.append(
            f"Dialogue: 0,{start},{end},Default,,0,0,0,,{blur_tag}{color_text(body, sandhi)}\n"
        )
    Path(output_path).write_text("".join(lines), encoding="utf-8-sig")
    return len(events)

def main():
    if len(sys.argv) < 3 or sys.argv[1] != "build":
        print(json.dumps({"ok": False, "error": "invalid helper arguments"}, ensure_ascii=False))
        sys.exit(2)
    req = json.loads(sys.argv[2])
    try:
        apply_tone_colors(req.get("tone_colors"))
        count = build_ass(
            req["input"], req["output"],
            req.get("font", "sans-serif"),
            req.get("font_size", 55),
            req.get("bold", 0),
            req.get("italic", 0),
            req.get("outline", 1.65),
            req.get("outline_color", "&H00000000&"),
            req.get("shadow", 0),
            req.get("shadow_color", "&H00000000&"),
            req.get("spacing", 0),
            req.get("blur", 0),
            req.get("alignment", 2),
            req.get("margin_x", 19),
            req.get("margin_y", 34),
            bool(req.get("tone_sandhi", False)),
        )
        print(json.dumps({"ok": True, "events": count, "output": req["output"]}, ensure_ascii=False))
    except Exception as e:
        print(json.dumps({"ok": False, "error": str(e)}, ensure_ascii=False))
        sys.exit(1)

if __name__ == "__main__":
    main()
