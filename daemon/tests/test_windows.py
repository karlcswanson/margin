"""The Windows code paths, run anywhere with the OS pieces faked: ConPTY
(pywinpty), psutil instead of lsof/ps, no ifconfig, Windows path rules.
The last test runs a real ConPTY shell, on Windows only."""
import json
import ntpath
import os
import queue
import sys
import tempfile
import time
import types
from pathlib import PureWindowsPath

import pytest
from fastapi.testclient import TestClient

from margind import bgtasks, files, gitreview, preview, render, terminals, tls
from margind.config import Project, WorkspaceConfig
from margind.events import EventBus
from margind.server import create_app
from margind.sessions import SessionManager
from test_sessions import FakeClient, make_ws

H = {"Authorization": "Bearer t"}


# -- shells over ConPTY ---------------------------------------------------------

class FakePty:
    """winpty.PtyProcess: text in and out, read blocks, EOFError at the end."""
    spawned: list["FakePty"] = []

    def __init__(self, argv, cwd, env, dimensions):
        self.argv, self.cwd, self.env, self.size = argv, cwd, env, dimensions
        self.pid = 4242
        self.alive = True
        self.written: list[str] = []
        self.out: queue.Queue = queue.Queue()
        self.out.put("")                                # pywinpty's keep-alive: not the end
        self.out.put("PS> ")

    @classmethod
    def spawn(cls, argv, cwd=None, env=None, dimensions=(24, 80)):
        p = cls(argv, cwd, env, dimensions)
        cls.spawned.append(p)
        return p

    def read(self, size=1024):
        item = self.out.get()
        if item is None:
            raise EOFError("Pty is closed")
        return item

    def write(self, s):
        self.written.append(s)
        self.out.put(f"echo:{s}")
        return len(s)

    def setwinsize(self, rows, cols):
        self.size = (rows, cols)

    def isalive(self):
        return self.alive

    def terminate(self, force=False):
        self.alive = False
        self.out.put(None)
        return True

    def exit(self):                                     # the shell ends by itself
        self.alive = False
        self.out.put(None)


@pytest.fixture
def windows_shells(monkeypatch):
    FakePty.spawned = []
    monkeypatch.setitem(sys.modules, "winpty", types.SimpleNamespace(PtyProcess=FakePty))
    monkeypatch.setattr(terminals, "WINDOWS", True)
    monkeypatch.setattr(terminals, "shutil", types.SimpleNamespace(
        which=lambda name: {"pwsh": r"C:\Program Files\PowerShell\7\pwsh.exe", "screen": "/usr/bin/screen"}.get(name)))
    return FakePty


def _read_until(sock, needle: bytes, timeout=5.0) -> bytes:
    got, end = b"", time.time() + timeout
    while needle not in got:
        assert time.time() < end, f"never saw {needle!r} in {got!r}"
        m = sock.receive()
        got += m.get("bytes") or b""
    return got


def test_conpty_shell_streams_like_a_pty(windows_shells):
    with tempfile.TemporaryDirectory() as tmp:
        ws = make_ws(tmp)
        app = create_app(ws, manager=SessionManager(ws, EventBus(), client_factory=FakeClient), bus=EventBus())
        with TestClient(app) as c:
            t = c.post("/v1/terminals", headers=H, json={"project": "pcb"}).json()
            assert t["alive"] and t["screen"] is False             # no screen on Windows, even if one is on PATH
            pty = windows_shells.spawned[0]
            assert pty.argv == [r"C:\Program Files\PowerShell\7\pwsh.exe", "-NoLogo"]
            assert pty.cwd == os.path.join(tmp, "proj") and pty.size == (30, 100)
            assert pty.env["MARGIN_SHELL"] == "1" and "MARGIN_COMMAND" not in pty.env

            with c.websocket_connect(f"/v1/terminals/{t['id']}/stream", headers=H) as sock:
                start = sock.receive_json()
                assert start["type"] == "start" and start["screen"] is False
                got = _read_until(sock, b"PS> ")
                sock.send_text(json.dumps({"type": "resize", "cols": 120, "rows": 40}))
                sock.send_bytes("caf\xe9".encode()[:-1])          # a character split across two messages
                sock.send_bytes("caf\xe9".encode()[-1:])
                got += _read_until(sock, "echo:\xe9".encode())
                offset = start["offset"] + len(got)
            assert pty.size == (40, 120)
            assert pty.written == ["caf", "\xe9"]

            # reattach: only what was missed
            pty.out.put("later")
            with c.websocket_connect(f"/v1/terminals/{t['id']}/stream?since={offset}", headers=H) as sock:
                s2 = sock.receive_json()
                assert s2["reset"] is False
                assert _read_until(sock, b"later") == b"later"

            assert [x["id"] for x in c.get("/v1/terminals", headers=H).json()] == [t["id"]]
            assert c.delete(f"/v1/terminals/{t['id']}", headers=H).json() == {"ok": True}
            assert not pty.alive
            assert c.get("/v1/terminals", headers=H).json() == []


def test_conpty_shell_that_exits_tells_the_app(windows_shells):
    with tempfile.TemporaryDirectory() as tmp:
        ws = make_ws(tmp)
        app = create_app(ws, manager=SessionManager(ws, EventBus(), client_factory=FakeClient), bus=EventBus())
        with TestClient(app) as c:
            t = c.post("/v1/terminals", headers=H, json={"project": "pcb"}).json()
            with c.websocket_connect(f"/v1/terminals/{t['id']}/stream", headers=H) as sock:
                sock.receive_json()
                _read_until(sock, b"PS> ")
                windows_shells.spawned[0].exit()
                while (m := sock.receive()).get("text") is None:
                    pass
                assert json.loads(m["text"]) == {"type": "exit"}
            assert c.get("/v1/terminals", headers=H).json() == []


def test_shells_end_with_the_daemon_on_windows(windows_shells):
    with tempfile.TemporaryDirectory() as tmp:
        ws = make_ws(tmp)
        app = create_app(ws, manager=SessionManager(ws, EventBus(), client_factory=FakeClient), bus=EventBus())
        with TestClient(app) as c:
            c.post("/v1/terminals", headers=H, json={"project": "pcb"})
        assert not windows_shells.spawned[0].alive


def test_button_command_runs_in_powershell(windows_shells):
    import asyncio

    async def run():
        with tempfile.TemporaryDirectory() as tmp:
            sh = terminals.Terminals(make_ws(tmp))
            t = sh.open("pcb", os.path.join(tmp, "proj"), command="npm test")
            pty = windows_shells.spawned[0]
            assert pty.env["MARGIN_COMMAND"] == "npm test"
            ps, *args = pty.argv
            assert args[:3] == ["-NoLogo", "-NoExit", "-EncodedCommand"]
            import base64
            assert base64.b64decode(args[3]).decode("utf-16-le") == terminals.PS_COMMAND
            sh.close(t)

    asyncio.run(run())


def test_windows_shell_choice(monkeypatch):
    which = {}
    monkeypatch.setattr(terminals, "shutil", types.SimpleNamespace(which=lambda name: which.get(name)))
    monkeypatch.setenv("COMSPEC", r"C:\Windows\system32\cmd.exe")
    assert terminals._windows_argv(None) == [r"C:\Windows\system32\cmd.exe"]
    assert terminals._windows_argv("make") == [r"C:\Windows\system32\cmd.exe", "/K", "%MARGIN_COMMAND%"]
    which["powershell"] = r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
    assert terminals._windows_argv(None) == [which["powershell"], "-NoLogo"]
    which["pwsh"] = r"C:\Program Files\PowerShell\7\pwsh.exe"
    assert terminals._windows_argv(None)[0] == which["pwsh"]


# -- dev servers from psutil ------------------------------------------------------

def _fake_psutil(conns, procs, me="PC\\alex"):
    """procs: pid -> (ppid, cmdline list, cwd, user)."""
    class Error(Exception):
        pass

    class AccessDenied(Error):
        pass

    class Process:
        def __init__(self, pid):
            if pid not in procs:
                raise Error(pid)
            self.pid = pid
            self.info = {"ppid": procs[pid][0], "cmdline": procs[pid][1]}

        def username(self):
            if procs[self.pid][3] is None:
                raise AccessDenied(self.pid)
            return procs[self.pid][3]

        def cwd(self):
            return procs[self.pid][2]

        def name(self):
            return ntpath.basename(procs[self.pid][1][0])

    addr = types.SimpleNamespace
    return types.SimpleNamespace(
        Error=Error, CONN_LISTEN="LISTEN", Process=Process,
        net_connections=lambda kind: [addr(status=s, pid=pid, laddr=addr(ip=ip, port=port))
                                      for s, pid, ip, port in conns],
        process_iter=lambda attrs: [Process(pid) for pid in procs])


def _windows_os(monkeypatch, module):
    """`module` sees Windows path rules (and no real path lookups); nothing else does."""
    path = types.SimpleNamespace(realpath=lambda p: p, expanduser=lambda p: p, normcase=ntpath.normcase,
                                 dirname=ntpath.dirname, basename=ntpath.basename, join=ntpath.join)
    monkeypatch.setattr(module, "os", types.SimpleNamespace(path=path, sep="\\", environ=os.environ, getpid=os.getpid))


def test_listening_on_windows_uses_psutil(monkeypatch, tmp_path):
    proj, home = r"C:\Users\alex\code\web", r"C:\Users\alex"
    sid = "d2e5aaa2-7376-412b-8e78-91b42c93f389"
    me = "PC\\alex"
    procs = {
        os.getpid(): (1, ["python"], home, me),
        10: (1, [r"C:\Users\alex\.local\bin\claude.exe", "--output-format", "stream-json", "--resume", sid], proj, me),
        11: (10, ["bash", "-c", "source snap.sh && eval 'npm run dev' < /dev/null"], proj, me),
        12: (11, [r"C:\Program Files\nodejs\node.exe", "vite"], proj, me),
        20: (1, [r"C:\Windows\System32\svchost.exe"], r"C:\Windows\System32", me),
        30: (1, [r"C:\other\node.exe"], home, None),            # another user's: no access
        40: (1, [r"C:\tools\python.exe", "-m", "http.server"], home, me),
    }
    conns = [("LISTEN", 12, "::", 5173), ("LISTEN", 12, "0.0.0.0", 5173),
             ("LISTEN", 20, "0.0.0.0", 135), ("LISTEN", 30, "127.0.0.1", 3000),
             ("LISTEN", 40, "127.0.0.1", 8000), ("LISTEN", 40, "192.168.1.5", 8001),   # not a local address
             ("ESTABLISHED", 40, "127.0.0.1", 50000), ("LISTEN", 40, "127.0.0.1", 8787)]  # the daemon's port
    monkeypatch.setattr(preview, "WINDOWS", True)
    monkeypatch.setattr(preview, "_psutil", lambda: _fake_psutil(conns, procs))
    monkeypatch.setenv("SystemRoot", r"C:\Windows")
    _windows_os(monkeypatch, preview)
    monkeypatch.setattr(preview, "subprocess", None)                     # no lsof or ps
    ws = WorkspaceConfig(name="P", tokens=["t"], projects=[Project("web", proj.upper())],   # any case
                         state_dir=str(tmp_path / "st"))
    items = preview.listening(ws)
    assert [(i["port"], i["project"], i["command"]) for i in items] == [(5173, "web", "node"), (8000, None, "python")]
    assert items[0]["claude_session"] == sid and items[0]["claude_command"] == "npm run dev"


def test_listening_without_psutil_is_empty(monkeypatch, tmp_path):
    monkeypatch.setattr(preview, "WINDOWS", True)
    monkeypatch.setattr(preview, "_psutil", lambda: None)
    ws = WorkspaceConfig(name="P", tokens=["t"], projects=[], state_dir=str(tmp_path))
    assert preview.listening(ws) == []
    assert preview._cwd_of(1) is None and preview._processes() == {}


def test_windows_folder_rules(monkeypatch):
    monkeypatch.setattr(preview, "WINDOWS", True)
    _windows_os(monkeypatch, preview)
    monkeypatch.setenv("SystemRoot", r"C:\Windows")
    assert preview._inside(r"c:\Code\Web\src", r"C:\code\web")                # case-insensitive
    assert not preview._inside(r"C:\code\website", r"C:\code\web")
    assert preview._not_a_folder("C:\\") and preview._not_a_folder(r"C:\WINDOWS\system32")
    monkeypatch.setenv("ProgramFiles", r"C:\Program Files")
    assert preview._not_a_folder(r"C:\Program Files\Microsoft VS Code")
    assert not preview._not_a_folder(r"C:\code\web")


# -- certificate addresses without ifconfig ---------------------------------------

def test_tls_addresses_on_windows(monkeypatch, tmp_path):
    import socket
    nic = types.SimpleNamespace
    fake = types.SimpleNamespace(net_if_addrs=lambda: {
        "Ethernet": [nic(family=socket.AF_INET, address="192.168.1.20"), nic(family=-1, address="aa:bb")],
        "ZeroTier": [nic(family=socket.AF_INET, address="10.147.17.3")],
        "Public": [nic(family=socket.AF_INET, address="8.8.4.4")]})
    monkeypatch.setitem(sys.modules, "psutil", fake)
    monkeypatch.setattr(tls, "WINDOWS", True)
    monkeypatch.setattr(tls.subprocess, "run", lambda *a, **k: pytest.fail("ran ifconfig on Windows"))
    ws = WorkspaceConfig(name="P", tokens=["t"], state_dir=str(tmp_path))
    _, ips = tls.local_names(ws)
    assert {"192.168.1.20", "10.147.17.3", "127.0.0.1"} <= set(ips) and "8.8.4.4" not in ips

    monkeypatch.setitem(sys.modules, "psutil", None)                      # not installed: the host name's addresses
    monkeypatch.setattr(tls.socket, "getaddrinfo", lambda host, port, family: [(family, 1, 6, "", ("192.168.7.7", 0))])
    assert "192.168.7.7" in tls.local_names(ws)[1]


def test_computer_name_on_windows(monkeypatch):
    from margind import server
    monkeypatch.setattr(sys, "platform", "win32")
    monkeypatch.setattr(server.subprocess, "run", lambda *a, **k: pytest.fail("ran scutil on Windows"))
    monkeypatch.setenv("COMPUTERNAME", "WORKSTATION")
    assert server._computer_name() == "WORKSTATION"
    monkeypatch.delenv("COMPUTERNAME")
    assert server._computer_name() == server.socket.gethostname()


# -- programs found in Windows places ---------------------------------------------

def test_newest_kicad_first(monkeypatch):
    monkeypatch.setattr(render, "WINDOWS", True)
    monkeypatch.setenv("ProgramFiles", r"C:\Program Files")
    found = [r"C:\Program Files\KiCad\9.0\bin\kicad-cli.exe", r"C:\Program Files\KiCad\10.0\bin\kicad-cli.exe",
             r"C:\Program Files\KiCad\8.0\bin\kicad-cli.exe"]
    monkeypatch.setattr(render, "glob", types.SimpleNamespace(glob=lambda pattern: list(found)))
    _windows_os(monkeypatch, render)
    assert render._windows_kicads() == [found[1], found[0], found[2]]
    monkeypatch.setattr(render, "WINDOWS", False)
    assert render._windows_kicads() == []


# -- Windows path rules ------------------------------------------------------------

def test_env_files_by_any_ntfs_name(monkeypatch):
    other_names = (".ENV", ".env ", ".env::$DATA", ".Env.Local")
    monkeypatch.setattr(files, "WINDOWS", False)
    assert not any(files._env_file(n) for n in other_names)               # other files elsewhere
    monkeypatch.setattr(files, "WINDOWS", True)
    for name in (".env", ".env.local", ".env.", *other_names):
        assert files._env_file(name), name
    assert not files._env_file(".envrc") and not files._env_file("env.md")


def test_no_drive_letters_or_network_paths(monkeypatch, tmp_path):
    (tmp_path / "a.txt").write_text("a")
    ws = WorkspaceConfig(name="P", tokens=["t"], projects=[Project("p", str(tmp_path))], state_dir=str(tmp_path / "st"))
    monkeypatch.setattr(files, "WINDOWS", True)
    for rel in ("C:/Windows/win.ini", "c:secret.txt"):
        with pytest.raises(files.PathError):
            files.resolve(ws, "p", rel)
    assert files.resolve(ws, "p", "\\/a.txt").name == "a.txt"
    assert files._other_share(PureWindowsPath(r"\\evil.example\share\x.png"), ws)
    assert files._other_share(PureWindowsPath(r"//evil.example/share/x.png"), ws)
    assert not files._other_share(PureWindowsPath(r"C:\code\x.png"), ws)
    ws.projects.append(Project("nas", r"\\NAS\Projects\board"))
    monkeypatch.setattr(files, "Path", _WinPath)
    assert not files._other_share(PureWindowsPath(r"\\nas\projects\board\x.png"), ws)


class _WinPath(PureWindowsPath):
    def expanduser(self):
        return self


def test_git_paths_on_windows(monkeypatch):
    monkeypatch.setattr(gitreview, "WINDOWS", True)
    for bad in ("..\\x", "a\\..\\..\\x", "\\Windows\\x", "/etc/x", "C:x", "C:\\x", "\\\\server\\share\\x"):
        assert gitreview._outside(bad), bad
    for ok in ("src\\app.py", "src/app.py", "a..b.txt"):
        assert not gitreview._outside(ok), ok


def test_background_output_path_with_spaces():
    text = (r"Command running in background with ID: b1. Output is being written to: "
            r"C:\Users\Jane Doe\AppData\Local\Temp\claude\tasks\b1.output. You will be notified.")
    assert bgtasks.OUTPUT.search(text).group(1) == r"C:\Users\Jane Doe\AppData\Local\Temp\claude\tasks\b1.output"


# -- the real thing ------------------------------------------------------------------

@pytest.mark.skipif(sys.platform != "win32", reason="ConPTY is Windows only")
def test_real_conpty_shell():
    with tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as tmp:
        ws = make_ws(tmp)
        app = create_app(ws, manager=SessionManager(ws, EventBus(), client_factory=FakeClient), bus=EventBus())
        with TestClient(app) as c:
            t = c.post("/v1/terminals", headers=H, json={"project": "pcb"}).json()
            with c.websocket_connect(f"/v1/terminals/{t['id']}/stream", headers=H) as sock:
                sock.receive_json()
                sock.send_bytes(b"Write-Output ('marg' + 'in-' + 6*7)\r")
                _read_until(sock, b"margin-42", timeout=30)
            assert c.delete(f"/v1/terminals/{t['id']}", headers=H).json() == {"ok": True}
