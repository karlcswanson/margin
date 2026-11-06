"""Shells on this computer for the app: a PTY per shell, kept by the daemon
with its recent output, so the app can drop off and reattach (like mosh)
without losing anything.

On macOS/Linux each shell runs inside GNU screen when it's installed, named
`margin-<project>-<n>`, so it also outlives a daemon restart and can be
attached at the desk with `screen -x margin-<project>-<n>`. The PTY layer is
the only OS-specific part: pty here, ConPTY (pywinpty) on Windows, where
there is no screen and shells end with the daemon.
"""
from __future__ import annotations

import asyncio
import base64
import codecs
import logging
import os
import re
import shutil
import signal
import struct
import subprocess
import sys
import threading
import time
import uuid
from dataclasses import dataclass, field
from typing import Any

from .config import WorkspaceConfig

WINDOWS = sys.platform == "win32"
if not WINDOWS:
    import fcntl
    import termios

log = logging.getLogger("margind.terminals")

BUFFER = 512 * 1024          # output kept per shell for reattaching
SCREENRC = """\
startup_message off
defscrollback 10000
hardstatus off
defutf8 on
# Leave scrollback to the app's terminal instead of screen's alternate screen.
termcapinfo xterm* ti@:te@
"""


@dataclass
class Terminal:
    id: str
    project: str
    cwd: str
    name: str                      # screen session name, or a label
    screen: bool
    pid: int
    fd: int
    created_at: float = field(default_factory=time.time)
    buffer: bytearray = field(default_factory=bytearray)
    offset: int = 0                # total bytes ever written; buffer holds the last len(buffer)
    subscribers: set[asyncio.Queue] = field(default_factory=set)
    alive: bool = True
    title: str = ""
    cols: int = 100
    rows: int = 30
    pty: _WinPty | None = None   # Windows: the ConPTY (pid and fd are unused)
    outside: bool = False          # a screen session started outside Margin: closing only detaches

    def public(self) -> dict[str, Any]:
        return {"id": self.id, "project": self.project, "cwd": self.cwd, "name": self.name,
                "screen": self.screen, "alive": self.alive, "title": self.title, "outside": self.outside,
                "created_at": self.created_at, "offset": self.offset}


class Terminals:
    def __init__(self, ws: WorkspaceConfig) -> None:
        self.ws = ws
        self.items: dict[str, Terminal] = {}
        self.screen = shutil.which("screen") if ws.terminal_screen and not WINDOWS else None
        self._rc = ws.state_path / "screenrc"

    # -- listing ------------------------------------------------------------
    def list(self, project: str | None = None) -> list[dict[str, Any]]:
        out = [t.public() for t in self.items.values() if project in (None, t.project)]
        attached = {t.name for t in self.items.values()}
        # screen sessions from before a daemon restart: reattachable
        for name in self._screens():
            proj = name[len("margin-"):].rsplit("-", 1)[0]
            if name not in attached and project in (None, proj):
                out.append({"id": None, "project": proj, "name": name, "screen": True, "alive": True,
                            "detached": True})
        # and ones started some other way (by Claude, or at the desk) in a project's folder
        for name, (proj, cwd) in self.outside_screens().items():
            if name not in attached and project in (None, proj):
                out.append({"id": None, "project": proj, "cwd": cwd, "name": name, "screen": True,
                            "alive": True, "detached": True, "outside": True})
        return out

    def _all_screens(self) -> list[tuple[int, str]]:
        if not self.screen:
            return []
        try:
            out = subprocess.run([self.screen, "-ls"], capture_output=True, text=True, timeout=5).stdout
        except (OSError, subprocess.TimeoutExpired):
            return []
        return [(int(pid), name) for pid, name in re.findall(r"^\s*(\d+)\.([\w.-]+)\s", out, re.M)]

    def _screens(self) -> list[str]:
        return [name for _, name in self._all_screens() if name.startswith("margin-")]

    def outside_screens(self) -> dict[str, tuple[str, str]]:
        """Screen sessions not started by Margin whose program runs in a
        project's folder: name -> (project, folder)."""
        from .preview import _cwd_of
        roots = [(p.name, os.path.realpath(os.path.expanduser(p.path))) for p in self.ws.projects]
        found: dict[str, tuple[str, str]] = {}
        for pid, name in self._all_screens():
            if name.startswith("margin-"):
                continue
            cwd = next((c for c in map(_cwd_of, [*_children(pid), pid]) if c), None)
            proj = next((n for n, r in roots if cwd and is_project_dir(cwd, r)), None)
            if proj and cwd:
                found[name] = (proj, cwd)
        return found

    def screen_of(self, pids: list[int]) -> dict[int, str]:
        """For each process, the screen session it runs in, if any."""
        screens = dict(self._all_screens())
        if not screens:
            return {}
        out = {}
        for pid in pids:
            p = pid
            for _ in range(10):
                if p in screens:
                    out[pid] = screens[p]
                    break
                p = _parent(p)
                if p <= 1:
                    break
        return out

    def _wait_detached(self, name: str, timeout: float = 3.0) -> None:
        # Right after the daemon restarts, screen may still think the old
        # display is attached; attaching then hangs. Give it a moment.
        if not self.screen:
            return
        end = time.time() + timeout
        while time.time() < end:
            out = subprocess.run([self.screen, "-ls", name], capture_output=True, text=True, timeout=5).stdout
            if "(Detached)" in out or name not in out:
                return
            time.sleep(0.2)

    # -- starting -----------------------------------------------------------
    def open(self, project: str, cwd: str, name: str | None = None, command: str | None = None) -> Terminal:
        """A new shell in `cwd`, or (with the name of a screen session from
        `list`) that session again. With `command`, the shell runs it first
        and stays open after, so its output can be read and worked with."""
        outside = False
        if name:
            for t in self.items.values():
                if t.name == name and t.alive:
                    return t
            if not re.fullmatch(r"margin-[\w.-]+", name):
                if self.outside_screens().get(name, (None,))[0] != project:
                    raise ValueError("not a shell in this project")
                outside = True
            else:
                self._wait_detached(name)
        else:
            used = {t.name for t in self.items.values()} | set(self._screens())
            n = 1
            while f"margin-{_slug(project)}-{n}" in used:
                n += 1
            name = f"margin-{_slug(project)}-{n}"
        env = {**os.environ, "TERM": "xterm-256color", "COLORTERM": "truecolor", "LANG": os.environ.get("LANG", "en_US.UTF-8"),
               "MARGIN_SHELL": "1", "CLICOLOR": "1"}
        env.pop("CLAUDECODE", None)
        if WINDOWS:
            if command:
                env["MARGIN_COMMAND"] = command
            t = Terminal(id=uuid.uuid4().hex[:10], project=project, cwd=cwd, name=name, screen=False, pid=0, fd=-1)
            t.pty = _WinPty.spawn(_windows_argv(command), cwd, env, t.cols, t.rows)
            t.pid = t.pty.pid
            self.items[t.id] = t
            loop = asyncio.get_running_loop()
            # The proactor loop has no add_reader: a thread per shell blocks on
            # its output (a thread of its own, so shells don't use up asyncio's
            # shared pool for the life of the shell).
            threading.Thread(target=self._read_thread, args=(t, loop), daemon=True,
                             name=f"shell-{t.id}").start()
            log.info("shell %s (%s) in %s", t.id, name, cwd)
            return t
        shell = os.environ.get("SHELL") or "/bin/zsh"
        inner = [shell, "-l"]
        if command:
            env["MARGIN_COMMAND"] = command
            inner = [shell, "-lc", 'printf "\\033[1m$ %s\\033[0m\\n" "$MARGIN_COMMAND"; eval "$MARGIN_COMMAND"; '
                                   f'printf "\\n\\033[2m[exit $?]\\033[0m\\n"; exec {shell} -l']
        if self.screen:
            self._rc.write_text(SCREENRC)
            argv = [self.screen, "-c", str(self._rc), "-U", "-xRR", "-S", name, *inner]
        else:
            argv = inner
        pid, fd = _spawn(argv, cwd, env)
        t = Terminal(id=uuid.uuid4().hex[:10], project=project, cwd=cwd, name=name,
                     screen=bool(self.screen), pid=pid, fd=fd, outside=outside)
        self.items[t.id] = t
        _resize(fd, t.cols, t.rows)
        asyncio.get_running_loop().add_reader(fd, self._readable, t)
        log.info("shell %s (%s) in %s", t.id, name, cwd)
        return t

    def _readable(self, t: Terminal) -> None:
        try:
            data = os.read(t.fd, 65536)
        except OSError:
            data = b""
        if not data:
            self._ended(t)
            return
        self._received(t, data)

    def _read_thread(self, t: Terminal, loop: asyncio.AbstractEventLoop) -> None:
        while True:
            data = t.pty.read()                      # type: ignore[union-attr]
            try:
                loop.call_soon_threadsafe(self._got, t, data)
            except RuntimeError:                     # loop closed: daemon stopping
                return
            if not data:
                return

    def _got(self, t: Terminal, data: bytes) -> None:
        if data:
            self._received(t, data)
        else:
            self._ended(t)

    def _received(self, t: Terminal, data: bytes) -> None:
        t.buffer += data
        t.offset += len(data)
        if len(t.buffer) > BUFFER:
            del t.buffer[: len(t.buffer) - BUFFER]
        for q in list(t.subscribers):
            q.put_nowait(data)

    def _ended(self, t: Terminal) -> None:
        if not t.alive:
            return
        t.alive = False
        if t.pty is not None:
            t.pty.close()
        else:
            try:
                asyncio.get_running_loop().remove_reader(t.fd)
            except (ValueError, RuntimeError):
                pass
            try:
                os.close(t.fd)
            except OSError:
                pass
            try:
                os.waitpid(t.pid, os.WNOHANG)
            except ChildProcessError:
                pass
        for q in list(t.subscribers):
            q.put_nowait(None)
        self.items.pop(t.id, None)

    # -- talking to it --------------------------------------------------------
    def subscribe(self, t: Terminal, since: int | None) -> tuple[asyncio.Queue, bytes, bool]:
        """A queue of new output, plus what was missed since `since` (an
        offset from an earlier connection). `reset` means the app should
        clear its screen first: it missed more than is kept."""
        q: asyncio.Queue = asyncio.Queue()
        t.subscribers.add(q)
        start = t.offset - len(t.buffer)
        if since is not None and start <= since <= t.offset:
            return q, bytes(t.buffer[since - start:]), False
        return q, bytes(t.buffer), True

    def unsubscribe(self, t: Terminal, q: asyncio.Queue) -> None:
        t.subscribers.discard(q)

    def write(self, t: Terminal, data: bytes) -> None:
        if t.alive and t.pty is not None:
            if not t.pty.write(data):
                self._ended(t)
        elif t.alive:
            try:
                os.write(t.fd, data)
            except BlockingIOError:
                asyncio.get_running_loop().call_later(0.01, self.write, t, data)
            except OSError:
                self._ended(t)

    def resize(self, t: Terminal, cols: int, rows: int) -> None:
        cols, rows = max(10, min(cols, 500)), max(4, min(rows, 300))
        if t.alive and (cols, rows) != (t.cols, t.rows):
            t.cols, t.rows = cols, rows
            if t.pty is not None:
                t.pty.resize(cols, rows)
            else:
                _resize(t.fd, cols, rows)

    def close(self, t: Terminal) -> None:
        """End the shell for good (and its screen session). One started
        outside Margin is only let go of: it keeps running, as it was."""
        if t.screen and self.screen and not t.outside:
            subprocess.run([self.screen, "-S", t.name, "-X", "quit"], capture_output=True, timeout=5)
        if t.pty is None:
            try:
                os.killpg(t.pid, signal.SIGHUP)
            except OSError:
                pass
        self._ended(t)

    def quit_detached(self, name: str) -> None:
        if self.screen and re.fullmatch(r"margin-[\w.-]+", name):
            subprocess.run([self.screen, "-S", name, "-X", "quit"], capture_output=True, timeout=5)

    def shutdown(self) -> None:
        """Daemon stopping: drop the PTYs. Shells inside screen keep running."""
        for t in list(self.items.values()):
            if t.pty is None:
                try:
                    os.killpg(t.pid, signal.SIGHUP)
                except OSError:
                    pass
            self._ended(t)        # on Windows this ends the shell: there is no screen to keep it


def _children(pid: int) -> list[int]:
    try:
        out = subprocess.run(["pgrep", "-P", str(pid)], capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.TimeoutExpired):
        return []
    return [int(p) for p in out.split()]


def _parent(pid: int) -> int:
    try:
        return int(subprocess.run(["ps", "-o", "ppid=", "-p", str(pid)], capture_output=True, text=True,
                                  timeout=5).stdout.strip() or 0)
    except (OSError, subprocess.TimeoutExpired, ValueError):
        return 0


def _slug(s: str) -> str:
    return re.sub(r"[^\w.]+", "-", s).strip("-") or "shell"


def _spawn(argv: list[str], cwd: str, env: dict[str, str]) -> tuple[int, int]:
    master, slave = os.openpty()
    proc = subprocess.Popen(argv, cwd=cwd, env=env, stdin=slave, stdout=slave, stderr=slave,
                            start_new_session=True, close_fds=True,
                            preexec_fn=lambda: fcntl.ioctl(0, termios.TIOCSCTTY, 0))
    os.close(slave)
    os.set_blocking(master, False)
    return proc.pid, master


def _resize(fd: int, cols: int, rows: int) -> None:
    try:
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    except OSError:
        pass


def is_project_dir(cwd: str, root: str) -> bool:
    # normcase: Windows paths compare case-insensitively (a no-op elsewhere)
    c, r = os.path.normcase(os.path.realpath(cwd)), os.path.normcase(os.path.realpath(root))
    return c == r or c.startswith(r + os.sep)


# -- Windows (ConPTY) ----------------------------------------------------------

# Runs MARGIN_COMMAND, then stays open (-NoExit). [char]27 rather than `e so
# Windows PowerShell 5.1 shows the colours too.
PS_COMMAND = """$e = [char]27
Write-Host "$e[1m`$ $env:MARGIN_COMMAND$e[0m"
Invoke-Expression $env:MARGIN_COMMAND
$c = [int](-not $?)
if ($LASTEXITCODE) { $c = $LASTEXITCODE }
Write-Host "`n$e[2m[exit $c]$e[0m"
"""


def _windows_argv(command: str | None) -> list[str]:
    """PowerShell 7 if installed, else Windows PowerShell, else cmd."""
    ps = shutil.which("pwsh") or shutil.which("powershell")
    if ps:
        if not command:
            return [ps, "-NoLogo"]
        # -EncodedCommand: no quoting to get wrong between Python, CreateProcess and PowerShell.
        encoded = base64.b64encode(PS_COMMAND.encode("utf-16-le")).decode()
        return [ps, "-NoLogo", "-NoExit", "-EncodedCommand", encoded]
    cmd = os.environ.get("COMSPEC") or "cmd.exe"
    return [cmd, "/K", "%MARGIN_COMMAND%"] if command else [cmd]


class _WinPty:
    """pywinpty's PtyProcess with the bytes interface the rest of this file uses."""

    def __init__(self, proc: Any) -> None:
        self.proc = proc
        self.pid: int = getattr(proc, "pid", 0) or 0
        self._decode = codecs.getincrementaldecoder("utf-8")("replace")   # input may split a character

    @classmethod
    def spawn(cls, argv: list[str], cwd: str, env: dict[str, str], cols: int, rows: int) -> "_WinPty":
        from winpty import PtyProcess      # pywinpty, a Windows-only dependency
        return cls(PtyProcess.spawn(argv, cwd=cwd, env=env, dimensions=(rows, cols)))

    def read(self) -> bytes:
        """Blocks until there's output; b"" once the shell has gone."""
        try:
            while True:
                text = self.proc.read(65536)
                if text:                   # pywinpty returns "" for its own keep-alive messages
                    return text.encode("utf-8")
        except (EOFError, OSError):
            return b""

    def write(self, data: bytes) -> bool:
        text = self._decode.decode(data)
        if not text:
            return True
        try:
            self.proc.write(text)
            return True
        except (EOFError, OSError):
            return False

    def resize(self, cols: int, rows: int) -> None:
        try:
            self.proc.setwinsize(rows, cols)
        except (EOFError, OSError):
            pass

    def close(self) -> None:
        try:
            if self.proc.isalive():
                self.proc.terminate(force=True)
        except (EOFError, OSError):
            pass

