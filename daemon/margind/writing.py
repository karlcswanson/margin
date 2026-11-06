"""Writing support: save files edited in the app, and one-shot "revise this
passage" requests that return replacement text (no session, no tools)."""
from __future__ import annotations

import asyncio
import os
from pathlib import Path
from typing import Any, Awaitable, Callable

from claude_agent_sdk import AssistantMessage, ClaudeAgentOptions, TextBlock, query

from .config import WorkspaceConfig

MAX_FILE = 5_000_000

EDITOR_PROMPT = """\
You are an editor working on a document the user is writing. You get the
passage to revise, some surrounding context, and the user's instruction.
Put the revised passage, ready to replace the original, between <revised>
and </revised>. Write nothing outside the tags. Keep the author's voice and
the Markdown formatting unless asked otherwise."""


class Conflict(Exception):
    pass


def save(path: Path, data: bytes, base_modified: float | None, create_only: bool = False) -> float:
    """Write `data` atomically. If the file exists and `base_modified` is given,
    refuse when it changed on the host since the app loaded it; `create_only`
    refuses to replace an existing file."""
    if len(data) > MAX_FILE:
        raise ValueError("file too large")
    if create_only and path.exists():
        raise Conflict(f"{path.name} already exists")
    if path.exists():
        if not path.is_file():
            raise ValueError("not a file")
        if base_modified is not None and abs(path.stat().st_mtime - base_modified) > 0.001:
            raise Conflict("the file changed on the host since you opened it")
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.margin-tmp")
    tmp.write_bytes(data)
    if path.exists():
        os.chmod(tmp, path.stat().st_mode)
    tmp.replace(path)
    return path.stat().st_mtime


Assistant = Callable[[WorkspaceConfig, str, str], Awaitable[str]]


async def claude_revise(ws: WorkspaceConfig, cwd: str, prompt: str) -> str:
    opts = ClaudeAgentOptions(cwd=cwd, system_prompt=EDITOR_PROMPT, allowed_tools=[], max_turns=1,
                              setting_sources=[], env=ws.sdk_env(), model=ws.model)
    parts: list[str] = []
    async for msg in query(prompt=prompt, options=opts):
        if isinstance(msg, AssistantMessage):
            parts += [b.text for b in msg.content if isinstance(b, TextBlock)]
    return "".join(parts)


async def revise(ws: WorkspaceConfig, cwd: str, passage: str, instruction: str, context: str = "",
                 path: str | None = None, assistant: Assistant = claude_revise) -> str:
    prompt = (
        (f"Document: {path}\n\n" if path else "")
        + (f"Context around the passage:\n<context>\n{context[-6000:]}\n</context>\n\n" if context else "")
        + f"Passage to revise:\n<passage>\n{passage}\n</passage>\n\n"
        + f"Instruction: {instruction}"
    )
    text = await asyncio.wait_for(assistant(ws, cwd, prompt), timeout=180)
    return _unwrap(text.strip("\n"))


def _unwrap(text: str) -> str:
    t = text.strip()
    for tag in ("revised", "passage"):
        start, end = t.find(f"<{tag}>"), t.rfind(f"</{tag}>")
        if start != -1 and end > start:
            return t[start + len(tag) + 2:end].strip("\n")
    if t.startswith("```") and t.endswith("```") and t.count("```") == 2:
        return t.split("\n", 1)[1].rsplit("```", 1)[0].rstrip("\n")
    return text


def describe(path: Path) -> dict[str, Any]:
    return {"modified": path.stat().st_mtime, "size": path.stat().st_size}
