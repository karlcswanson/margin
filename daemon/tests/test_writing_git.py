"""Saving edited files, passage revisions, and git diffs for review."""
import os
import subprocess
import tempfile

import pytest

pytest.importorskip("fastapi")
from fastapi.testclient import TestClient  # noqa: E402

from margind.server import create_app  # noqa: E402
from test_sessions import make_ws  # noqa: E402

H = {"Authorization": "Bearer t"}


def test_save_create_and_conflict():
    with tempfile.TemporaryDirectory() as tmp:
        ws = make_ws(tmp)
        with TestClient(create_app(ws)) as c:
            r = c.put("/v1/file", headers=H, params={"project": "pcb", "path": "posts/hello.md"}, content=b"# Hi\n")
            assert r.status_code == 200
            got = c.get("/v1/file", headers=H, params={"project": "pcb", "path": "posts/hello.md"})
            mtime = float(got.headers["x-modified"])
            ok = c.put("/v1/file", headers=H, params={"project": "pcb", "path": "posts/hello.md",
                                                       "base_modified": mtime}, content=b"# Hi again\n")
            assert ok.status_code == 200
            stale = c.put("/v1/file", headers=H, params={"project": "pcb", "path": "posts/hello.md",
                                                          "base_modified": mtime - 100}, content=b"x")
            assert stale.status_code == 409
            assert c.put("/v1/file", headers=H, params={"project": "pcb", "path": "posts/hello.md",
                                                         "create_only": True}, content=b"x").status_code == 409
            assert c.put("/v1/file", headers=H, params={"project": "pcb", "path": "../escape.md"},
                         content=b"x").status_code == 404
            assert c.put("/v1/file", headers=H, params={"project": "pcb", "path": ".env"},
                         content=b"x").status_code == 404


def test_assist_returns_unwrapped_revision():
    with tempfile.TemporaryDirectory() as tmp:
        ws = make_ws(tmp)
        app = create_app(ws)
        seen = {}

        async def fake(ws_, cwd, prompt):
            seen["prompt"] = prompt
            return "```markdown\nA tighter sentence.\n```"
        app.state.assistant = fake
        with TestClient(app) as c:
            r = c.post("/v1/assist", headers=H, json={"project": "pcb", "passage": "A very long winded sentence.",
                                                      "instruction": "Tighten", "path": "posts/a.md"})
            assert r.json() == {"text": "A tighter sentence."}
            assert "Tighten" in seen["prompt"] and "posts/a.md" in seen["prompt"]


def test_git_diff_working_tree_and_refs():
    with tempfile.TemporaryDirectory() as tmp:
        ws = make_ws(tmp)
        root = ws.projects[0].path
        run = lambda *a: subprocess.run(["git", *a], cwd=root, check=True, capture_output=True)
        run("init", "-q", "-b", "main")
        run("-c", "user.email=a@b", "-c", "user.name=a", "add", "board.kicad_pcb")
        run("-c", "user.email=a@b", "-c", "user.name=a", "commit", "-qm", "first")
        open(os.path.join(root, "board.kicad_pcb"), "w").write("(kicad_pcb v2)")
        open(os.path.join(root, "notes.md"), "w").write("new file\n")
        with TestClient(create_app(ws)) as c:
            refs = c.get("/v1/git/refs", headers=H, params={"project": "pcb"}).json()
            assert refs["branch"] == "main" and refs["commits"][0]["subject"] == "first"
            d = c.get("/v1/git/diff", headers=H, params={"project": "pcb"}).json()["diff"]
            assert "+(kicad_pcb v2)" in d and "b/notes.md" in d and "+new file" in d
            assert c.get("/v1/git/diff", headers=H, params={"project": "pcb", "base": "--output=x"}).status_code == 422


def test_one_files_diff_and_its_last_committed_version(tmp_path):
    import subprocess
    from fastapi.testclient import TestClient
    from margind.config import Project, WorkspaceConfig
    from margind.events import EventBus
    from margind.server import create_app
    from margind.sessions import SessionManager
    run = lambda *a: subprocess.run(a, cwd=tmp_path, check=True, capture_output=True)
    run("git", "init", "-q"); run("git", "config", "user.email", "t@t"); run("git", "config", "user.name", "t")
    # bytes: no CRLF on Windows, whatever git's autocrlf says
    (tmp_path / "a.txt").write_bytes(b"one\n"); (tmp_path / "b.txt").write_bytes(b"x\n")
    run("git", "add", "."); run("git", "commit", "-qm", "init")
    (tmp_path / "a.txt").write_bytes(b"two\n"); (tmp_path / "b.txt").write_bytes(b"y\n")
    ws = WorkspaceConfig(name="P", tokens=["t"], projects=[Project("p", str(tmp_path))], state_dir=str(tmp_path / ".st"))
    c = TestClient(create_app(ws, SessionManager(ws, EventBus())))
    h = {"Authorization": "Bearer t"}
    d = c.get("/v1/git/diff?project=p&path=a.txt", headers=h).json()["diff"]
    assert "-one" in d and "+two" in d and "b.txt" not in d
    assert c.get("/v1/git/file?project=p&path=a.txt", headers=h).content == b"one\n"
    assert c.get("/v1/git/file?project=p&path=nope.txt", headers=h).status_code == 404
    assert c.get("/v1/git/file?project=p&path=../x", headers=h).status_code == 404
