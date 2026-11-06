"""Read-only file access inside a workspace's project folders, so the app can
browse a repo and preview PDFs, images, SVGs and 3D models."""
from __future__ import annotations

import mimetypes
import ntpath
import os
import sys
from pathlib import Path
from typing import Any

from .config import WorkspaceConfig

WINDOWS = sys.platform == "win32"
HIDDEN = {".git", "node_modules", "__pycache__", ".venv", "venv", ".DS_Store", ".pytest_cache"}

mimetypes.add_type("model/stl", ".stl")
mimetypes.add_type("model/obj", ".obj")
mimetypes.add_type("model/step", ".step")
mimetypes.add_type("model/step", ".stp")
mimetypes.add_type("model/vnd.usdz+zip", ".usdz")
mimetypes.add_type("text/markdown", ".md")
for ext in (".kicad_sch", ".kicad_pcb", ".kicad_pro", ".kicad_sym", ".kicad_mod", ".kicad_prl"):
    mimetypes.add_type("text/x-kicad", ext)


class PathError(Exception):
    pass


def resolve(ws: WorkspaceConfig, project: str, rel: str) -> Path:
    root = Path(ws.project(project).path).expanduser().resolve()
    if WINDOWS:
        rel = rel.lstrip("/\\")
        if ntpath.splitdrive(rel)[0]:           # C:...
            raise PathError("path escapes project")
    else:
        rel = rel.lstrip("/")
    target = (root / rel).resolve()
    if target != root and root not in target.parents:
        raise PathError("path escapes project")
    if any(_env_file(part) for part in target.relative_to(root).parts):
        raise PathError("refusing to serve env files")
    return target


def _env_file(part: str) -> bool:
    if WINDOWS:
        # NTFS: ".ENV", ".env." and ".env " all open .env, as does ".env::$DATA" (a stream of it).
        part = part.split(":")[0].rstrip(". ").lower()
    return part in (".env",) or part.startswith(".env.")


def resolve_any(ws: WorkspaceConfig, path: str, cwd: str | None = None) -> Path:
    """A host path Claude mentioned (absolute, or relative to the session's
    cwd), allowed only inside one of the workspace's projects."""
    p = Path(path).expanduser()
    if WINDOWS and _other_share(p, ws):
        raise PathError("path is outside this workspace's projects")
    if not p.is_absolute():
        if not cwd:
            raise PathError("relative path without a session folder")
        base = Path(cwd).expanduser().resolve()
        p = base / p
        if not p.exists():
            # Written relative to the project root while the session sat in a subfolder.
            for proj in ws.projects:
                root = Path(proj.path).expanduser().resolve()
                if (base == root or root in base.parents) and (root / path).exists():
                    p = root / path
                    break
            else:
                p = _unique_below(base, path) or p
    p = p.resolve()
    for proj in ws.projects:
        root = Path(proj.path).expanduser().resolve()
        if p == root or root in p.parents:
            return resolve(ws, proj.name, str(p.relative_to(root)))
    raise PathError("path is outside this workspace's projects")


def _other_share(p: Path, ws: WorkspaceConfig) -> bool:
    r"""A network path (\\server\share\...) that no project is on. Checked
    before anything touches it: even looking it up would connect to that
    server and offer it this user's Windows credentials."""
    drive = p.drive
    if not drive.startswith(("\\\\", "//")):
        return False
    return all(Path(proj.path).expanduser().drive.lower() != drive.lower() for proj in ws.projects)


def _unique_below(base: Path, rel: str, max_depth: int = 4) -> Path | None:
    """Written relative to a subfolder the shell had moved into: the file
    below `base` whose path ends with `rel`. When several match (a copy of a
    folder elsewhere in the project), the most recently changed one: that's
    the one Claude has just been working on."""
    tail = Path(rel).parts
    found: list[Path] = []
    for dirpath, dirnames, _ in os.walk(base):
        d = Path(dirpath)
        depth = len(d.relative_to(base).parts)
        dirnames[:] = [n for n in dirnames if not n.startswith(".") and n != "node_modules"] if depth < max_depth else []
        if depth and (d / Path(*tail)).is_file():
            found.append(d / Path(*tail))
            if len(found) > 20:
                break
    return max(found, key=lambda f: f.stat().st_mtime) if found else None


def kind_for(name: str) -> str:
    n = name.lower()
    ext = os.path.splitext(n)[1]
    if ext in (".png", ".jpg", ".jpeg", ".gif", ".webp", ".heic"):
        return "image"
    if ext == ".svg":
        return "svg"
    if ext == ".pdf":
        return "pdf"
    if ext in (".stl", ".obj", ".usdz", ".ply"):
        return "model"
    if ext in (".step", ".stp"):
        return "cad"
    if ext in (".kicad_sch", ".kicad_pcb"):
        return "kicad"
    if ext in (".md", ".markdown"):
        return "markdown"
    if ext in (".csv",):
        return "csv"
    if ext in (".py", ".c", ".h", ".cpp", ".rs", ".js", ".ts", ".vue", ".swift", ".go", ".toml",
               ".yaml", ".yml", ".json", ".txt", ".rpt", ".log", ".sh", ".html", ".css", ".ini", ".cfg"):
        return "text"
    return "other"


def listing(ws: WorkspaceConfig, project: str, rel: str = "") -> list[dict[str, Any]]:
    d = resolve(ws, project, rel)
    if not d.is_dir():
        raise PathError("not a directory")
    root = Path(ws.project(project).path).expanduser().resolve()
    out = []
    for e in sorted(d.iterdir(), key=lambda p: (not p.is_dir(), p.name.lower())):
        if e.name in HIDDEN or e.name.startswith(".env"):
            continue
        st = e.stat()
        out.append({
            "name": e.name,
            "path": e.relative_to(root).as_posix(),   # "/" on Windows too, as the app expects
            "dir": e.is_dir(),
            "size": None if e.is_dir() else st.st_size,
            "modified": st.st_mtime,
            "kind": "dir" if e.is_dir() else kind_for(e.name),
        })
    return out


def media_type(path: Path) -> str:
    return mimetypes.guess_type(path.name)[0] or "application/octet-stream"
