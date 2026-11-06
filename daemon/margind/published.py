"""Web pages and services Claude publishes for a project ("Station dashboard"
→ localhost:5173/owner), shown in that project's Preview tab in the app.
Kept across restarts; each one shows whether anything answers on its port."""
from __future__ import annotations

import json
import re
import socket
import time
import uuid
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

LOCAL = {"localhost", "127.0.0.1", "0.0.0.0", "::1", "[::1]"}


class PublishError(ValueError):
    pass


def parse_local_url(url: str) -> tuple[int, str]:
    """http://localhost:5173/owner?x=1 → (5173, "/owner?x=1"). Only this computer."""
    u = urlsplit(url.strip())
    if u.scheme not in ("http", "https") or (u.hostname or "") not in {h.strip("[]") for h in LOCAL}:
        raise PublishError("use a http://localhost:<port>/... address on this computer")
    port = u.port or (443 if u.scheme == "https" else 80)
    path = (u.path or "/") + (f"?{u.query}" if u.query else "") + (f"#{u.fragment}" if u.fragment else "")
    return port, path


class PublishedStore:
    def __init__(self, path: Path) -> None:
        self.path = path
        try:
            self.items: dict[str, list[dict[str, Any]]] = json.loads(path.read_text())
        except (OSError, ValueError):
            self.items = {}

    def _save(self) -> None:
        self.path.write_text(json.dumps(self.items, indent=1))

    def publish(self, project: str, name: str, url: str, description: str = "",
                kind: str = "page", session_id: str | None = None) -> dict[str, Any]:
        name = re.sub(r"\s+", " ", name).strip()[:80]
        if not name:
            raise PublishError("give it a name")
        if kind not in ("page", "service"):
            raise PublishError("kind is page or service")
        port, path = parse_local_url(url)
        pages = self.items.setdefault(project, [])
        existing = next((p for p in pages if p["name"].lower() == name.lower()), None)
        entry = {"id": existing["id"] if existing else uuid.uuid4().hex[:8], "name": name, "kind": kind,
                 "port": port, "path": path, "description": description.strip()[:300],
                 "session_id": session_id, "updated_at": time.time()}
        if existing:
            pages[pages.index(existing)] = entry
        else:
            pages.append(entry)
        self._save()
        return entry

    def remove(self, project: str, name_or_id: str) -> bool:
        pages = self.items.get(project, [])
        keep = [p for p in pages if name_or_id not in (p["id"], p["name"]) and p["name"].lower() != name_or_id.lower()]
        if len(keep) == len(pages):
            return False
        self.items[project] = keep
        self._save()
        return True

    def list(self, project: str) -> list[dict[str, Any]]:
        return [{**p, "alive": _answers(p["port"])} for p in self.items.get(project, [])]


def _answers(port: int) -> bool:
    for host in ("127.0.0.1", "::1"):
        try:
            with socket.create_connection((host, port), timeout=0.25):
                return True
        except OSError:
            continue
    return False
