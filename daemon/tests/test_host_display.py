"""Margin blocks Bash commands that would show something on the host's screen."""
import asyncio

import pytest

from margind.sessions import _block_host_display


def decision(cmd):
    out = asyncio.run(_block_host_display({"tool_input": {"command": cmd}}, None, None))
    return out.get("hookSpecificOutput", {}).get("permissionDecision", "allow")


@pytest.mark.parametrize("cmd", [
    "open viewer.html",
    "python3 viewer.py && ls -la viewer.html && open viewer.html",
    "cd out; open -a 'Affinity Designer 2' logo.svg",
    "xdg-open board.pdf",
    "qlmanage -p render.png",
    "python3 -m webbrowser http://localhost:8000",
    "sudo open /Applications/Foo.app",
])
def test_blocks(cmd):
    assert decision(cmd) == "deny"


@pytest.mark.parametrize("cmd", [
    "ls -la",
    "kicad-cli pcb export svg board.kicad_pcb",
    "python3 - <<'PY'\nopen('x.txt').read()\nPY",
    "grep -rn 'open' src",
    "npm start",
    "git log --oneline",
])
def test_allows(cmd):
    assert decision(cmd) == "allow"


def test_first_prompt_gets_the_whole_note_then_reminders_and_display_reports(tmp_path):
    from margind.config import Project, WorkspaceConfig
    from margind.events import EventBus
    from margind.sessions import REMOTE_NOTE, LiveSession, SessionManager
    ws = WorkspaceConfig(name="P", tokens=["t"], projects=[Project("p", str(tmp_path))], state_dir=str(tmp_path / "st"))
    mgr = SessionManager(ws, EventBus())
    sess = LiveSession(mgr, "s", "p", str(tmp_path), resume=True, permission_mode="default")
    ctx = lambda: asyncio.run(sess._remind_remote({"prompt": "x"}, None, None))["hookSpecificOutput"]["additionalContext"]

    first = ctx()
    assert REMOTE_NOTE in first and "Markdown image" in first
    assert REMOTE_NOTE not in ctx()

    mgr.report_display("s", [{"path": "case.obj", "ok": False, "detail": "case.mtl not found"},
                             {"path": "board.kicad_pcb", "ok": True}])
    report = ctx()
    assert "FAILED: case.obj (case.mtl not found)" in report and "shown: board.kicad_pcb" in report
    assert "display report" not in ctx()          # only changes are repeated
