"""Transcript normalization: media references, inline images, input clipping."""
from margind import normalize


def test_written_image_and_markdown_images_become_media():
    items = normalize.from_history("assistant", {"content": [
        {"type": "tool_use", "id": "t1", "name": "Write",
         "input": {"file_path": "/p/out/logo.svg", "content": "<svg/>"}},
        {"type": "tool_use", "id": "t2", "name": "Write",
         "input": {"file_path": "/p/main.py", "content": "print(1)"}},
        {"type": "text", "text": "Here: ![logo](out/logo.svg) and `out/board.PNG`, not ![x](https://a/b.png)"},
    ]})
    assert items[0]["media"] == ["/p/out/logo.svg"]
    assert "media" not in items[1]
    assert items[2]["media"] == ["out/logo.svg", "out/board.PNG"]


def test_tool_result_images_inline_when_small():
    small = {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": "QUJD"}}
    big = {"type": "image", "source": {"type": "base64", "media_type": "image/png",
                                       "data": "A" * (normalize.MAX_INLINE_IMAGE + 1)}}
    items = normalize.from_history("user", {"content": [
        {"type": "tool_result", "tool_use_id": "t1", "content": [{"type": "text", "text": "shot"}, small, big]},
    ]})
    assert items[0]["images"] == [{"media_type": "image/png", "data": "QUJD"}]
    assert items[0]["text"] == "shot\n[image]\n[image]"


def test_long_edit_keeps_its_fields():
    old = "x" * (normalize.MAX_TOOL_FIELD + 10)
    items = normalize.from_history("assistant", {"content": [
        {"type": "tool_use", "id": "t1", "name": "Edit",
         "input": {"file_path": "/p/a.py", "old_string": old, "new_string": "y"}},
    ]})
    inp = items[0]["input"]
    assert inp["file_path"] == "/p/a.py" and inp["new_string"] == "y"
    assert inp["old_string"].startswith("x" * 100) and "more characters" in inp["old_string"]


def test_models_and_pdfs_are_media():
    items = normalize.from_history("assistant", {"content": [
        {"type": "text", "text": "Top: ![top](enclosure/v4/v4-top.stl), datasheet `docs/w5500.pdf`"},
    ]})
    assert items[0]["media"] == ["enclosure/v4/v4-top.stl", "docs/w5500.pdf"]
