"""HTTP + WebSocket API for one workspace. See docs/protocol.md."""
from __future__ import annotations

import asyncio
import hashlib
import hmac
import json
import logging
import os
import socket
import subprocess
import sys
import uuid
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any

from fastapi import Depends, FastAPI, HTTPException, Query, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse, HTMLResponse, Response
from pydantic import BaseModel

from . import __version__, actions, bgtasks, desk, ideas, files, gitreview, localpage, preview, render, step, terminals, tls, writing
from .config import WorkspaceConfig
from .events import EventBus
from .push import DeviceStore
from .sessions import SessionManager, save_markup_in

log = logging.getLogger("margind.server")


class StartBody(BaseModel):
    project: str
    prompt: str
    permission_mode: str | None = None


class SendBody(BaseModel):
    text: str
    permission_mode: str | None = None


class RunActionBody(BaseModel):
    project: str
    label: str
    fingerprint: str              # the version the user saw and confirmed
    session_id: str | None = None


class TerminalBody(BaseModel):
    project: str | None = None
    session_id: str | None = None    # start in that chat's folder
    name: str | None = None          # reattach to this screen session


class SettingsBody(BaseModel):
    permission_mode: str | None = None
    model: str | None = None        # "" = the workspace default
    effort: str | None = None       # "" = the model's default


class PermissionBody(BaseModel):
    decision: str  # allow | deny
    message: str | None = None
    always: bool = False


class AssistBody(BaseModel):
    project: str
    passage: str
    instruction: str
    context: str | None = None
    path: str | None = None


class PreviewBody(BaseModel):
    port: int


class DisplayItem(BaseModel):
    path: str
    ok: bool
    detail: str | None = None


class DisplayBody(BaseModel):
    items: list[DisplayItem]


class IdeaBody(BaseModel):
    text: str
    created_at: float | None = None
    used_in: str | None = None       # the chat it went into
    used_at: float | None = None


class OpenBody(BaseModel):
    project: str
    editor: str                       # an id from the page's list, or "folder"


class ProposalBody(BaseModel):
    decision: str            # approve | revise
    feedback: str | None = None


class DeviceBody(BaseModel):
    token: str
    name: str | None = None
    environment: str = "development"  # development | production


def create_app(ws: WorkspaceConfig, manager: SessionManager | None = None,
               bus: EventBus | None = None) -> FastAPI:
    bus = bus or EventBus()
    boot = uuid.uuid4().hex   # changes on every daemon start; the app resets its event counter
    machine = ws.machine or _computer_name()
    devices = DeviceStore(ws)
    if manager is None:
        notifier = None
        if ws.apns:
            from .push import ApnsPusher
            notifier = ApnsPusher(ws, devices)
        manager = SessionManager(ws, bus, notifier=notifier)

    @asynccontextmanager
    async def lifespan(_app: FastAPI):
        yield
        await previews.shutdown()
        shells.shutdown()
        await manager.shutdown()

    certs: tls.Certs | None = None
    if ws.preview_tls:
        try:
            certs = tls.ensure(ws)
        except Exception:
            log.exception("HTTPS for previews unavailable; serving them over HTTP")
    previews = preview.PreviewProxy(ws, tls=certs.server_context() if certs else None)

    app = FastAPI(title=f"margind · {ws.name}", version=__version__, lifespan=lifespan)
    app.state.ws, app.state.bus, app.state.manager = ws, bus, manager
    app.state.assistant = writing.claude_revise      # replaced in tests

    def _check(token: str | None) -> None:
        if not token or not any(hmac.compare_digest(token, t) for t in ws.tokens):
            raise HTTPException(401, "bad token")

    def auth(request: Request) -> None:
        h = request.headers.get("authorization", "")
        _check(h[7:] if h.lower().startswith("bearer ") else None)

    # ---- on this computer: what's running ------------------------------
    @app.get("/", dependencies=[Depends(localpage.require_local)], include_in_schema=False)
    async def local_page() -> HTMLResponse:
        return HTMLResponse(localpage.PAGE)

    @app.get("/local/status", dependencies=[Depends(localpage.require_local)], include_in_schema=False)
    async def local_status() -> dict[str, Any]:
        return await localpage.status(ws, manager, previews, shells, background)

    @app.post("/local/open", dependencies=[Depends(localpage.require_local), Depends(localpage.require_page)],
              include_in_schema=False)
    async def local_open(body: OpenBody) -> dict[str, Any]:
        try:
            folder = ws.project(body.project).path
        except KeyError:
            raise HTTPException(404, "unknown project")
        try:
            if body.editor == "folder":
                await asyncio.to_thread(desk.open_folder, folder)
                return {"ok": True}
            return {"ok": True, "editor": await asyncio.to_thread(desk.open_in, body.editor, folder)}
        except desk.DeskError as e:
            raise HTTPException(400, str(e))

    shells = terminals.Terminals(ws)

    # ---- the daemon's CA (public; install it on the iPad for HTTPS previews) ----
    @app.get("/v1/tls/ca.pem")
    async def ca_pem() -> Response:
        if certs is None:
            raise HTTPException(404, "HTTPS is off (preview_tls)")
        return Response(certs.ca_pem, media_type="application/x-pem-file")

    @app.get("/v1/tls/margin.mobileconfig")
    async def ca_profile() -> Response:
        if certs is None:
            raise HTTPException(404, "HTTPS is off (preview_tls)")
        return Response(tls.mobileconfig(certs, ws), media_type="application/x-apple-aspen-config",
                        headers={"Content-Disposition": f'attachment; filename="margin-{ws.slug}.mobileconfig"'})

    # ---- info ---------------------------------------------------------
    @app.get("/v1/info", dependencies=[Depends(auth)])
    async def info() -> dict[str, Any]:
        return {
            "workspace": ws.name, "slug": ws.slug, "color": ws.color,
            "host": socket.gethostname(), "machine": machine, "version": __version__,
            "projects": [{"name": p.name, "path": p.path} for p in ws.projects],
            "default_permission_mode": ws.default_permission_mode,
            "push": ws.apns is not None, "seq": bus.seq, "boot": boot,
            "renders": render.kicad_cli(ws) is not None,
            "step": await asyncio.to_thread(step.cad_python, ws) is not None,
            "tls": {"ca_sha256": certs.ca_sha256} if certs else None,
        }

    # ---- sessions -----------------------------------------------------
    @app.get("/v1/sessions", dependencies=[Depends(auth)])
    async def sessions(project: str | None = None, limit: int = 50) -> list[dict[str, Any]]:
        try:
            return await manager.list(project, limit)
        except KeyError:
            raise HTTPException(404, "unknown project")

    @app.post("/v1/sessions", dependencies=[Depends(auth)])
    async def start(body: StartBody) -> dict[str, str]:
        try:
            sid = await manager.start(body.project, body.prompt, body.permission_mode)
        except KeyError:
            raise HTTPException(404, "unknown project")
        except ValueError as e:
            raise HTTPException(400, str(e))
        return {"session_id": sid}

    @app.get("/v1/sessions/{session_id}/messages", dependencies=[Depends(auth)])
    async def messages(session_id: str) -> dict[str, Any]:
        items = await manager.history(session_id)
        live = manager.live.get(session_id)
        return {"session_id": session_id, "items": items, "queued": manager.queue_of(session_id),
                "shows": manager.shows.get(session_id, []), "replies": manager.replies.get(session_id, []),
                "crons": manager.crons.get(session_id, []), "activity": live.turn if live else None,
                "status": live.status if live else "stored", "seq": bus.seq}

    @app.post("/v1/sessions/{session_id}/messages", dependencies=[Depends(auth)])
    async def send(session_id: str, body: SendBody) -> dict[str, bool]:
        try:
            await manager.send(session_id, body.text, body.permission_mode)
        except KeyError:
            raise HTTPException(404, "unknown session")
        return {"ok": True}

    @app.get("/v1/sessions/{session_id}/settings", dependencies=[Depends(auth)])
    async def get_settings(session_id: str) -> dict[str, Any]:
        manager.want_models(session_id)
        return manager.settings(session_id)

    @app.patch("/v1/sessions/{session_id}/settings", dependencies=[Depends(auth)])
    async def set_settings(session_id: str, body: SettingsBody) -> dict[str, Any]:
        try:
            return await manager.update_settings(session_id, body.permission_mode, body.model, body.effort)
        except ValueError as e:
            raise HTTPException(400, str(e))

    @app.delete("/v1/sessions/{session_id}/show", dependencies=[Depends(auth)])
    async def shown(session_id: str, id: str | None = None) -> dict[str, bool]:
        # The user opened it (or put it aside); without an id, all of them.
        manager.remove_show(session_id, id)
        return {"ok": True}

    @app.delete("/v1/sessions/{session_id}/queue/{queue_id}", dependencies=[Depends(auth)])
    async def cancel_queued(session_id: str, queue_id: str) -> dict[str, bool]:
        try:
            manager.cancel_queued(session_id, queue_id)
        except KeyError:
            raise HTTPException(404, "already sent")
        return {"ok": True}

    @app.post("/v1/sessions/{session_id}/display", dependencies=[Depends(auth)])
    async def display(session_id: str, body: DisplayBody) -> dict[str, bool]:
        manager.report_display(session_id, [i.model_dump() for i in body.items])
        return {"ok": True}

    @app.post("/v1/sessions/{session_id}/interrupt", dependencies=[Depends(auth)])
    async def interrupt(session_id: str) -> dict[str, bool]:
        await manager.interrupt(session_id)
        return {"ok": True}

    @app.post("/v1/sessions/{session_id}/close", dependencies=[Depends(auth)])
    async def close(session_id: str) -> dict[str, bool]:
        await manager.close(session_id)
        return {"ok": True}

    # ---- approvals ----------------------------------------------------
    @app.get("/v1/permissions", dependencies=[Depends(auth)])
    async def permissions() -> list[dict[str, Any]]:
        return manager.pending_list()

    @app.post("/v1/permissions/{request_id}", dependencies=[Depends(auth)])
    async def decide(request_id: str, body: PermissionBody) -> dict[str, bool]:
        try:
            manager.resolve_permission(request_id, body.decision, body.message, body.always)
        except KeyError:
            raise HTTPException(404, "no such request (already answered?)")
        except ValueError as e:
            raise HTTPException(400, str(e))
        return {"ok": True}

    # ---- proposals (the folio) -----------------------------------------
    @app.get("/v1/proposals", dependencies=[Depends(auth)])
    async def proposals(limit: int = 200) -> list[dict[str, Any]]:
        return manager.proposals.list(limit)

    @app.post("/v1/proposals/{proposal_id}", dependencies=[Depends(auth)])
    async def decide_proposal(proposal_id: str, body: ProposalBody) -> dict[str, Any]:
        try:
            return await manager.decide_proposal(proposal_id, body.decision, body.feedback)
        except KeyError:
            raise HTTPException(404, "no such proposal")
        except ValueError as e:
            raise HTTPException(409, str(e))

    @app.post("/v1/sessions/{session_id}/markup", dependencies=[Depends(auth)])
    async def markup(session_id: str, request: Request) -> dict[str, str]:
        data = await request.body()
        if len(data) > 25_000_000:
            raise HTTPException(413, "markup image too large")
        if session_id not in manager._cwd_cache:
            await manager._find_cwd(session_id)
        try:
            return {"path": manager.save_markup(session_id, data)}
        except KeyError:
            raise HTTPException(404, "unknown session")
        except ValueError as e:
            raise HTTPException(400, str(e))

    @app.post("/v1/markup", dependencies=[Depends(auth)])
    async def project_markup(project: str, request: Request) -> dict[str, str]:
        """A markup made outside a session (e.g. on a code review), stored in the project."""
        data = await request.body()
        if len(data) > 25_000_000:
            raise HTTPException(413, "markup image too large")
        try:
            return {"path": save_markup_in(ws.project(project).path, data)}
        except KeyError:
            raise HTTPException(404, "unknown project")
        except ValueError as e:
            raise HTTPException(400, str(e))

    # ---- web previews -------------------------------------------------
    @app.get("/v1/previews/servers", dependencies=[Depends(auth)])
    async def preview_servers() -> list[dict[str, Any]]:
        """Servers listening on this machine (dev servers to preview). Ones
        Claude started in the background say which chat, and its description."""
        def _list() -> list[dict[str, Any]]:
            items = preview.listening(ws)
            in_screen = shells.screen_of([int(it["pid"]) for it in items if it.get("pid")])
            for it in items:     # a server kept in a screen session: its output is in the Shell tab
                if name := in_screen.get(int(it.get("pid") or 0)):
                    it["screen"] = name
            tasks: dict[str, list[dict[str, Any]]] = {}
            for it in items:
                sid = it.get("claude_session")
                if not sid:
                    continue
                if sid not in tasks:
                    tasks[sid] = background.list(sid, _live_since(sid), manager.claude_tasks.get(sid),
                                                  manager.task_states.get(sid))
                cmd = str(it.get("claude_command") or "").strip()
                t = next((t for t in tasks[sid] if t["command"].strip() == cmd), None)
                if t:
                    it["claude_task"] = t["id"]
                    it["claude_description"] = t["description"]
            return items
        return await asyncio.to_thread(_list)

    @app.post("/v1/previews", dependencies=[Depends(auth)])
    async def open_preview(body: PreviewBody) -> dict[str, Any]:
        try:
            return (await previews.open(body.port)).public()
        except preview.PreviewError as e:
            raise HTTPException(400, str(e))

    @app.delete("/v1/previews/{port}", dependencies=[Depends(auth)])
    async def close_preview(port: int) -> dict[str, bool]:
        await previews.close(port)
        return {"ok": True}

    # ---- files --------------------------------------------------------
    @app.get("/v1/files", dependencies=[Depends(auth)])
    async def list_files(project: str, path: str = "") -> list[dict[str, Any]]:
        try:
            return await asyncio.to_thread(files.listing, ws, project, path)
        except (files.PathError, KeyError, FileNotFoundError) as e:
            raise HTTPException(404, str(e))

    @app.get("/v1/file", dependencies=[Depends(auth)])
    async def get_file(project: str, path: str) -> FileResponse:
        try:
            p = files.resolve(ws, project, path)
        except (files.PathError, KeyError) as e:
            raise HTTPException(404, str(e))
        if not p.is_file():
            raise HTTPException(404, "not a file")
        return FileResponse(p, media_type=files.media_type(p), headers={
            "X-Modified": repr(p.stat().st_mtime), "Cache-Control": "no-cache"})

    @app.put("/v1/file", dependencies=[Depends(auth)])
    async def put_file(project: str, path: str, request: Request, base_modified: float | None = None,
                       create_only: bool = False) -> dict[str, Any]:
        """Save a file edited in the app (creates it if new)."""
        try:
            p = files.resolve(ws, project, path)
        except (files.PathError, KeyError) as e:
            raise HTTPException(404, str(e))
        try:
            modified = writing.save(p, await request.body(), base_modified, create_only)
        except writing.Conflict as e:
            raise HTTPException(409, str(e))
        except ValueError as e:
            raise HTTPException(400, str(e))
        return {"ok": True, "modified": modified}

    @app.post("/v1/assist", dependencies=[Depends(auth)])
    async def assist(body: AssistBody) -> dict[str, str]:
        """Revise a passage of a document; returns the replacement text."""
        try:
            cwd = ws.project(body.project).path
        except KeyError:
            raise HTTPException(404, "unknown project")
        try:
            text = await writing.revise(ws, cwd, body.passage, body.instruction, body.context or "",
                                        body.path, assistant=app.state.assistant)
        except asyncio.TimeoutError:
            raise HTTPException(504, "Claude took too long")
        return {"text": text}

    # ---- git (code review) -----------------------------------------------
    @app.get("/v1/git/refs", dependencies=[Depends(auth)])
    async def git_refs(project: str) -> dict[str, Any]:
        try:
            return await gitreview.refs(ws.project(project).path)
        except KeyError:
            raise HTTPException(404, "unknown project")
        except gitreview.GitError as e:
            raise HTTPException(422, str(e))

    @app.get("/v1/git/diff", dependencies=[Depends(auth)])
    async def git_diff(project: str, base: str | None = None, path: str | None = None) -> dict[str, Any]:
        try:
            return await gitreview.diff(ws.project(project).path, base or None, path or None)
        except KeyError:
            raise HTTPException(404, "unknown project")
        except gitreview.GitError as e:
            raise HTTPException(422, str(e))

    @app.get("/v1/git/file", dependencies=[Depends(auth)])
    async def git_file(project: str, path: str, ref: str = "HEAD") -> Response:
        """A project file as it was at `ref`, for before/after views."""
        try:
            files.resolve(ws, project, path)          # same rules as reading it now (.env etc.)
            data = await gitreview.show(ws.project(project).path, path, ref)
        except (files.PathError, KeyError) as e:
            raise HTTPException(404, str(e))
        except gitreview.GitError as e:
            raise HTTPException(404, str(e))
        return Response(data, media_type=files.media_type(Path(path)))

    @app.get("/v1/resolve", dependencies=[Depends(auth)])
    async def resolve_path(path: str, cwd: str | None = None) -> dict[str, str]:
        """Where a path Claude mentioned really is: {project, path}, the way the
        media and render endpoints find it (relative to the session folder,
        the project root, or a subfolder the shell had moved into)."""
        try:
            p = files.resolve_any(ws, path, cwd)
        except files.PathError as e:
            raise HTTPException(404, str(e))
        if not p.is_file():
            raise HTTPException(404, "not a file")
        for proj in ws.projects:
            root = Path(proj.path).expanduser().resolve()
            if root in p.parents:
                return {"project": proj.name, "path": p.relative_to(root).as_posix()}
        raise HTTPException(404, "outside the projects")

    @app.get("/v1/media", dependencies=[Depends(auth)])
    async def get_media(path: str, cwd: str | None = None) -> FileResponse:
        try:
            p = files.resolve_any(ws, path, cwd)
        except files.PathError as e:
            raise HTTPException(404, str(e))
        if not p.is_file():
            raise HTTPException(404, "not a file")
        return FileResponse(p, media_type=files.media_type(p), headers={"Cache-Control": "no-cache"})

    @app.get("/v1/render", dependencies=[Depends(auth)])
    async def get_render(path: str, cwd: str | None = None, view: str = "2d",
                         ref: str | None = None) -> FileResponse:
        """A KiCad schematic as PDF, a board as SVG ("2d") or a 3D PNG ("3d");
        a STEP model as margin-parts JSON ("parts", also the default). With
        `ref`, the file as it was at that commit."""
        try:
            p = files.resolve_any(ws, path, cwd)
        except files.PathError as e:
            raise HTTPException(404, str(e))
        if ref:
            p = await _at_ref(p, ref)
        elif not p.is_file():
            raise HTTPException(404, "not a file")
        try:
            if step.handles(p):
                out = await step.convert(ws, p, "parts" if view == "2d" else view)
            else:
                out = await render.render(ws, p, view)
        except render.RenderError as e:
            raise HTTPException(422, str(e))
        return FileResponse(out, media_type=files.media_type(out))

    async def _at_ref(p: Path, ref: str) -> Path:
        """An old version written out under the state folder, to render."""
        for proj in ws.projects:
            root = Path(proj.path).expanduser().resolve()
            if root in p.parents:
                try:
                    data = await gitreview.show(str(root), p.relative_to(root).as_posix(), ref)
                except gitreview.GitError as e:
                    raise HTTPException(404, str(e))
                d = ws.state_path / "renders" / "git" / hashlib.sha1(data).hexdigest()[:16]
                d.mkdir(parents=True, exist_ok=True)
                out = d / p.name
                if not out.is_file():
                    out.write_bytes(data)
                return out
        raise HTTPException(404, "not in a project")

    # ---- devices (push) ----------------------------------------------
    @app.post("/v1/devices", dependencies=[Depends(auth)])
    async def register(body: DeviceBody) -> dict[str, bool]:
        devices.add(body.token, body.name, body.environment)
        return {"ok": True, "push_enabled": ws.apns is not None}

    # ---- events -------------------------------------------------------
    # ---- Claude Code's own background commands in a session ---------------
    background = bgtasks.BackgroundTasks()

    def _live_since(session_id: str) -> float | None:
        sess = manager.live.get(session_id)
        return sess.started_at if sess else None

    @app.get("/v1/sessions/{session_id}/tasks", dependencies=[Depends(auth)])
    async def background_tasks(session_id: str) -> list[dict[str, Any]]:
        return await asyncio.to_thread(background.list, session_id, _live_since(session_id),
                                       manager.claude_tasks.get(session_id), manager.task_states.get(session_id))

    @app.post("/v1/sessions/{session_id}/tasks/{task_id}/stop", dependencies=[Depends(auth)])
    async def stop_background_task(session_id: str, task_id: str) -> dict[str, bool]:
        try:
            await manager.stop_task(session_id, task_id)
        except KeyError:
            raise HTTPException(409, "Claude isn't running in this chat")
        return {"ok": True}

    @app.get("/v1/sessions/{session_id}/tasks/{task_id}/output", dependencies=[Depends(auth)])
    async def background_output(session_id: str, task_id: str, since: int | None = None) -> dict[str, Any]:
        out = await asyncio.to_thread(background.output, session_id, task_id, since)
        if out is None:
            raise HTTPException(404, "no such task")
        return out

    # ---- pages Claude published for a project --------------------------
    @app.get("/v1/published", dependencies=[Depends(auth)])
    async def published(project: str) -> list[dict[str, Any]]:
        try:
            ws.project(project)
        except KeyError:
            raise HTTPException(404, "unknown project")
        return await asyncio.to_thread(manager.published.list, project)

    @app.delete("/v1/published", dependencies=[Depends(auth)])
    async def unpublish(project: str, id: str) -> dict[str, bool]:
        if not manager.published.remove(project, id):
            raise HTTPException(404, "not published")
        manager.publish_pages(project)
        return {"ok": True}

    # ---- buttons Claude set up for a project ------------------------------
    @app.get("/v1/actions", dependencies=[Depends(auth)])
    async def list_actions(project: str) -> list[dict[str, Any]]:
        try:
            return actions.load(ws.project(project).path)
        except KeyError:
            raise HTTPException(404, "unknown project")

    @app.delete("/v1/actions", dependencies=[Depends(auth)])
    async def delete_action(project: str, label: str) -> dict[str, bool]:
        try:
            root = ws.project(project).path
        except KeyError:
            raise HTTPException(404, "unknown project")
        if not actions.remove_action(root, label):
            raise HTTPException(404, "no such button")
        manager.publish_actions(project)
        return {"ok": True}

    # ---- ideas saved for a project, used in a chat later -------------------
    @app.get("/v1/ideas", dependencies=[Depends(auth)])
    async def list_ideas() -> dict[str, list[dict[str, Any]]]:
        return {p.name: ideas.load(p.path) for p in ws.projects}

    @app.put("/v1/ideas/{idea_id}", dependencies=[Depends(auth)])
    async def put_idea(idea_id: str, project: str, body: IdeaBody) -> dict[str, Any]:
        try:
            root = ws.project(project).path
        except KeyError:
            raise HTTPException(404, "unknown project")
        try:
            idea = ideas.put(root, idea_id, body.text, created_at=body.created_at,
                             used_in=body.used_in, used_at=body.used_at)
        except ideas.IdeaError as e:
            raise HTTPException(400, str(e))
        manager.publish_ideas(project)
        return idea

    @app.delete("/v1/ideas/{idea_id}", dependencies=[Depends(auth)])
    async def delete_idea(idea_id: str, project: str) -> dict[str, bool]:
        try:
            root = ws.project(project).path
        except KeyError:
            raise HTTPException(404, "unknown project")
        if ideas.remove(root, idea_id):           # already gone is fine: it may be a retry
            manager.publish_ideas(project)
        return {"ok": True}

    @app.post("/v1/actions/run", dependencies=[Depends(auth)])
    async def run_action(body: RunActionBody) -> dict[str, Any]:
        try:
            root = ws.project(body.project).path
        except KeyError:
            raise HTTPException(404, "unknown project")
        a = next((x for x in actions.load(root) if x["label"].lower() == body.label.lower()), None)
        if a is None:
            raise HTTPException(404, "no such button")
        if a["fingerprint"] != body.fingerprint:
            raise HTTPException(409, "the button changed; look at it again")
        if a["kind"] == "run":
            cwd = os.path.realpath(os.path.join(root, a.get("cwd") or ""))
            t = shells.open(body.project, cwd, command=a["command"])
            return {"kind": "run", "terminal": t.public()}
        if a["kind"] == "prompt":
            if not body.session_id:
                raise HTTPException(400, "which chat?")
            try:
                await manager.send(body.session_id, a["prompt"])
            except KeyError:
                raise HTTPException(404, "unknown session")
            return {"kind": "prompt"}
        return {"kind": "open", "url": a["url"]}

    # ---- shells ---------------------------------------------------------
    @app.get("/v1/terminals", dependencies=[Depends(auth)])
    async def list_terminals(project: str | None = None) -> list[dict[str, Any]]:
        return await asyncio.to_thread(shells.list, project)

    @app.post("/v1/terminals", dependencies=[Depends(auth)])
    async def open_terminal(body: TerminalBody) -> dict[str, Any]:
        cwd = None
        if body.session_id:
            cwd = await manager._find_cwd(body.session_id)
        project = body.project or (ws.project_for_cwd(cwd) if cwd else None)
        try:
            proj = ws.project(project or "")
        except KeyError:
            raise HTTPException(404, "unknown project")
        if not cwd or not terminals.is_project_dir(cwd, proj.path):
            cwd = proj.path
        try:
            return shells.open(proj.name, cwd, body.name).public()
        except ValueError as e:
            raise HTTPException(400, str(e))

    @app.delete("/v1/terminals/{terminal_id}", dependencies=[Depends(auth)])
    async def close_terminal(terminal_id: str, name: str | None = None) -> dict[str, bool]:
        if t := shells.items.get(terminal_id):
            shells.close(t)
        elif name:
            shells.quit_detached(name)
        else:
            raise HTTPException(404, "no such shell")
        return {"ok": True}

    @app.websocket("/v1/terminals/{terminal_id}/stream")
    async def terminal_stream(sock: WebSocket, terminal_id: str, since: int | None = Query(None),
                              token: str | None = Query(None)) -> None:
        h = sock.headers.get("authorization", "")
        try:
            _check(h[7:] if h.lower().startswith("bearer ") else token)
        except HTTPException:
            await sock.close(code=4401)
            return
        t = shells.items.get(terminal_id)
        if t is None or not t.alive:
            await sock.close(code=4404)
            return
        await sock.accept()
        q, missed, reset = shells.subscribe(t, since)
        # Offsets count every byte the shell ever wrote; the app sends back the
        # last one it has when it reconnects.
        await sock.send_json({"type": "start", "offset": t.offset - len(missed), "reset": reset,
                              "name": t.name, "screen": t.screen})
        if missed:
            await sock.send_bytes(missed)

        async def pump_out() -> None:
            while (data := await q.get()) is not None:
                while not q.empty():                    # coalesce bursts
                    more = q.get_nowait()
                    if more is None:
                        await sock.send_bytes(data)
                        data = None
                        break
                    data += more
                if data is None:
                    break
                await sock.send_bytes(data)
            await sock.send_json({"type": "exit"})
            await sock.close()

        out = asyncio.create_task(pump_out())
        try:
            while True:
                msg = await sock.receive()
                if msg["type"] == "websocket.disconnect":
                    break
                if (b := msg.get("bytes")) is not None:
                    shells.write(t, b)
                elif (txt := msg.get("text")) is not None:
                    try:
                        m = json.loads(txt)
                    except ValueError:
                        continue
                    if m.get("type") == "input":
                        shells.write(t, str(m.get("data", "")).encode())
                    elif m.get("type") == "resize":
                        shells.resize(t, int(m.get("cols", 80)), int(m.get("rows", 24)))
        except (WebSocketDisconnect, RuntimeError):
            pass
        finally:
            shells.unsubscribe(t, q)
            out.cancel()

    @app.websocket("/v1/events")
    async def events(sock: WebSocket, since: int = Query(0), token: str | None = Query(None)) -> None:
        h = sock.headers.get("authorization", "")
        try:
            _check(h[7:] if h.lower().startswith("bearer ") else token)
        except HTTPException:
            await sock.close(code=4401)
            return
        await sock.accept()
        q = bus.subscribe()
        try:
            missed = bus.replay(since)
            if since > bus.seq or (since and missed and missed[0]["seq"] > since + 1):
                # daemon restarted or buffer overflowed: tell the app to refetch
                await sock.send_json({"type": "resync", "seq": bus.seq})
            for e in missed:
                await sock.send_json(e)
            while True:
                try:
                    e = await asyncio.wait_for(q.get(), timeout=25)
                    await sock.send_json(e)
                except asyncio.TimeoutError:
                    await sock.send_json({"type": "ping", "seq": bus.seq})
        except (WebSocketDisconnect, RuntimeError):
            pass
        finally:
            bus.unsubscribe(q)

    return app


def _computer_name() -> str:
    """The Mac's name as Finder shows it ("Alex's MacBook Pro"); the host name elsewhere."""
    if sys.platform == "win32":
        return os.environ.get("COMPUTERNAME") or socket.gethostname()
    try:
        out = subprocess.run(["scutil", "--get", "ComputerName"], capture_output=True, text=True, timeout=2)
        if out.returncode == 0 and out.stdout.strip():
            return out.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        pass
    return socket.gethostname().removesuffix(".local")
