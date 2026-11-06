"""Git state for code review in the app: what changed (working tree, or
against a branch/commit) as a unified diff, plus refs to compare against."""
from __future__ import annotations

import asyncio
import difflib
import ntpath
import os
import re
import sys

MAX_DIFF = 3_000_000
MAX_UNTRACKED = 200_000
WINDOWS = sys.platform == "win32"


class GitError(Exception):
    pass


async def _git(cwd: str, *args: str) -> str:
    proc = await asyncio.create_subprocess_exec(
        "git", "-c", "core.quotepath=off", *args, cwd=cwd,
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    out, err = await asyncio.wait_for(proc.communicate(), 60)
    if proc.returncode != 0:
        raise GitError(err.decode(errors="replace").strip() or f"git {args[0]} failed")
    return out.decode(errors="replace")


def _outside(path: str) -> bool:
    """Absolute, or climbing out with "..". On Windows also "..\\", "\\x" and "C:x"."""
    if WINDOWS:
        return bool(ntpath.splitdrive(path)[0]) or path.startswith(("/", "\\")) or ".." in re.split(r"[/\\]", path)
    return os.path.isabs(path) or ".." in path.split("/")


async def refs(cwd: str) -> dict:
    try:
        branch = (await _git(cwd, "rev-parse", "--abbrev-ref", "HEAD")).strip()
    except GitError as e:
        raise GitError("not a git repository") if "not a git" in str(e).lower() else e
    branches = [b.strip() for b in (await _git(cwd, "branch", "--format=%(refname:short)")).splitlines() if b.strip()]
    log = []
    try:
        for line in (await _git(cwd, "log", "-30", "--format=%h%x09%s%x09%cr")).splitlines():
            h, s, when = (line.split("\t") + ["", ""])[:3]
            log.append({"sha": h, "subject": s, "when": when})
    except GitError:
        pass                        # no commits yet
    return {"branch": branch, "branches": branches, "commits": log}


async def diff(cwd: str, base: str | None = None, path: str | None = None) -> dict:
    """`base` empty → uncommitted changes (vs HEAD, untracked files included);
    otherwise everything that differs from that ref, including uncommitted work.
    `path` limits it to one file (relative to `cwd`)."""
    if path and (path.startswith("-") or _outside(path)):
        raise GitError("bad path")
    only = ["--", path] if path else []
    has_head = True
    try:
        await _git(cwd, "rev-parse", "--verify", "HEAD")
    except GitError:
        has_head = False
    if base and base.startswith("-"):
        raise GitError("bad ref")
    target = base or ("HEAD" if has_head else None)
    text = await _git(cwd, "diff", "--no-color", "-M", target, *only) if target else ""
    # untracked files appear as additions
    if not base:
        for path in (await _git(cwd, "ls-files", "--others", "--exclude-standard", *only)).splitlines():
            full = os.path.join(cwd, path)
            try:
                if os.path.getsize(full) > MAX_UNTRACKED:
                    continue
                with open(full, encoding="utf-8") as f:
                    lines = f.read().splitlines(keepends=True)
            except (OSError, UnicodeDecodeError):
                continue
            body = "".join(difflib.unified_diff([], lines, "/dev/null", f"b/{path}"))
            text += f"diff --git a/{path} b/{path}\nnew file mode 100644\n" + body + ("" if body.endswith("\n") else "\n")
    truncated = len(text) > MAX_DIFF
    return {"base": base or "", "diff": text[:MAX_DIFF], "truncated": truncated}


async def show(cwd: str, path: str, ref: str = "HEAD") -> bytes:
    """A file as it was at `ref` (path relative to `cwd`)."""
    if ref.startswith("-") or path.startswith("-") or _outside(path):
        raise GitError("bad ref or path")
    proc = await asyncio.create_subprocess_exec(
        "git", "show", f"{ref}:./{path}", cwd=cwd,
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    out, err = await asyncio.wait_for(proc.communicate(), 60)
    if proc.returncode != 0:
        raise GitError(err.decode(errors="replace").strip() or "not in that commit")
    return out
