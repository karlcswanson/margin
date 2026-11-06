"""Shells over the API: a real PTY, typed into and read back, reattached.
(POSIX shells; test_windows.py covers ConPTY.)"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

import pytest
from fastapi.testclient import TestClient

from margind.events import EventBus
from margind.server import create_app
from margind.sessions import SessionManager
from test_sessions import FakeClient, make_ws

H = {"Authorization": "Bearer t"}
posix_shell = pytest.mark.skipif(sys.platform == "win32", reason="types POSIX shell commands")


def _read_until(sock, needle: bytes, got: bytes = b"", timeout=10.0) -> bytes:
    end = time.time() + timeout
    while needle not in got:
        assert time.time() < end, f"never saw {needle!r} in {got[-400:]!r}"
        m = sock.receive()
        if m.get("bytes"):
            got += m["bytes"]
    return got


def _app(tmp, screen, ws=None):
    ws = ws or make_ws(tmp)
    ws.terminal_screen = screen
    return create_app(ws, manager=SessionManager(ws, EventBus(), client_factory=FakeClient), bus=EventBus())


@posix_shell
@pytest.mark.parametrize("screen", [False, True])
def test_shell_types_reads_and_reattaches(screen):
    if screen and not shutil.which("screen"):
        pytest.skip("screen not installed")
    with tempfile.TemporaryDirectory() as tmp, TestClient(_app(tmp, screen)) as c:
        assert c.post("/v1/terminals", json={"project": "pcb"}).status_code == 401
        t = c.post("/v1/terminals", headers=H, json={"project": "pcb"}).json()
        assert t["alive"] and t["name"].startswith("margin-pcb-") and t["screen"] == screen
        with c.websocket_connect(f"/v1/terminals/{t['id']}/stream", headers=H) as sock:
            start = sock.receive_json()
            assert start["type"] == "start"
            sock.send_text(json.dumps({"type": "resize", "cols": 120, "rows": 40}))
            sock.send_bytes(b"echo marg''in-$((6*7)); pwd; stty size\r")
            got = _read_until(sock, b"margin-42")
            got = _read_until(sock, b"40 120", got)
            offset = start["offset"] + len(got)
        assert os.path.realpath(os.path.join(tmp, "proj")).encode() in got

        # Off and back on: only what was missed comes again.
        with c.websocket_connect(f"/v1/terminals/{t['id']}/stream?since={offset}", headers=H) as sock:
            s2 = sock.receive_json()
            assert s2["reset"] is False and s2["offset"] == offset
            sock.send_bytes(b"echo again-$((2+3))\r")
            got2 = _read_until(sock, b"again-5")
            assert b"margin-42" not in got2

        listed = c.get("/v1/terminals?project=pcb", headers=H).json()
        assert [x["id"] for x in listed if x.get("id")] == [t["id"]]
        assert c.delete(f"/v1/terminals/{t['id']}", headers=H).json() == {"ok": True}
        assert c.get("/v1/terminals?project=pcb", headers=H).json() == []
        if screen:
            out = subprocess.run(["screen", "-ls"], capture_output=True, text=True).stdout
            assert t["name"] not in out


def test_shell_only_in_projects():
    with tempfile.TemporaryDirectory() as tmp, TestClient(_app(tmp, False)) as c:
        assert c.post("/v1/terminals", headers=H, json={"project": "nope"}).status_code == 404
        assert c.post("/v1/terminals", headers=H, json={"project": "pcb", "name": "../x"}).status_code == 400


@posix_shell
def test_screen_shell_outlives_the_daemon():
    """The daemon's shell manager goes away; the screen session stays, is
    listed as detached, and reattaching finds the same shell."""
    if not shutil.which("screen"):
        pytest.skip("screen not installed")
    import asyncio

    from margind.terminals import Terminals

    async def collect(sh, t, secs):
        q, out, _ = sh.subscribe(t, None)
        end = asyncio.get_running_loop().time() + secs
        while asyncio.get_running_loop().time() < end:
            try:
                out += await asyncio.wait_for(q.get(), 0.2) or b""
            except asyncio.TimeoutError:
                pass
        sh.unsubscribe(t, q)
        return out

    async def run():
        with tempfile.TemporaryDirectory() as tmp:
            ws = make_ws(tmp)
            cwd = os.path.join(tmp, "proj")
            sh = Terminals(ws)
            t = sh.open("pcb", cwd)
            try:
                await collect(sh, t, 1.5)
                sh.write(t, b"export KEPT=still-$((1+1))\r")
                await collect(sh, t, 0.5)
                sh.shutdown()
                await asyncio.sleep(1.5)        # screen notices its display is gone
                sh2 = Terminals(ws)
                assert any(x["name"] == t.name and x.get("detached") for x in sh2.list("pcb"))
                t2 = sh2.open("pcb", cwd, t.name)
                await collect(sh2, t2, 1.5)
                sh2.write(t2, b"echo $KEPT\r")
                assert b"still-2" in await collect(sh2, t2, 2)
                sh2.close(t2)
            finally:
                subprocess.run(["screen", "-S", t.name, "-X", "quit"], capture_output=True)

    asyncio.run(run())


@posix_shell
def test_screen_sessions_started_elsewhere_show_and_are_only_let_go():
    """A screen session Claude or the desk started in a project's folder is
    listed with that project's shells, attaches like one, and closing it in
    the app leaves it running."""
    if not shutil.which("screen"):
        pytest.skip("screen not installed")
    import asyncio

    from margind.terminals import Terminals

    async def run():
        with tempfile.TemporaryDirectory() as tmp:
            ws = make_ws(tmp)
            cwd = os.path.join(tmp, "proj")
            name = f"station-{os.getpid()}"
            subprocess.run(["screen", "-dmS", name, "sleep", "60"], cwd=cwd, check=True)
            try:
                sh = Terminals(ws)
                for _ in range(20):
                    if name in sh.outside_screens():
                        break
                    await asyncio.sleep(0.1)
                (item,) = [x for x in sh.list("pcb") if x["name"] == name]
                assert item["outside"] and item["detached"] and item["id"] is None
                assert not [x for x in sh.list("other") if x["name"] == name]
                with pytest.raises(ValueError):
                    sh.open("other", cwd, name)
                sleeper = int(subprocess.run(["pgrep", "-f", "sleep 60"], capture_output=True, text=True,
                                             cwd=cwd).stdout.split()[-1])
                assert sh.screen_of([sleeper]).get(sleeper) == name
                t = sh.open("pcb", cwd, name)
                assert t.outside
                await asyncio.sleep(1)
                sh.close(t)
                await asyncio.sleep(0.5)
                assert name in subprocess.run(["screen", "-ls"], capture_output=True, text=True).stdout
            finally:
                subprocess.run(["screen", "-S", name, "-X", "quit"], capture_output=True)

    asyncio.run(run())
