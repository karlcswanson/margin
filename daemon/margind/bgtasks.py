"""Claude Code's own background commands (Bash with run_in_background: dev
servers, decoders, watchers) for a session, so the app can show them next to
its shells. Nothing new for Claude: this reads what Claude Code already keeps.

- the transcript says what was started (the command and its description),
  where its output goes (a file under Claude Code's temp folder), and how it
  ended (a <task-notification> with completed / failed / killed / stopped);
- the output file is read as it grows.

Transcripts get large, so each is read once and then only what was appended.
"""
from __future__ import annotations

import json
import os
import re
import time
from datetime import datetime
from pathlib import Path
from typing import Any

TASK_ID = re.compile(r"^[a-z0-9]{6,24}$")
# Up to the first ".output" that ends a word: paths may have spaces (C:\Users\Jane Doe\...).
OUTPUT = re.compile(r"Output is being written to: (\S.*?\.output)\b")
NOTE_ID = re.compile(r"<task-id>([a-z0-9]{6,24})</task-id>")
NOTE_STATUS = re.compile(r"<status>(\w+)</status>")
NOTE_SUMMARY = re.compile(r"<summary>(.*?)</summary>", re.S)
RECENT_OUTPUT = 120          # seconds: output still growing counts as running
FIRST_READ = 256 * 1024      # how much of a long output to send at first


def config_dir() -> Path:
    return Path(os.path.expanduser(os.environ.get("CLAUDE_CONFIG_DIR") or "~/.claude"))


class _Scan:
    def __init__(self, path: Path) -> None:
        self.path = path
        self.offset = 0
        self.uses: dict[str, dict[str, Any]] = {}      # tool_use_id -> Bash input
        self.tasks: dict[str, dict[str, Any]] = {}     # task id -> what we know

    def update(self) -> None:
        try:
            size = self.path.stat().st_size
        except OSError:
            return
        if size < self.offset:                        # rewritten: start again
            self.__init__(self.path)
        if size == self.offset:
            return
        with open(self.path, "rb") as f:
            f.seek(self.offset)
            chunk = f.read(size - self.offset)
        end = chunk.rfind(b"\n") + 1                   # whole lines only; the rest next time
        self.offset += end
        for line in chunk[:end].splitlines():
            if b"run_in_background" in line or b"backgroundTaskId" in line or b"task-notification" in line:
                try:
                    self._record(json.loads(line))
                except (ValueError, AttributeError):
                    continue

    def _record(self, r: dict[str, Any]) -> None:
        content = (r.get("message") or {}).get("content")
        if isinstance(content, list):
            for b in content:
                if not isinstance(b, dict):
                    continue
                if b.get("type") == "tool_use" and b.get("name") == "Bash" and (b.get("input") or {}).get("run_in_background"):
                    self.uses[b["id"]] = b["input"]
                elif b.get("type") == "tool_result" and b.get("tool_use_id") in self.uses:
                    tid = (r.get("toolUseResult") or {}).get("backgroundTaskId") if isinstance(r.get("toolUseResult"), dict) else None
                    text = b.get("content") if isinstance(b.get("content"), str) else json.dumps(b.get("content"))
                    m = OUTPUT.search(text or "")
                    if tid and TASK_ID.match(tid) and m:
                        inp = self.uses[b["tool_use_id"]]
                        self.tasks[tid] = {"id": tid, "command": inp.get("command", ""),
                                           "description": inp.get("description") or "",
                                           "output": m.group(1), "started_at": _ts(r.get("timestamp")),
                                           "status": None, "summary": ""}
        text = r.get("content") if r.get("type") == "queue-operation" else content
        if isinstance(text, str) and "<task-notification>" in text:
            for note in text.split("<task-notification>")[1:]:
                status = NOTE_STATUS.search(note)
                summary = NOTE_SUMMARY.search(note)
                for tid in NOTE_ID.findall(note):
                    if tid in self.tasks and status:
                        self.tasks[tid]["status"] = status.group(1)
                        self.tasks[tid]["summary"] = summary.group(1).strip() if summary else ""


def _ts(s: Any) -> float:
    try:
        return datetime.fromisoformat(str(s).replace("Z", "+00:00")).timestamp()
    except ValueError:
        return time.time()


class BackgroundTasks:
    def __init__(self) -> None:
        self._scans: dict[str, _Scan] = {}

    def _scan(self, session_id: str) -> _Scan | None:
        s = self._scans.get(session_id)
        if s is None:
            found = next((p for p in (config_dir() / "projects").glob(f"*/{session_id}.jsonl")), None)
            if found is None:
                return None
            s = self._scans[session_id] = _Scan(found)
        s.update()
        return s

    def list(self, session_id: str, live_since: float | None = None,
             seen: tuple[float, dict[str, str]] | None = None) -> list[dict[str, Any]]:
        """Newest first. `live_since`: when this daemon's Claude for the session
        started; tasks it started without an ending yet are still running.
        `seen`: Claude Code's own list at the end of its last turn (when, and
        the ones still in flight), which settles any task started before it."""
        s = self._scan(session_id)
        if s is None:
            return []
        out = []
        for t in s.tasks.values():
            t = dict(t)
            path = Path(t.pop("output"))
            try:
                st = path.lstat()
                t["size"] = st.st_size
                recent = time.time() - st.st_mtime < RECENT_OUTPUT
            except OSError:
                t["size"], recent = 0, False
            if t["status"] is None and seen and t["started_at"] < seen[0]:
                t["status"] = seen[1].get(t["id"], "stopped")
                if t["status"] == "pending":
                    t["status"] = "running"
            if t["status"] is None:
                running = recent or (live_since is not None and t["started_at"] >= live_since - 5)
                t["status"] = "running" if running else "stopped"
            out.append(t)
        out.sort(key=lambda t: t["started_at"], reverse=True)
        return out

    def output(self, session_id: str, task_id: str, since: int | None) -> dict[str, Any] | None:
        """Output from byte `since` (or the last part of it), and where it ends."""
        s = self._scan(session_id)
        t = s.tasks.get(task_id) if s else None
        if t is None:
            return None
        path = Path(t["output"])
        # Only the plain output file Claude Code named for this task.
        if path.name != f"{task_id}.output" or path.is_symlink() or not path.is_file():
            return {"start": 0, "size": 0, "text": "", "reset": since is not None}
        size = path.stat().st_size
        reset = since is None or not (0 <= since <= size)
        start = max(0, size - FIRST_READ) if reset else since
        with open(path, "rb") as f:
            f.seek(start)
            data = f.read(size - start)
        for cut in range(min(3, len(data))):            # don't split a character at the end
            try:
                (data[:-cut] if cut else data).decode()
                data = data[:-cut] if cut else data
                break
            except UnicodeDecodeError:
                continue
        return {"start": start, "size": start + len(data), "text": data.decode(errors="replace"), "reset": reset}
