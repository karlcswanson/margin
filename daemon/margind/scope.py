"""What an approved proposal lets Claude run without asking.

A proposal lists its shell commands under a "Commands I'll run" heading.
Approving the proposal approves those commands (plus a few read-only ones)
while the plan is carried out; anything else still comes to the reviewer.
"""
from __future__ import annotations

import fnmatch
import re

_HEADING = re.compile(r"^(#{1,4})\s+(.*)$")
_TICKS = re.compile(r"`([^`]+)`")
_SPLIT = re.compile(r"\s*(?:&&|\|\||;|\||\n)\s*")
# Things a scoped command may not contain: substitutions, writes to files, backgrounding.
_UNSAFE = re.compile(r"\$\(|`|<\(|(?<![0-9&])>(?!\s*/dev/null)|(?<![&|>])&(?![&>])")

# Read-only commands that never need asking while carrying out an approved plan.
SAFE = [
    "ls", "ls *", "pwd", "cat *", "head *", "tail *", "wc *", "grep *", "rg *", "tree", "tree *",
    "stat *", "file *", "du *", "which *", "echo", "echo *", "sort *", "uniq *", "cut *", "diff *",
    "git status", "git status *", "git diff", "git diff *", "git log", "git log *", "git show *",
    "git branch", "git branch --show-current", "git rev-parse *",
]
_SAFE_REJECT = re.compile(r"\s-(?:exec|delete|fprint|ok)\b|\bsed\s+-i")


def commands_in(plan: str) -> list[str]:
    """Commands listed under a heading that mentions commands, from fenced
    blocks or `backticked` bullets."""
    out: list[str] = []
    lines = plan.splitlines()
    i = 0
    while i < len(lines):
        m = _HEADING.match(lines[i].strip())
        if m and "command" in m.group(2).lower():
            level = len(m.group(1))
            i += 1
            fence = False
            while i < len(lines):
                line = lines[i]
                h = _HEADING.match(line.strip())
                if not fence and h and len(h.group(1)) <= level:
                    break
                t = line.strip()
                if t.startswith("```") or t.startswith("~~~"):
                    fence = not fence
                elif fence:
                    _add(out, t)
                elif t[:1] in "-*+" or t[:2].rstrip(".").isdigit():
                    for c in _TICKS.findall(t):
                        _add(out, c)
                i += 1
            continue
        i += 1
    return out


def _add(out: list[str], cmd: str) -> None:
    cmd = cmd.strip()
    if cmd.startswith("$ "):
        cmd = cmd[2:]
    if not cmd or cmd.startswith("#"):
        return
    # "cd x && make test" approves "make test": steps are matched one by one.
    for part in _parts(cmd):
        if part not in out:
            out.append(part)


def _parts(command: str) -> list[str]:
    out = []
    for part in _SPLIT.split(command.strip()):
        part = re.sub(r"\s*2>&1$", "", " ".join(part.split()))
        if part and part != "cd" and not part.startswith("cd "):
            out.append(part)
    return out


def _relative(part: str, cwd: str | None) -> str:
    """Paths inside the project compare the same written either way."""
    if not cwd:
        return part
    root = cwd.rstrip("/")
    return part.replace(root + "/", "").replace(root, ".")


def allows(command: str, approved: list[str], cwd: str | None = None) -> bool:
    """True when every part of `command` is an approved or read-only command.
    `cd somewhere` steps are fine; substitutions and file writes never are."""
    if not command.strip() or _UNSAFE.search(command):
        return False
    patterns = [_relative(p, cwd) for p in approved]
    for part in _parts(command):
        part = _relative(part, cwd)
        if any(_match(part, p) for p in patterns):
            continue
        if not _SAFE_REJECT.search(part) and any(_match(part, p) for p in SAFE):
            continue
        return False
    return True


def _match(part: str, pattern: str) -> bool:
    pattern = " ".join(pattern.split())
    if any(ch in pattern for ch in "*?["):
        return fnmatch.fnmatchcase(part, pattern)
    # A listed command also covers extra arguments ("pytest -q" covers "pytest -q tests/x.py").
    return part == pattern or part.startswith(pattern + " ")
