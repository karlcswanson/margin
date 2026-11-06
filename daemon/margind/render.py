"""Host-side renders of files iOS can't show natively: KiCad schematics become
a PDF (every sheet), boards an SVG of the copper/silk/outline layers or a
ray-traced 3D PNG. Renders are cached by path and modification time."""
from __future__ import annotations

import asyncio
import glob
import hashlib
import os
import re
import shutil
import sys
from pathlib import Path

from .config import WorkspaceConfig

TIMEOUT = 180
WINDOWS = sys.platform == "win32"

PCB_LAYERS = "F.Cu,B.Cu,F.Paste,F.SilkS,B.SilkS,F.Mask,Edge.Cuts"

# extension -> {view: output extension}
VIEWS: dict[str, dict[str, str]] = {
    ".kicad_sch": {"2d": "pdf"},
    ".kicad_pcb": {"2d": "svg", "3d": "png"},
}

_locks: dict[str, asyncio.Lock] = {}


class RenderError(Exception):
    pass


def kicad_cli(ws: WorkspaceConfig | None = None) -> str | None:
    configured = ws.kicad_cli if ws else None
    candidates = [configured, shutil.which("kicad-cli"),
                  "/Applications/KiCad/KiCad.app/Contents/MacOS/kicad-cli", *_windows_kicads()]
    for c in candidates:
        if c and os.path.isfile(os.path.expanduser(c)):
            return os.path.expanduser(c)
    return None


def _windows_kicads() -> list[str]:
    r"""C:\Program Files\KiCad\<version>\bin\kicad-cli.exe, newest version first
    (by number: 10.0 is newer than 9.0)."""
    if not WINDOWS:
        return []
    base = os.environ.get("ProgramFiles") or r"C:\Program Files"
    found = glob.glob(os.path.join(base, "KiCad", "*", "bin", "kicad-cli.exe"))

    def version(path: str) -> tuple[int, ...]:
        v = os.path.basename(os.path.dirname(os.path.dirname(path)))
        return tuple(int(n) for n in re.findall(r"\d+", v))
    return sorted(found, key=version, reverse=True)


def cache_path(ws: WorkspaceConfig, src: Path, view: str, ext: str) -> Path:
    st = src.stat()
    key = hashlib.sha1(f"{src}\0{st.st_mtime_ns}\0{st.st_size}\0{view}".encode()).hexdigest()[:20]
    return ws.state_path / "renders" / f"{key}.{ext}"


def views_for(path: Path) -> dict[str, str]:
    return VIEWS.get(path.suffix.lower(), {})


def _command(cli: str, src: Path, view: str, out: Path) -> list[str]:
    ext = src.suffix.lower()
    if ext == ".kicad_sch":
        return [cli, "sch", "export", "pdf", "-o", str(out), str(src)]
    if ext == ".kicad_pcb" and view == "2d":
        return [cli, "pcb", "export", "svg", "--mode-single", "--layers", PCB_LAYERS,
                "--page-size-mode", "2", "--exclude-drawing-sheet", "-o", str(out), str(src)]
    if ext == ".kicad_pcb" and view == "3d":
        return [cli, "pcb", "render", "--rotate", "-40,0,30", "--perspective", "--quality", "high",
                "--width", "1600", "--height", "1200", "--background", "opaque", "-o", str(out), str(src)]
    raise RenderError(f"no {view} render for {src.name}")


async def render(ws: WorkspaceConfig, src: Path, view: str = "2d") -> Path:
    out_ext = views_for(src).get(view)
    if not out_ext:
        raise RenderError(f"can't render {src.name} as {view}")
    cli = kicad_cli(ws)
    if not cli:
        raise RenderError("kicad-cli not found on this host (install KiCad, or set kicad_cli in the workspace TOML)")
    out = cache_path(ws, src, view, out_ext)
    key = out.stem
    if out.is_file():
        return out
    async with _locks.setdefault(key, asyncio.Lock()):
        if out.is_file():
            return out
        out.parent.mkdir(parents=True, exist_ok=True)
        tmp = out.with_name(f"{key}.tmp.{out_ext}")
        proc = await asyncio.create_subprocess_exec(
            *_command(cli, src, view, tmp), cwd=str(src.parent),
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT)
        try:
            log, _ = await asyncio.wait_for(proc.communicate(), TIMEOUT)
        except asyncio.TimeoutError:
            proc.kill()
            raise RenderError(f"rendering {src.name} took too long")
        if proc.returncode != 0 or not tmp.is_file():
            tail = log.decode(errors="replace").strip().splitlines()[-3:]
            raise RenderError(f"kicad-cli failed on {src.name}: " + " / ".join(tail))
        tmp.replace(out)
    _locks.pop(key, None)
    return out
