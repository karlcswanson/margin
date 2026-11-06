"""Ideas you jot down for a project, to bring into a chat when the time is
right. Kept in <project>/.margin/ideas.json so they last and can be read at
the desk too. Nothing here reaches Claude until you use an idea in a chat.

The app writes them by id (PUT is an upsert), so an idea added while the
computer was out of reach can be sent again safely when it's back.
"""
from __future__ import annotations

import json
import re
import time
from pathlib import Path
from typing import Any

KEEP = 300


class IdeaError(ValueError):
    pass


def _path(root: str) -> Path:
    return Path(root) / ".margin" / "ideas.json"


def load(root: str) -> list[dict[str, Any]]:
    try:
        items = json.loads(_path(root).read_text())
    except (OSError, ValueError):
        return []
    return [i for i in items if isinstance(i, dict) and i.get("id") and isinstance(i.get("text"), str)]


def save(root: str, items: list[dict[str, Any]]) -> None:
    from .sessions import _git_exclude
    p = _path(root)
    p.parent.mkdir(parents=True, exist_ok=True)
    _git_exclude(root, ".margin/")
    tmp = p.with_suffix(".tmp")
    tmp.write_text(json.dumps(items, indent=1) + "\n")
    tmp.replace(p)


def put(root: str, idea_id: str, text: str, *, created_at: float | None = None,
        used_in: str | None = None, used_at: float | None = None) -> dict[str, Any]:
    if not re.fullmatch(r"[A-Za-z0-9-]{1,64}", idea_id):
        raise IdeaError("bad idea id")
    text = text.strip()
    if not text:
        raise IdeaError("the idea is empty")
    items = load(root)
    old = next((i for i in items if i["id"] == idea_id), None)
    idea = {"id": idea_id, "text": text[:20000],
            "created_at": created_at or (old or {}).get("created_at") or time.time(),
            "updated_at": time.time(), "used_in": used_in or None, "used_at": used_at if used_in else None}
    items = [i for i in items if i["id"] != idea_id] + [idea]
    items.sort(key=lambda i: i.get("created_at") or 0)
    # Too many: drop the oldest used ones first.
    while len(items) > KEEP:
        used = [i for i in items if i.get("used_in")]
        items.remove(used[0] if used else items[0])
    save(root, items)
    return idea


def remove(root: str, idea_id: str) -> bool:
    items = load(root)
    keep = [i for i in items if i["id"] != idea_id]
    if len(keep) == len(items):
        return False
    save(root, keep)
    return True
