"""Turn Agent SDK messages (live) and transcript entries (history) into one
small, stable JSON shape the app renders:

    {"kind": "user_text" | "text" | "thinking" | "tool_use" | "tool_result",
     ...kind-specific fields}

Items that show pictures also carry "media" (host paths of images, 3D models
or PDFs the app fetches from /v1/media) or "images" (small inline base64 images from tool
results, e.g. screenshots).
"""
from __future__ import annotations

import json
import re
from typing import Any

from claude_agent_sdk import (
    AssistantMessage,
    TextBlock,
    ThinkingBlock,
    ToolResultBlock,
    ToolUseBlock,
    UserMessage,
)

MAX_TEXT = 20_000
MAX_TOOL_IO = 20_000      # tool results (Read output, Bash output)
MAX_TOOL_FIELD = 40_000   # each string in a tool input (Write content, Edit old/new)
MAX_INLINE_IMAGE = 1_500_000  # base64 characters

# Files the app can show inline: images, 3D models, PDFs
MEDIA_EXTS = (".png", ".jpg", ".jpeg", ".gif", ".webp", ".heic", ".svg",
              ".stl", ".obj", ".ply", ".usdz", ".pdf",
              ".kicad_sch", ".kicad_pcb",   # rendered on the host (render.py)
              ".step", ".stp")              # converted on the host (step.py)
MEDIA_TOOLS = {"Write", "Edit", "MultiEdit", "Read", "NotebookEdit"}
# ![alt](path) and `path.png`, local paths only
_MD_IMAGE = re.compile(r"!\[[^\]]*\]\(<?([^)\s>]+)>?\)")
_CODE_PATH = re.compile(r"`([^`\s]+\.(?:png|jpe?g|gif|webp|heic|svg|stl|obj|ply|usdz|pdf|kicad_sch|kicad_pcb|step|stp))`", re.IGNORECASE)


def _clip(s: str, n: int) -> str:
    return s if len(s) <= n else s[:n] + f"\n… [{len(s) - n} more characters]"


def _tool_input(inp: Any) -> dict[str, Any]:
    # Clip field by field so the app still sees the shape (e.g. Edit's
    # old_string/new_string for a diff) even when the code is long.
    if isinstance(inp, dict):
        return {k: _clip_value(v) for k, v in inp.items()}
    return {"value": _clip_value(inp)}


def _clip_value(v: Any) -> Any:
    if isinstance(v, str):
        return _clip(v, MAX_TOOL_FIELD)
    if isinstance(v, dict):
        return {k: _clip_value(x) for k, x in v.items()}
    if isinstance(v, list):
        return [_clip_value(x) for x in v[:200]]
    try:
        json.dumps(v)
        return v
    except Exception:
        return str(v)


def _result_text(content: Any) -> str:
    if content is None:
        return ""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for c in content:
            if isinstance(c, dict):
                if c.get("type") == "text":
                    parts.append(c.get("text", ""))
                elif c.get("type") == "image":
                    parts.append("[image]")
            else:
                parts.append(str(c))
        return "\n".join(parts)
    return str(content)


def _is_media_path(p: Any) -> bool:
    return isinstance(p, str) and p.lower().endswith(MEDIA_EXTS) and "://" not in p


def _tool_media(name: Any, inp: Any) -> list[str]:
    if name in MEDIA_TOOLS and isinstance(inp, dict):
        p = inp.get("file_path") or inp.get("notebook_path")
        if _is_media_path(p):
            return [p]
    return []


def _text_media(text: str) -> list[str]:
    found = _MD_IMAGE.findall(text) + _CODE_PATH.findall(text)
    return list(dict.fromkeys(p for p in found if _is_media_path(p)))


def _result_images(content: Any) -> list[dict[str, str]]:
    out = []
    if isinstance(content, list):
        for c in content:
            if isinstance(c, dict) and c.get("type") == "image":
                src = c.get("source") or {}
                data = src.get("data")
                if src.get("type") == "base64" and isinstance(data, str) and len(data) <= MAX_INLINE_IMAGE:
                    out.append({"media_type": src.get("media_type", "image/png"), "data": data})
    return out


def _text_item(text: str) -> dict[str, Any]:
    it: dict[str, Any] = {"kind": "text", "text": _clip(text, MAX_TEXT)}
    if media := _text_media(text):
        it["media"] = media
    return it


def _tool_use_item(id: Any, name: Any, inp: Any) -> dict[str, Any]:
    it: dict[str, Any] = {"kind": "tool_use", "id": id, "name": name, "input": _tool_input(inp)}
    if media := _tool_media(name, inp):
        it["media"] = media
    return it


def _tool_result_item(tool_use_id: Any, is_error: Any, content: Any) -> dict[str, Any]:
    it: dict[str, Any] = {
        "kind": "tool_result",
        "tool_use_id": tool_use_id,
        "is_error": bool(is_error),
        "text": _clip(_result_text(content), MAX_TOOL_IO),
    }
    if images := _result_images(content):
        it["images"] = images
    return it


# ---- live SDK objects ----------------------------------------------------

def from_sdk(msg: Any) -> list[dict[str, Any]]:
    items: list[dict[str, Any]] = []
    if isinstance(msg, AssistantMessage):
        for b in msg.content:
            if isinstance(b, TextBlock):
                items.append(_text_item(b.text))
            elif isinstance(b, ThinkingBlock):
                items.append({"kind": "thinking", "text": _clip(b.thinking, MAX_TEXT)})
            elif isinstance(b, ToolUseBlock):
                items.append(_tool_use_item(b.id, b.name, b.input))
        if msg.error:
            items.append({"kind": "text", "text": f"⚠️ {msg.error}", "error": True})
    elif isinstance(msg, UserMessage) and isinstance(msg.content, list):
        for b in msg.content:
            if isinstance(b, ToolResultBlock):
                items.append(_tool_result_item(b.tool_use_id, b.is_error, b.content))
    for it in items:
        it["parent_tool_use_id"] = getattr(msg, "parent_tool_use_id", None)
    return items


# ---- stored transcript entries (get_session_messages) --------------------

def from_history(entry_type: str, message: Any) -> list[dict[str, Any]]:
    if not isinstance(message, dict):
        return []
    content = message.get("content")
    items: list[dict[str, Any]] = []
    if entry_type == "user":
        if isinstance(content, str):
            if not content.startswith("<"):  # skip command/system wrappers
                items.append({"kind": "user_text", "text": _clip(content, MAX_TEXT)})
        elif isinstance(content, list):
            for c in content:
                if not isinstance(c, dict):
                    continue
                if c.get("type") == "text" and not c.get("text", "").startswith("<"):
                    items.append({"kind": "user_text", "text": _clip(c["text"], MAX_TEXT)})
                elif c.get("type") == "tool_result":
                    items.append(_tool_result_item(c.get("tool_use_id"), c.get("is_error"), c.get("content")))
    elif entry_type == "assistant" and isinstance(content, list):
        for c in content:
            if not isinstance(c, dict):
                continue
            t = c.get("type")
            if t == "text":
                items.append(_text_item(c.get("text", "")))
            elif t == "thinking":
                items.append({"kind": "thinking", "text": _clip(c.get("thinking", ""), MAX_TEXT)})
            elif t == "tool_use":
                items.append(_tool_use_item(c.get("id"), c.get("name"), c.get("input")))
    return items
