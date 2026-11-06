"""Proposals: the plans Claude presents for review (Claude Code's plan mode,
ExitPlanMode), each version kept with the reviewer's decision and feedback.

They are what the app's folio is built from: what needs a decision, what the
team is working on after approval, and what was decided. Stored per workspace
in <state>/proposals.json so they survive daemon restarts.
"""
from __future__ import annotations

import json
import logging
import time
import uuid
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any

from . import scope

log = logging.getLogger("margind.proposals")

# pending → approved → done | revise (Claude re-proposes) | superseded
STATUSES = {"pending", "approved", "revise", "superseded", "done"}
KEEP = 500


@dataclass
class Proposal:
    id: str
    session_id: str
    project: str | None
    version: int
    plan: str
    created_at: float
    status: str = "pending"
    feedback: str | None = None
    decided_at: float | None = None
    outcome: str | None = None          # Claude's final summary after carrying it out
    outcome_error: bool = False
    title: str = ""
    commands: list[str] = field(default_factory=list)   # "Commands I'll run": approved with the plan
    request_id: str | None = None       # live permission request, when the session is running

    def public(self) -> dict[str, Any]:
        d = asdict(self)
        d["live"] = self.request_id is not None
        d.pop("request_id")
        return d


def title_of(plan: str) -> str:
    for line in plan.splitlines():
        t = line.strip().lstrip("#").strip()
        if t:
            return t.removeprefix("Plan:").strip()[:120]
    return "Proposal"


@dataclass
class ProposalStore:
    path: Path
    items: dict[str, Proposal] = field(default_factory=dict)

    @classmethod
    def load(cls, path: Path) -> "ProposalStore":
        store = cls(path)
        try:
            for raw in json.loads(path.read_text()):
                p = Proposal(**raw)
                p.request_id = None            # requests don't survive a restart
                store.items[p.id] = p
        except FileNotFoundError:
            pass
        except Exception:
            # A corrupt file shouldn't stop the daemon; keep it for inspection.
            path.rename(path.with_suffix(".corrupt.json"))
        return store

    def save(self) -> None:
        """Persist; a failure is logged, never allowed to block a decision."""
        keep = sorted(self.items.values(), key=lambda p: p.created_at)[-KEEP:]
        self.items = {p.id: p for p in keep}
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            tmp = self.path.with_suffix(".tmp")
            tmp.write_text(json.dumps([asdict(p) for p in keep], indent=1))
            tmp.replace(self.path)
        except OSError:
            log.exception("couldn't save proposals to %s", self.path)

    def for_session(self, session_id: str) -> list[Proposal]:
        return sorted((p for p in self.items.values() if p.session_id == session_id), key=lambda p: p.version)

    def latest(self, session_id: str) -> Proposal | None:
        ps = self.for_session(session_id)
        return ps[-1] if ps else None

    def add(self, session_id: str, project: str | None, plan: str, request_id: str | None) -> Proposal:
        prev = self.for_session(session_id)
        for p in prev:
            if p.status == "pending":
                p.status = "superseded"
        p = Proposal(id=uuid.uuid4().hex[:12], session_id=session_id, project=project,
                     version=(prev[-1].version + 1) if prev else 1, plan=plan, created_at=time.time(),
                     title=title_of(plan), commands=scope.commands_in(plan), request_id=request_id)
        self.items[p.id] = p
        self.save()
        return p

    def decide(self, p: Proposal, status: str, feedback: str | None) -> None:
        p.status = status
        p.feedback = feedback or None
        p.decided_at = time.time()
        p.request_id = None
        self.save()

    def approved_commands(self, session_id: str) -> list[str] | None:
        """The approved command list while a session carries out its plan, else None."""
        p = self.latest(session_id)
        return p.commands if p and p.status == "approved" else None

    def finish(self, session_id: str, outcome: str, is_error: bool) -> Proposal | None:
        p = self.latest(session_id)
        if p and p.status == "approved":
            p.status = "done"
            p.outcome = outcome
            p.outcome_error = is_error
            self.save()
            return p
        return None

    def list(self, limit: int = 200) -> list[dict[str, Any]]:
        ps = sorted(self.items.values(), key=lambda p: p.decided_at or p.created_at, reverse=True)
        return [p.public() for p in ps[:limit]]
