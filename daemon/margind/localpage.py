"""A page on this computer showing what Margin is running: open sessions,
what they're waiting on, open web previews. Only answers requests from this
machine (loopback, with a localhost Host header), so it needs no token."""
from __future__ import annotations

import asyncio
import os
import time
from typing import Any

from fastapi import HTTPException, Request

from . import desk

LOCAL_HOSTS = {"127.0.0.1", "::1"}


def require_local(request: Request) -> None:
    host = (request.headers.get("host") or "").rsplit(":", 1)[0].strip("[]")
    if (request.client is None or request.client.host not in LOCAL_HOSTS
            or host not in {"localhost", "127.0.0.1", "::1"}):
        raise HTTPException(404)


def _home(path: str) -> str:
    home = os.path.expanduser("~")
    return "~" + path[len(home):] if path == home or path.startswith(home + os.sep) else path


def require_page(request: Request) -> None:
    """Buttons that open things: only from this page. Another site open in
    the browser can't send the custom header without a CORS preflight, which
    is never granted, and its Origin wouldn't be this one."""
    origin = request.headers.get("origin")
    host = request.headers.get("host") or ""
    if request.headers.get("x-margin-local") != "1" or (origin is not None and origin != f"http://{host}"):
        raise HTTPException(403)


async def status(ws: Any, manager: Any, previews: Any, shells: Any = None, background: Any = None) -> dict[str, Any]:
    rows = await manager.list(limit=60)
    now = time.time()
    sessions = []
    for r in rows:
        live = r["session_id"] in manager.live
        if not live and r["status"] != "active_elsewhere" and now - (r.get("last_modified") or 0) > 6 * 3600:
            continue
        sid = r["session_id"]
        s = manager.settings(sid) if live else {}
        tasks = []
        if background is not None:
            since = manager.live[sid].started_at if live else None
            tasks = [t for t in await asyncio.to_thread(background.list, sid, since) if t["status"] == "running"]
        sessions.append({
            "session_id": sid, "project": r.get("project"), "title": r.get("title"),
            "status": r["status"], "live": live, "last_modified": r.get("last_modified"),
            "cwd": r.get("cwd"), "git_branch": r.get("git_branch"),
            "pending": [p.public() for p in manager.pending.values() if p.session_id == sid and p.proposal_id is None],
            "queued": len(manager.queue_of(sid)),
            "proposal": r.get("proposal"),
            "permission_mode": s.get("permission_mode"), "model": s.get("model"),
            "activity": manager.live[sid].turn if live else None,
            "tasks": [{"id": t["id"], "command": t["command"], "description": t["description"]} for t in tasks],
        })
    return {
        "workspace": ws.name, "color": ws.color, "bind": ws.bind, "port": ws.port, "now": now,
        "projects": [{"name": p.name, "path": _home(p.path)} for p in ws.projects],
        "editors": await asyncio.to_thread(desk.editors),
        "sessions": sessions,
        "previews": [p.public() | {"auth_path": None} for p in previews.items.values()],
        "shells": await asyncio.to_thread(shells.list) if shells is not None else [],
    }


PAGE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Margin sessions</title>
<style>
:root{--bg:#f6f6f4;--card:#fff;--fg:#1d1d1f;--muted:#6e6e73;--line:#e3e3e0;--accent:#3FA66B;
  --run:#2f7de1;--wait:#d98a00;--err:#d33}
@media (prefers-color-scheme: dark){:root{--bg:#161617;--card:#1f1f21;--fg:#f2f2f2;--muted:#9a9aa0;--line:#2e2e31}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.45 -apple-system,system-ui,sans-serif}
main{max-width:980px;margin:0 auto;padding:28px 16px 60px}
header{display:flex;align-items:baseline;gap:12px;flex-wrap:wrap;margin-bottom:18px}
h1{font-size:22px;margin:0;display:flex;align-items:center;gap:10px}
.dot{width:10px;height:10px;border-radius:50%;background:var(--accent);display:inline-block}
.meta{color:var(--muted);font-size:13px}
h2{font-size:13px;text-transform:uppercase;letter-spacing:.06em;color:var(--muted);margin:26px 0 8px}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:12px 14px;margin-bottom:8px}
.row{display:flex;gap:10px;align-items:center;flex-wrap:wrap}
.title{font-weight:600;flex:1;min-width:200px}
.pill{font-size:12px;padding:2px 8px;border-radius:99px;border:1px solid var(--line);color:var(--muted);white-space:nowrap}
.s-running{color:var(--run);border-color:var(--run)}
.s-waiting{color:var(--wait);border-color:var(--wait)}
.s-idle{color:var(--accent);border-color:var(--accent)}
.s-active_elsewhere{color:var(--muted)}
.sub{color:var(--muted);font-size:13px;margin-top:4px;word-break:break-all}
.pending{margin-top:8px;padding:8px 10px;border-left:3px solid var(--wait);background:color-mix(in srgb,var(--wait) 8%,transparent);border-radius:6px;font-size:13px}
code{font:12px ui-monospace,SFMono-Regular,Menlo,monospace}
.empty{color:var(--muted);padding:12px 0}
.open{display:flex;gap:6px}
select,button{font:inherit;font-size:13px;color:var(--fg);background:var(--bg);border:1px solid var(--line);border-radius:8px;padding:4px 10px;cursor:pointer}
select:hover,button:hover{border-color:var(--muted)}
.note{color:var(--muted);font-size:13px;min-height:1em}
.task{margin-top:8px;padding:8px 10px;border-left:3px solid var(--run);background:color-mix(in srgb,var(--run) 8%,transparent);border-radius:6px;font-size:13px;word-break:break-all}
</style></head>
<body><main>
<header><h1><span class="dot" id="dot"></span><span id="ws">Margin</span></h1><span class="meta" id="meta"></span></header>
<h2>Projects</h2><div id="projects"></div><div class="note" id="note"></div>
<h2>Sessions</h2><div id="sessions"><div class="empty">Loading…</div></div>
<h2>Shells</h2><div id="shells"></div>
<h2>Web previews</h2><div id="previews"></div>
</main>
<script>
const esc = s => String(s ?? "").replace(/[&<>"]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));
const ago = (t, now) => { if (!t) return ""; const s = Math.max(0, now - t);
  return s < 60 ? "just now" : s < 3600 ? Math.round(s/60) + " min ago" : s < 86400 ? Math.round(s/3600) + " h ago" : Math.round(s/86400) + " d ago"; };
const dur = s => { s = Math.max(0, Math.round(s)); return s < 60 ? s + "s" : s < 3600 ? Math.floor(s/60) + "m " + (s%60) + "s" : Math.floor(s/3600) + "h " + Math.floor(s%3600/60) + "m"; };
const tok = n => n < 1000 ? String(n) : (n/1000).toFixed(1) + "k";
const label = {running:"working", waiting:"needs you", idle:"idle", starting:"starting", active_elsewhere:"in a terminal", stored:"closed"};
const mode = {default:"ask", auto:"auto", acceptEdits:"accept edits", plan:"plan", bypassPermissions:"bypass", dontAsk:"don't ask"};
async function load() {
  let d;
  try { d = await (await fetch("/local/status", {cache:"no-store"})).json(); }
  catch (e) { document.getElementById("meta").textContent = "daemon not answering"; return; }
  document.getElementById("ws").textContent = "Margin · " + d.workspace;
  document.getElementById("dot").style.background = d.color || "";
  document.getElementById("meta").textContent = `${d.bind}:${d.port}`;
  const pj = document.getElementById("projects");
  const key = JSON.stringify([d.projects, d.editors]);
  if (pj.dataset.key !== key) {          // redrawn only when something changed, so an open menu stays open
    pj.dataset.key = key;
    pj.innerHTML = d.projects.map(p => `
      <div class="card row"><span class="title">${esc(p.name)}</span>
        <span class="sub" style="flex:2;margin:0">${esc(p.path)}</span>
        <span class="open">
          ${d.editors.length ? `<select data-project="${esc(p.name)}" aria-label="Open ${esc(p.name)} in">
            <option value="" selected disabled>Open in…</option>
            ${d.editors.map(e => `<option value="${esc(e.id)}">${esc(e.name)}</option>`).join("")}</select>` : ""}
          <button data-project="${esc(p.name)}" data-editor="folder">Folder</button>
        </span></div>`).join("");
  }
  const ss = d.sessions;
  document.getElementById("sessions").innerHTML = ss.length ? ss.map(s => `
    <div class="card"><div class="row">
      <span class="title">${esc(s.title)}</span>
      ${s.project ? `<span class="pill">${esc(s.project)}</span>` : ""}
      ${s.permission_mode ? `<span class="pill">${esc(mode[s.permission_mode] || s.permission_mode)}</span>` : ""}
      ${s.model ? `<span class="pill">${esc(s.model)}</span>` : ""}
      ${s.queued ? `<span class="pill">${s.queued} queued</span>` : ""}
      ${s.proposal && s.proposal.status === "pending" ? `<span class="pill s-waiting">plan v${s.proposal.version} to review</span>` : ""}
      <span class="pill s-${esc(s.status)}">${esc(label[s.status] || s.status)}</span>
    </div>
    <div class="sub">${esc(ago(s.last_modified, d.now))} · ${esc(s.cwd)}${s.git_branch ? " · " + esc(s.git_branch) : ""} · <code>${esc(s.session_id.slice(0,8))}</code></div>
    ${s.activity ? `<div class="task"><b>${esc(s.status === "waiting" ? "Waiting for you" : s.activity.doing)}</b> ${esc(s.activity.detail || "")}
      <span class="meta"> · ${dur(d.now - s.activity.started_at)}${s.activity.tokens ? " · ↓ " + tok(s.activity.tokens) + " tokens" : ""}</span></div>` : ""}
    ${s.tasks.map(t => `<div class="task"><b>Claude is running</b> ${esc(t.description || "a command")} <code>${esc(t.command)}</code></div>`).join("")}
    ${s.pending.map(p => `<div class="pending"><b>${esc(p.tool_name)}</b> waiting for approval${p.title ? ": " + esc(p.title) : ""}</div>`).join("")}
    </div>`).join("") : `<div class="empty">No sessions in the last six hours.</div>`;
  document.getElementById("shells").innerHTML = d.shells.length ? d.shells.map(t => `
    <div class="card row"><span class="title">${esc(t.project)} <code>${esc(t.name)}</code></span>
      <span class="pill">${t.detached ? "kept, not attached" : "attached"}</span>
      ${t.screen ? `<span class="pill">screen -x ${esc(t.name)}</span>` : ""}</div>`).join("")
    : `<div class="empty">None open.</div>`;
  document.getElementById("previews").innerHTML = d.previews.length ? d.previews.map(p => `
    <div class="card row"><span class="title">localhost:${p.target_port}</span><span class="pill">on port ${p.listen_port}</span></div>`).join("")
    : `<div class="empty">None open.</div>`;
}
async function openProject(project, editor) {
  const note = document.getElementById("note");
  try {
    const r = await fetch("/local/open", {method: "POST", headers: {"Content-Type": "application/json", "X-Margin-Local": "1"},
                                          body: JSON.stringify({project, editor})});
    const j = await r.json();
    note.textContent = r.ok ? `Opening ${project}${j.editor ? " in " + j.editor : ""}…` : (j.detail || "Couldn't open it");
  } catch (e) { note.textContent = "daemon not answering"; }
  setTimeout(() => { note.textContent = ""; }, 4000);
}
document.getElementById("projects").addEventListener("change", e => {
  const s = e.target.closest("select"); if (!s || !s.value) return;
  openProject(s.dataset.project, s.value); s.value = "";
});
document.getElementById("projects").addEventListener("click", e => {
  const b = e.target.closest("button"); if (b) openProject(b.dataset.project, b.dataset.editor);
});
load(); setInterval(load, 3000);
</script></body></html>
"""
