"""Unit tests for helska/helska_tone_colors.py.

The helper is pure and deterministic, so these tests pin its behaviour
(RGB->BGR conversion, tone-colour map, ASS timestamps, SRT parsing, escaping)
so later edits cannot silently break it.

Run with:  python -m pytest tests -q
"""
import importlib.util
from pathlib import Path

MODULE_PATH = Path(__file__).resolve().parents[1] / "helska" / "helska_tone_colors.py"

_spec = importlib.util.spec_from_file_location("helska_tone_colors", MODULE_PATH)
tc = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(tc)  # requires pypinyin (see requirements note in README)


# --- colour conversion -----------------------------------------------------

def test_hex_to_ass_inverts_rgb_to_bgr():
    # #ec464f -> r=ec g=46 b=4f -> ASS &H<b><g><r>&
    assert tc.hex_to_ass("#ec464f") == "&H4F46EC&"
    assert tc.hex_to_ass("#FF8F40") == "&H408FFF&"


def test_default_tone_map_values():
    assert tc.COLORS[1] == "&H4F46EC&"
    assert tc.COLORS[3] == "&H43BF6C&"
    assert tc.COLORS[5] == "&HFCFCFC&"
    assert tc.NORMAL == tc.COLORS[5]


def test_normalize_hex():
    assert tc.normalize_hex("ec464f") == "#EC464F"
    assert tc.normalize_hex("#EC464F") == "#EC464F"
    assert tc.normalize_hex("  #ec464f ") == "#EC464F"
    assert tc.normalize_hex("nonsense") is None
    assert tc.normalize_hex(None) is None


def test_apply_tone_colors_overrides_and_resets():
    tc.apply_tone_colors({1: "#112233"})
    assert tc.COLORS[1] == tc.hex_to_ass("#112233")
    assert tc.NORMAL == tc.COLORS[5]
    # The next call starts from the built-in defaults again.
    tc.apply_tone_colors(None)
    assert tc.COLORS[1] == "&H4F46EC&"


def test_apply_tone_colors_ignores_bad_values():
    tc.apply_tone_colors({1: "not-a-color", 2: "#000000"})
    assert tc.COLORS[1] == "&H4F46EC&"                 # default kept
    assert tc.COLORS[2] == tc.hex_to_ass("#000000")    # valid value applied


# --- timestamps ------------------------------------------------------------

def test_ass_time_centiseconds():
    assert tc.ass_time(("0", "0", "3", "40")) == "0:00:03.04"
    assert tc.ass_time(("1", "2", "3", "456")) == "1:02:03.46"


def test_ass_time_carries_over():
    # 59.995s rounds to 100 centiseconds -> carries into the next second.
    assert tc.ass_time(("0", "0", "59", "995")) == "0:01:00.00"


# --- SRT parsing -----------------------------------------------------------

SRT = (
    "1\r\n"
    "00:00:01,000 --> 00:00:03,000\r\n"
    "你好\r\n"
    "\r\n"
    "2\r\n"
    "00:00:03,500 --> 00:00:05,250\r\n"
    "world\r\n"
)


def test_parse_srt_cue_count_and_timestamps():
    events = tc.parse_srt(SRT)
    assert len(events) == 2
    assert events[0][0] == "0:00:01.00"
    assert events[0][1] == "0:00:03.00"
    assert events[1][0] == "0:00:03.50"
    assert events[1][1] == "0:00:05.25"
    assert events[0][2] == "你好"


def test_parse_srt_empty():
    assert tc.parse_srt("") == []


# --- escaping --------------------------------------------------------------

def test_ass_escape_text_replaces_specials():
    assert tc.ass_escape_text("a{b}c\\d") == "a｛b｝c＼d"


def test_color_text_escapes_user_braces():
    out = tc.color_text("{x}")
    assert "｛x｝" in out


def test_multiline_cue_stays_one_event():
    # Visual line breaks become ASS's explicit \N escape, never a raw newline.
    assert "\\N" in tc.color_text("a\nb")


# --- end-to-end SRT -> ASS -------------------------------------------------

def test_build_ass_writes_one_dialogue_per_cue(tmp_path):
    src = tmp_path / "in.srt"
    src.write_bytes(SRT.encode("utf-8"))
    dst = tmp_path / "out.ass"

    count = tc.build_ass(str(src), str(dst), font="Arial", font_size=42)

    assert count == 2
    text = dst.read_text(encoding="utf-8-sig")
    assert text.count("\nDialogue:") == 2
    assert "Style: Default,Arial,42" in text
