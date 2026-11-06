"""API smoke test: REST + WebSocket against the fake SDK client."""
import os
import tempfile
import time

import pytest

fastapi = pytest.importorskip("fastapi")
from fastapi.testclient import TestClient  # noqa: E402

from margind.events import EventBus  # noqa: E402
from margind.server import create_app  # noqa: E402
from margind.sessions import SessionManager  # noqa: E402
from test_sessions import FakeClient, make_ws  # noqa: E402

H = {"Authorization": "Bearer t"}


def test_api_flow():
    with tempfile.TemporaryDirectory() as tmp:
        ws = make_ws(tmp)
        bus = EventBus()
        mgr = SessionManager(ws, bus, client_factory=FakeClient)
        with TestClient(create_app(ws, manager=mgr, bus=bus)) as c:
            assert c.get("/v1/info").status_code == 401
            info = c.get("/v1/info", headers=H).json()
            assert info["slug"] == "personal" and info["projects"][0]["name"] == "pcb"

            assert c.post("/v1/sessions", headers=H, json={"project": "nope", "prompt": "x"}).status_code == 404
            sid = c.post("/v1/sessions", headers=H, json={"project": "pcb", "prompt": "run DRC"}).json()["session_id"]

            with c.websocket_connect("/v1/events?since=0", headers=H) as sock:
                seen = []
                while True:
                    e = sock.receive_json()
                    seen.append(e["type"])
                    if e["type"] == "permission.request":
                        req = e
                        break
                assert "session.started" in seen and "session.items" in seen

                perms = c.get("/v1/permissions", headers=H).json()
                assert perms[0]["request_id"] == req["request_id"]
                rows = c.get("/v1/sessions", headers=H).json()
                assert any(r["session_id"] == sid and r["status"] == "waiting" and r["pending_permissions"] == 1 for r in rows)

                r = c.post(f"/v1/permissions/{req['request_id']}", headers=H, json={"decision": "allow"})
                assert r.json() == {"ok": True}
                while True:
                    e = sock.receive_json()
                    if e["type"] == "session.result":
                        assert e["result"].startswith("DRC clean")
                        break
            assert c.post(f"/v1/permissions/{req['request_id']}", headers=H, json={"decision": "allow"}).status_code == 404

            files = c.get("/v1/files", headers=H, params={"project": "pcb"}).json()
            assert [f["name"] for f in files] == ["sub", "board.kicad_pcb"]
            assert c.get("/v1/file", headers=H, params={"project": "pcb", "path": "board.kicad_pcb"}).text == "(kicad_pcb)"
            assert c.get("/v1/file", headers=H, params={"project": "pcb", "path": "../../etc/passwd"}).status_code == 404

            root = ws.projects[0].path
            m = c.get("/v1/media", headers=H, params={"path": os.path.join(root, "board.kicad_pcb")})
            assert m.text == "(kicad_pcb)"
            assert c.get("/v1/media", headers=H, params={"path": "board.kicad_pcb", "cwd": root}).text == "(kicad_pcb)"
            assert c.get("/v1/media", headers=H, params={"path": "board.kicad_pcb"}).status_code == 404
            assert c.get("/v1/media", headers=H, params={"path": "/etc/hosts"}).status_code == 404

            assert c.post("/v1/devices", headers=H, json={"token": "abc"}).json()["ok"]
            assert os.path.exists(os.path.join(tmp, "state", "personal", "devices.json"))

            # reconnect after a "restart" (since > current seq) gets resync
            with c.websocket_connect("/v1/events?since=99999", headers=H) as sock:
                assert sock.receive_json()["type"] == "resync"


def test_render_rejects_non_kicad_and_outside_paths():
    with tempfile.TemporaryDirectory() as tmp:
        ws = make_ws(tmp)
        with TestClient(create_app(ws, manager=SessionManager(ws, EventBus(), client_factory=FakeClient), bus=EventBus())) as c:
            root = ws.projects[0].path
            assert c.get("/v1/render", headers=H, params={"path": "/etc/hosts"}).status_code == 404
            r = c.get("/v1/render", headers=H, params={"path": "board.kicad_pcb", "cwd": root, "view": "4d"})
            assert r.status_code == 422


def test_project_markup_upload(tmp_path):
    from fastapi.testclient import TestClient
    from margind.config import Project, WorkspaceConfig
    from margind.events import EventBus
    from margind.server import create_app
    from margind.sessions import SessionManager
    ws = WorkspaceConfig(name="P", tokens=["t"], projects=[Project("p", str(tmp_path))], state_dir=str(tmp_path / "st"))
    c = TestClient(create_app(ws, SessionManager(ws, EventBus())))
    h = {"Authorization": "Bearer t"}
    r = c.post("/v1/markup?project=p", content=b"\x89PNG\r\n\x1a\nx", headers=h)
    assert r.status_code == 200 and r.json()["path"].startswith(str(tmp_path.resolve()))
    assert c.post("/v1/markup?project=p", content=b"<svg/>", headers=h).status_code == 400
    assert c.post("/v1/markup?project=nope", content=b"\x89PNG", headers=h).status_code == 404


def test_local_page_only_from_this_computer():
    with tempfile.TemporaryDirectory() as tmp:
        ws = make_ws(tmp)
        app = create_app(ws, manager=SessionManager(ws, EventBus(), client_factory=FakeClient), bus=EventBus())
        with TestClient(app) as c:                       # a remote client
            assert c.get("/").status_code == 404
            assert c.get("/local/status").status_code == 404
        with TestClient(app, base_url="http://localhost:8787", client=("127.0.0.1", 50000)) as c:
            assert "Margin" in c.get("/").text
            d = c.get("/local/status").json()
            assert d["workspace"] == "Personal" and d["sessions"] == [] and d["previews"] == []
            # A page elsewhere pointing its own hostname at 127.0.0.1 (DNS rebinding) gets nothing.
            assert c.get("/local/status", headers={"host": "evil.example:8787"}).status_code == 404


def test_ideas_are_kept_per_project_and_puts_repeat_safely(tmp_path):
    ws = make_ws(str(tmp_path))
    bus = EventBus()
    mgr = SessionManager(ws, bus, client_factory=FakeClient)
    with TestClient(create_app(ws, manager=mgr, bus=bus)) as c:
        assert c.get("/v1/ideas", headers=H).json() == {"pcb": []}
        body = {"text": "  try a ground pour on the bottom  ", "created_at": 100.0}
        a = c.put("/v1/ideas/abc-1", headers=H, params={"project": "pcb"}, json=body).json()
        c.put("/v1/ideas/abc-1", headers=H, params={"project": "pcb"}, json=body)    # sent again after reconnecting
        got = c.get("/v1/ideas", headers=H).json()["pcb"]
        assert len(got) == 1 and got[0]["text"] == a["text"] == "try a ground pour on the bottom"
        assert got[0]["created_at"] == 100.0 and got[0]["used_in"] is None

        c.put("/v1/ideas/abc-1", headers=H, params={"project": "pcb"},
              json=body | {"used_in": "sess-1", "used_at": 200.0})
        assert c.get("/v1/ideas", headers=H).json()["pcb"][0]["used_in"] == "sess-1"

        assert c.put("/v1/ideas/x", headers=H, params={"project": "nope"}, json=body).status_code == 404
        assert c.put("/v1/ideas/x", headers=H, params={"project": "pcb"}, json={"text": " "}).status_code == 400
        assert c.put("/v1/ideas/../x", headers=H, params={"project": "pcb"}, json=body).status_code in (400, 404)
        assert c.delete("/v1/ideas/abc-1", headers=H, params={"project": "pcb"}).json() == {"ok": True}
        assert c.delete("/v1/ideas/abc-1", headers=H, params={"project": "pcb"}).json() == {"ok": True}
        assert c.get("/v1/ideas", headers=H).json() == {"pcb": []}


def test_local_page_opens_a_project_only_when_asked_by_itself(monkeypatch):
    from margind import desk
    launched = []
    monkeypatch.setattr(desk, "_find", lambda: [("PyCharm", "/Applications/PyCharm.app")])
    monkeypatch.setattr(desk, "_launch", launched.append)
    with tempfile.TemporaryDirectory() as tmp:
        ws = make_ws(tmp)
        folder = ws.project("pcb").path
        app = create_app(ws, manager=SessionManager(ws, EventBus(), client_factory=FakeClient), bus=EventBus())
        page = {"X-Margin-Local": "1", "Origin": "http://localhost:8787"}
        with TestClient(app, base_url="http://localhost:8787", client=("127.0.0.1", 50000)) as c:
            assert c.get("/local/status").json()["editors"] == [{"id": "pycharm", "name": "PyCharm"}]
            r = c.post("/local/open", headers=page, json={"project": "pcb", "editor": "pycharm"})
            assert r.json() == {"ok": True, "editor": "PyCharm"}
            assert c.post("/local/open", headers=page, json={"project": "pcb", "editor": "folder"}).json() == {"ok": True}
            assert launched[0][-1] == folder and launched[1][-1] == folder
            assert c.post("/local/open", headers=page, json={"project": "pcb", "editor": "vim"}).status_code == 400
            assert c.post("/local/open", headers=page, json={"project": "/etc", "editor": "folder"}).status_code == 404
            # Another website in the browser: no custom header, or its own origin.
            assert c.post("/local/open", json={"project": "pcb", "editor": "folder"}).status_code == 403
            evil = page | {"Origin": "https://evil.example"}
            assert c.post("/local/open", headers=evil, json={"project": "pcb", "editor": "folder"}).status_code == 403
            assert len(launched) == 2
        with TestClient(app) as c:                       # from another computer
            assert c.post("/local/open", headers=page, json={"project": "pcb", "editor": "folder"}).status_code == 404
