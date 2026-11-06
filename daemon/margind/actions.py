"""Buttons Claude sets up for a project ("Flash firmware", "Run tests"),
shown above the message box in the app. Kept in <project>/.margin/actions.json
so they last and can be edited by hand.

A button runs a command in a new project shell (output visible, the shell
stays open after), sends Claude a prompt, or opens a local web page.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import time
from pathlib import Path
from typing import Any

from .published import PublishError, parse_local_url
from .terminals import is_project_dir

KINDS = ("run", "prompt", "open")


class ActionError(ValueError):
    pass


def _path(root: str) -> Path:
    return Path(root) / ".margin" / "actions.json"


def load(root: str) -> list[dict[str, Any]]:
    try:
        items = json.loads(_path(root).read_text())
    except (OSError, ValueError):
        return []
    return [a | {"fingerprint": fingerprint(a)} for a in items if isinstance(a, dict) and a.get("label")]


def fingerprint(a: dict[str, Any]) -> str:
    """Changes when what the button does changes: the app asks again before running it."""
    what = json.dumps([a.get("kind"), a.get("command"), a.get("prompt"), a.get("url"), a.get("cwd")])
    return hashlib.sha256(what.encode()).hexdigest()[:16]


def save(root: str, items: list[dict[str, Any]]) -> None:
    from .sessions import _git_exclude
    p = _path(root)
    p.parent.mkdir(parents=True, exist_ok=True)
    _git_exclude(root, ".margin/")
    p.write_text(json.dumps([{k: v for k, v in a.items() if k != "fingerprint"} for a in items], indent=1) + "\n")


def set_action(root: str, label: str, *, command: str = "", prompt: str = "", url: str = "",
               description: str = "", icon: str = "", cwd: str = "") -> dict[str, Any]:
    label = re.sub(r"\s+", " ", label).strip()[:40]
    if not label:
        raise ActionError("give the button a label")
    given = [k for k, v in (("run", command), ("prompt", prompt), ("open", url)) if v.strip()]
    if len(given) != 1:
        raise ActionError("give exactly one of command, prompt or url")
    kind = given[0]
    a: dict[str, Any] = {"label": label, "kind": kind, "description": description.strip()[:200],
                         "icon": re.sub(r"[^a-z0-9.]", "", icon.lower())[:40], "updated_at": time.time()}
    if kind == "run":
        a["command"] = command.strip()
        if cwd:
            full = os.path.realpath(os.path.join(root, cwd))
            if not is_project_dir(full, root):
                raise ActionError("cwd must be inside the project")
            a["cwd"] = os.path.relpath(full, os.path.realpath(root))
    elif kind == "prompt":
        a["prompt"] = prompt.strip()
    else:
        try:
            parse_local_url(url)
        except PublishError as e:
            raise ActionError(str(e))
        a["url"] = url.strip()
    items = [x for x in load(root) if x["label"].lower() != label.lower()]
    items.append(a)
    save(root, items[-12:])
    return a | {"fingerprint": fingerprint(a)}


def remove_action(root: str, label: str) -> bool:
    items = load(root)
    keep = [x for x in items if x["label"].lower() != label.strip().lower()]
    if len(keep) == len(items):
        return False
    save(root, keep)
    return True
