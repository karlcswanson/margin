import json
import time

from margind.bgtasks import BackgroundTasks


def _line(f, r):
    f.write(json.dumps(r) + "\n")


def test_reads_claude_codes_background_commands(tmp_path, monkeypatch):
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(tmp_path / "cfg"))
    sid = "11111111-2222-3333-4444-555555555555"
    proj = tmp_path / "cfg" / "projects" / "-x-proj"
    proj.mkdir(parents=True)
    out = tmp_path / "tmp" / sid / "tasks"
    out.mkdir(parents=True)
    (out / "bserve123.output").write_bytes(b"listening on 5173\n")
    (out / "bdone4567.output").write_bytes(b"ok\n")
    transcript = proj / f"{sid}.jsonl"

    def start(f, use, tid, cmd, desc):
        _line(f, {"type": "assistant", "message": {"content": [
            {"type": "tool_use", "id": use, "name": "Bash",
             "input": {"command": cmd, "description": desc, "run_in_background": True}}]}})
        _line(f, {"type": "user", "timestamp": "2026-11-01T01:00:00Z", "toolUseResult": {"backgroundTaskId": tid},
                  "message": {"content": [{"type": "tool_result", "tool_use_id": use,
                                           "content": f"Command running in background with ID: {tid}. Output is being "
                                                      f"written to: {out}/{tid}.output. You will be notified."}]}})

    with open(transcript, "w") as f:
        _line(f, {"type": "assistant", "message": {"content": [
            {"type": "tool_use", "id": "u0", "name": "Bash", "input": {"command": "ls"}}]}})
        start(f, "u1", "bserve123", "npm run dev", "Start the dev server")
        start(f, "u2", "bdone4567", "make", "Build")
        _line(f, {"type": "queue-operation", "content": "<task-notification>\n<task-id>bdone4567</task-id>\n"
                  "<status>completed</status>\n<summary>Background command \"Build\" completed (exit code 0)</summary>\n"
                  "</task-notification>"})

    b = BackgroundTasks()
    tasks = {t["id"]: t for t in b.list(sid)}
    assert set(tasks) == {"bserve123", "bdone4567"}
    assert tasks["bserve123"]["status"] == "running"          # output is fresh
    assert tasks["bserve123"]["command"] == "npm run dev" and "output" not in tasks["bserve123"]
    assert tasks["bdone4567"]["status"] == "completed" and "exit code 0" in tasks["bdone4567"]["summary"]

    o = b.output(sid, "bserve123", None)
    assert o["text"] == "listening on 5173\n" and o["reset"]
    with open(out / "bserve123.output", "ab") as f:
        f.write("ready ✓\n".encode())
    o2 = b.output(sid, "bserve123", o["size"])
    assert o2["text"] == "ready ✓\n" and not o2["reset"]
    assert b.output(sid, "nope", None) is None

    # appended later: read incrementally; old output: no longer running
    import os
    old = time.time() - 3600
    os.utime(out / "bserve123.output", (old, old))
    # Quiet output, but Claude Code said at the end of its turn that it's still running.
    assert {t["id"]: t["status"] for t in b.list(sid, seen=(time.time(), {"bserve123": "running"}))}["bserve123"] == "running"
    assert {t["id"]: t["status"] for t in b.list(sid, seen=(time.time(), {}))}["bserve123"] == "stopped"
    with open(transcript, "a") as f:
        _line(f, {"type": "user", "message": {"content": "<task-notification>\n<task-id>bserve123</task-id>\n"
                  "<status>killed</status>\n</task-notification>"}})
    assert {t["id"]: t["status"] for t in b.list(sid)}["bserve123"] == "killed"
