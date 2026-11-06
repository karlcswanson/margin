"""STEP assemblies for the iPad's 3D viewer. iOS can't read STEP, so a Python
with OpenCascade (cadquery-ocp) converts it on the host into "margin-parts/1"
JSON: one mesh per part instance with its name and colour (see step_worker.py).
That interpreter is usually a separate venv; nothing CAD lives in the daemon's."""
from __future__ import annotations

import asyncio
import glob
import importlib.util
import os
import subprocess
import sys
from pathlib import Path

from .config import WorkspaceConfig
from .render import TIMEOUT, RenderError, cache_path

EXTS = (".step", ".stp")
VIEWS = ("parts", "2d")         # "2d" is the default view of /v1/render; same JSON
WORKER = Path(__file__).with_name("step_worker.py")
# runs the worker without putting its directory (or the project's) on sys.path
_BOOT = "import runpy, sys; runpy.run_path(sys.argv[1], run_name='__main__')"

_found: dict[str | None, str | None] = {}
_locks: dict[str, asyncio.Lock] = {}


def handles(path: Path) -> bool:
    return path.suffix.lower() in EXTS


def _has_ocp(python: str) -> bool:
    if os.path.realpath(python) == os.path.realpath(sys.executable):
        return importlib.util.find_spec("OCP") is not None
    try:
        return subprocess.run([python, "-c", "import OCP"], capture_output=True, timeout=60).returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def cad_python(ws: WorkspaceConfig | None = None) -> str | None:
    """A Python that can import OCP: the configured one, ours, or a ~/.venvs/* venv."""
    configured = ws.cad_python if ws else None
    if configured in _found:
        return _found[configured]
    if configured:
        candidates = [os.path.expanduser(configured)]
    else:
        home = os.path.expanduser("~/.venvs")
        candidates = [sys.executable, *sorted(glob.glob(f"{home}/*/bin/python")),
                      *sorted(glob.glob(f"{home}/*/Scripts/python.exe"))]
    _found[configured] = next((c for c in candidates if os.path.isfile(c) and _has_ocp(c)), None)
    return _found[configured]


async def convert(ws: WorkspaceConfig, src: Path, view: str = "parts") -> Path:
    if view not in VIEWS:
        raise RenderError(f"can't render {src.name} as {view} (STEP has a \"parts\" view)")
    python = await asyncio.to_thread(cad_python, ws)
    if not python:
        raise RenderError("STEP needs OpenCascade: set cad_python to a Python with cadquery-ocp "
                          "(pip install cadquery-ocp) in the workspace TOML")
    # keyed on the worker too, so an improved converter redoes old files
    out = cache_path(ws, src, f"parts\0{WORKER.stat().st_mtime_ns}", "json")
    if out.is_file():
        return out
    key = out.stem
    async with _locks.setdefault(key, asyncio.Lock()):
        if out.is_file():
            return out
        out.parent.mkdir(parents=True, exist_ok=True)
        tmp = out.with_name(f"{key}.tmp.json")
        proc = await asyncio.create_subprocess_exec(
            python, "-c", _BOOT, str(WORKER), str(src), str(tmp), cwd=str(out.parent),
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT)
        try:
            log, _ = await asyncio.wait_for(proc.communicate(), TIMEOUT)
        except asyncio.TimeoutError:
            proc.kill()
            raise RenderError(f"converting {src.name} took too long")
        if proc.returncode != 0 or not tmp.is_file():
            tmp.unlink(missing_ok=True)
            tail = log.decode(errors="replace").strip().splitlines()[-3:]
            raise RenderError(f"STEP conversion failed on {src.name}: " + " / ".join(tail))
        tmp.replace(out)
    _locks.pop(key, None)
    return out
