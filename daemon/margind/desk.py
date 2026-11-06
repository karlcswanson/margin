"""Opening a project at the desk: in one of the editors installed on this
computer, or in Finder / Explorer. Used by the local page's buttons.

Only an editor found here and a configured project's folder can be opened:
the page sends names, never a path or a command.
"""
from __future__ import annotations

import glob
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

# macOS apps, by the name of their .app bundle.
MAC_APPS = [
    "Visual Studio Code", "Visual Studio Code - Insiders", "Cursor", "Zed", "Nova", "Sublime Text", "BBEdit",
    "Xcode", "IntelliJ IDEA", "IntelliJ IDEA CE", "IntelliJ IDEA Ultimate", "PyCharm", "PyCharm CE",
    "PyCharm Professional Edition", "PyCharm Community Edition", "WebStorm", "CLion", "GoLand", "RustRover",
    "PhpStorm", "Rider", "RubyMine", "DataGrip", "Fleet", "Android Studio",
]

# Commands on PATH (Linux, and Windows launchers like code.cmd).
COMMANDS = [
    ("code", "Visual Studio Code"), ("cursor", "Cursor"), ("zed", "Zed"), ("subl", "Sublime Text"),
    ("idea", "IntelliJ IDEA"), ("pycharm", "PyCharm"), ("webstorm", "WebStorm"), ("clion", "CLion"),
    ("goland", "GoLand"), ("rustrover", "RustRover"), ("phpstorm", "PhpStorm"), ("rider", "Rider"),
    ("rubymine", "RubyMine"), ("fleet", "Fleet"), ("studio", "Android Studio"),
]


def _id(name: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")


def _mac() -> list[tuple[str, str]]:
    dirs = ["/Applications", os.path.expanduser("~/Applications"),
            os.path.expanduser("~/Applications/JetBrains Toolbox"), "/Applications/JetBrains Toolbox"]
    found = []
    for name in MAC_APPS:
        for d in dirs:
            p = os.path.join(d, name + ".app")
            if os.path.isdir(p):
                found.append((name, p))
                break
    return found


def _windows() -> list[tuple[str, str]]:
    found: dict[str, str] = {}
    local = os.environ.get("LOCALAPPDATA", "")
    vscode = os.path.join(local, "Programs", "Microsoft VS Code", "Code.exe")
    if os.path.isfile(vscode):
        found["Visual Studio Code"] = vscode
    # JetBrains IDEs, installed directly or by the Toolbox: <IDE>\bin\<ide>64.exe
    roots = [os.path.join(os.environ.get("ProgramFiles", r"C:\Program Files"), "JetBrains", "*"),
             os.path.join(local, "Programs", "*"), os.path.join(local, "JetBrains", "Toolbox", "apps", "*", "*", "*")]
    for root in roots:
        for exe in sorted(glob.glob(os.path.join(root, "bin", "*64.exe"))):
            stem = Path(exe).name.removesuffix("64.exe").lower()
            name = next((n for c, n in COMMANDS if c == stem), None)
            if name and name not in found:
                found[name] = exe
    for cmd, name in COMMANDS:
        if name not in found and (p := shutil.which(cmd)):
            found[name] = p
    return sorted(found.items())


def _linux() -> list[tuple[str, str]]:
    return [(name, p) for cmd, name in COMMANDS if (p := shutil.which(cmd))]


def _find() -> list[tuple[str, str]]:
    if sys.platform == "darwin":
        return _mac()
    if sys.platform == "win32":
        return _windows()
    return _linux()


def editors() -> list[dict[str, str]]:
    """The editors on this computer, for the "Open in" menu."""
    return [{"id": _id(n), "name": n} for n, _ in _find()]


class DeskError(ValueError):
    pass


def _launch(argv: list[str]) -> None:
    kw: dict = {"stdin": subprocess.DEVNULL, "stdout": subprocess.DEVNULL, "stderr": subprocess.DEVNULL}
    if sys.platform == "win32":
        kw["creationflags"] = subprocess.DETACHED_PROCESS | subprocess.CREATE_NEW_PROCESS_GROUP
        if argv[0].lower().endswith((".cmd", ".bat")):
            argv = ["cmd", "/c", *argv]
    else:
        kw["start_new_session"] = True
    subprocess.Popen(argv, **kw)


def open_in(editor_id: str, folder: str) -> str:
    """Opens the folder in that editor; returns the editor's name."""
    if not os.path.isdir(folder):
        raise DeskError("the project folder isn't there")
    match = next(((n, p) for n, p in _find() if _id(n) == editor_id), None)
    if match is None:
        raise DeskError("that editor isn't installed here")
    name, where = match
    _launch(["open", "-a", where, folder] if sys.platform == "darwin" else [where, folder])
    return name


def open_folder(folder: str) -> None:
    if not os.path.isdir(folder):
        raise DeskError("the project folder isn't there")
    if sys.platform == "darwin":
        _launch(["open", folder])
    elif sys.platform == "win32":
        _launch(["explorer", os.path.normpath(folder)])
    else:
        _launch(["xdg-open", folder])
