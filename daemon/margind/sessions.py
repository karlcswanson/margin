"""Session manager: runs Claude Code sessions through the Agent SDK and turns
everything they do into events on the bus.

Sessions are ordinary Claude Code sessions stored under the workspace's
CLAUDE_CONFIG_DIR (default ~/.claude), so the same sessions show up in
`claude --resume` at the desk, and CLAUDE.md / memory / settings / MCP
servers / skills all load exactly as they do in the terminal.
"""
from __future__ import annotations

import asyncio
import json
import logging
import os
import re
import time
import uuid
from dataclasses import dataclass
from typing import Any, Awaitable, Callable

from claude_agent_sdk import (
    AssistantMessage,
    ClaudeAgentOptions,
    ClaudeSDKClient,
    HookMatcher,
    PermissionResultAllow,
    PermissionResultDeny,
    PermissionUpdate,
    ResultMessage,
    SystemMessage,
    TaskNotificationMessage,
    TaskStartedMessage,
    TaskUpdatedMessage,
    TextBlock,
    ThinkingBlock,
    ToolPermissionContext,
    ToolUseBlock,
    create_sdk_mcp_server,
    tool,
)
from claude_agent_sdk import get_session_info, get_session_messages, list_sessions

from . import normalize, scope
from .proposals import ProposalStore
from . import actions, crons, ideas
from .published import PublishedStore, PublishError, parse_local_url
from .config import WorkspaceConfig
from .events import EventBus

log = logging.getLogger("margind.sessions")
INTERRUPTED = "The user interrupted (Esc). Stop and wait for their next instruction."
UNANSWERED = ("You offered replies under the conversation, but they don't carry your answer and the user can't "
              "see one. If they asked you something you haven't answered in text, answer it now. If you have, "
              "or you only asked them a question, end your turn without writing anything more.")
APPROVAL_PUSH_AFTER = 15.0   # seconds: push an approval Claude Code hasn't raised a notification for by then

ClientFactory = Callable[[ClaudeAgentOptions], Any]
Notifier = Callable[[dict[str, Any]], Awaitable[None]]

# Margin's own tools for Claude: nothing to approve, they only change what the app shows.
MARGIN_TOOLS = ["mcp__margin__publish_page", "mcp__margin__unpublish_page",
                "mcp__margin__set_action", "mcp__margin__remove_action", "mcp__margin__show", "mcp__margin__suggest_replies"]

PERMISSION_MODES = {"default", "acceptEdits", "plan", "bypassPermissions", "dontAsk", "auto"}
EFFORTS = {"low", "medium", "high", "xhigh", "max"}
# A transcript written to this recently by someone else is probably open at the desk.
ACTIVE_ELSEWHERE_SECONDS = 20

# Appended to the Claude Code system prompt for sessions run through Margin.
REMOTE_NOTE = """\
# Margin
The user is driving this session remotely from the Margin app on an iPad, not
sitting at this computer. Nothing shown on this machine's screen reaches them.
- Never open files, apps or browser tabs on this machine (`open`, `xdg-open`,
  `qlmanage -p`, `webbrowser`, browser-automation tools). The user can't see them,
  and Margin blocks those commands.
- Margin shows these files inline in the chat, with tap-to-enlarge:
  images (PNG, JPG, GIF, WebP, SVG), PDFs, KiCad schematics and boards
  (.kicad_sch, .kicad_pcb, rendered as PDF / 2D layers / 3D), and 3D models:
  STEP/STP (converted by Margin, keeps per-part colours and transparency),
  USDZ (UsdPreviewSurface colours, opacity and textures), OBJ (+ its .mtl
  colours and textures, kept next to it), STL and PLY (geometry only, shown
  grey). Multi-part models (STEP assemblies, USDZ/OBJ with several objects)
  can be hidden part by part and exploded on the iPad, so one assembly file
  beats separate exploded exports. Prefer STEP or USDZ for coloured mockups.
  To show one, reference it as a Markdown image, e.g. ![enclosure](enclosure/v4/case.step).
  Use absolute paths, or paths relative to the folder the session started in
  (not the shell's current directory, which may have moved). Don't build HTML viewers.
- Web pages and apps: run the dev server (or `python3 -m http.server`) on
  this machine in the background and link it, e.g. [the app](http://localhost:5173/).
- Anything long-running (servers, daemons, watchers): start it with Bash's
  `run_in_background`, never with `screen`, `nohup`, `&` or output redirected
  to a log file. The user watches, and can stop, your background commands in
  Margin's Shell tab, and they keep running while this chat is idle; read
  their output from the file Claude Code gives you.
  Margin opens localhost links in a browser on the iPad through its own proxy,
  live reload included, and the user can mark the page up. Don't open a browser here.
  Also publish each page or service you start with the `publish_page` tool (a
  short name, the localhost URL, one line on what it is): it then stays in the
  project's Preview tab so the user can come back to it.
- When something is ready for the user to look at (a page after a change, a
  render, a report, the lines of code or the diff you want their eye on), call
  the `show` tool with it. It never interrupts them: it joins a short list above
  their message box, and opens only when they tap it.
- When you ask a question with a few clear answers, also call `suggest_replies`
  so they can answer with a tap. The replies are shortcuts for their next
  message, not your answer: write your full answer as text too.
- For things the user will want to do again in this project (flash firmware,
  run the tests, deploy), add a button with the `set_action` tool; it shows
  above the message box. A few useful ones, not one per command.
- For anything else (Gerbers, plots, data, diagrams), convert it on this
  machine to one of those formats first, then reference the result.
- After the user views things, you may get a "[Margin display report]" saying
  which referenced files showed and which failed (and why). Fix failures
  without waiting to be told.
- Diagrams: fenced ```mermaid blocks (flowcharts, sequence, state, ER, Gantt)
  are drawn in place, as are ```svg blocks; prefer them to ASCII art.
- Code you write, edit or quote in fenced code blocks is shown highlighted, and
  edits are shown as diffs, so there is no need to repeat a whole file after editing it.
- Links are tappable: link project files as [board](v4/main.kicad_pcb) and
  web pages as [W5500 datasheet](https://...). When a part needs ordering, link
  its distributor page (e.g. DigiKey) with the part number.
- The user works like an executive reviewing a folio. When you plan (plan mode),
  present the plan for approval with ExitPlanMode, structured as:
  a one-paragraph summary; then one `## N. Title` section per change or
  decision, each with what changes, why, alternatives considered and your
  recommendation, plus inline renders/diffs where they help; then
  `## Decisions I made` listing calls you made yourself so they can be overruled;
  then `## Commands I'll run`: a fenced block with every shell command you'll
  need to carry out and verify the plan (builds, tests, kicad-cli, git), one
  per line, `*` allowed for varying arguments. Approving the plan approves
  these, so list them all; anything else will interrupt the reviewer.
  When the user needs to choose (an approach, a library, a part), put the
  question on its own line ending in "?" and follow it with a short list of
  options, marking the one you suggest "(recommended)"; Margin shows them as
  options to tap. Keep each `##` section something that can be done or left
  out on its own: the user can leave sections out when approving.
  The user comments per section and approves or sends it back; the approval
  may come with their choices, sections to leave out and notes: follow them.
  When it comes back, revise and present the next version, leading with what changed.
- In plan mode you can't write files, so mockups, wireframes and diagrams
  for a plan go in the plan itself as fenced ```svg blocks (a complete <svg>
  with a viewBox). Margin draws them in place, full screen on tap, and the
  user marks them up. Don't promise files you'll draw after approval instead.
- Feedback may include marked-up images (Apple Pencil drawings and notes on a
  render, model view or page), given by absolute path with the name of what was
  marked up. Read them: the drawing shows what is meant. Under each picture,
  every stroke is described (a circle, underline, line or dot, where it is)
  with what it's on: file and line numbers of code or diff lines, quoted text
  from the chat, a plan or a PDF, or mockup elements by id. Act on exactly that.
- Messages the user sends while you work are queued and arrive together when
  you finish; several may be voice notes, so read them as one set of instructions.
"""

# Sent with every prompt from the app (long sessions drift away from the system prompt).
PROMPT_REMINDER = (
    "[Margin] This message was sent from the Margin iPad app; the user can't see this computer's screen. "
    "To show images, SVGs, 3D models (STEP/USDZ/OBJ+MTL keep colours; STL/PLY don't), PDFs or KiCad "
    "schematics/boards, reference the file as a Markdown image with an absolute path, e.g. "
    "![v4 case](/path/to/enclosure/v4/case.step), and Margin renders it inline. "
    "Convert other formats (plots, diagrams) to one of these first. Never open things on this "
    "computer, build HTML viewers, or suggest `open` commands. Link parts and web pages as Markdown links, "
    "and project files as [name](relative/path). When you present a plan, end it with a "
    "`## Commands I'll run` fenced block listing every shell command you'll need."
)


# Bash commands that would put something on this machine's screen instead of the iPad's.
_SHOWS_ON_HOST = re.compile(
    r"(?:^|[;&|(`\n]|\$\()\s*(?:sudo\s+)?(?:open|xdg-open|gio\s+open|qlmanage\s+-p|start)(?=\s|$)"
    r"|\bwebbrowser\b|\bosascript\b.*\bactivate\b",
)


async def _block_host_display(input_data: dict[str, Any], tool_use_id: str | None, context: Any) -> dict[str, Any]:
    cmd = (input_data.get("tool_input") or {}).get("command") or ""
    if _SHOWS_ON_HOST.search(cmd):
        return {"hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": (
                "Blocked by Margin: the user is on an iPad and can't see this computer's screen. "
                "Don't open files or apps here. Reference images, 3D models (STL/OBJ/PLY/USDZ) or PDFs "
                "by path, e.g. ![name](path/to/file.stl), and Margin shows them inline."),
        }}
    return {}


@dataclass
class PendingPermission:
    id: str
    session_id: str
    tool_name: str
    tool_input: dict[str, Any]
    title: str | None
    description: str | None
    created_at: float
    suggestions: list[Any]
    future: asyncio.Future
    proposal_id: str | None = None
    push: dict[str, Any] | None = None        # its push, until sent
    push_timer: asyncio.Task | None = None

    def public(self) -> dict[str, Any]:
        return {
            "request_id": self.id,
            "session_id": self.session_id,
            "tool_name": self.tool_name,
            "input": normalize._tool_input(self.tool_input),
            "title": self.title,
            "description": self.description,
            "created_at": self.created_at,
            "can_always_allow": bool(self.suggestions),
        }


class LiveSession:
    def __init__(self, mgr: "SessionManager", session_id: str, project: str | None, cwd: str,
                 resume: bool, permission_mode: str) -> None:
        self.mgr = mgr
        self.session_id = session_id
        self.project = project
        self.cwd = cwd
        self.resume = resume
        self.permission_mode = permission_mode
        prefs = mgr.prefs.get(session_id, {})
        self.model: str | None = prefs.get("model") or mgr.ws.model
        self.effort: str | None = prefs.get("effort")
        self.reconnect = False          # effort changed: next prompt starts a fresh client
        self.turn: dict[str, Any] | None = None   # while working: since when, tokens, what it's doing
        self.wrote = False                         # wrote the user text since its last command this turn
        self.offered: bool | None = None           # offered replies this turn: had it written an answer first?
        self.starting: set[str] = set()            # tool uses that started a background command, result not in yet
        self.status = "starting"
        self.queue: asyncio.Queue[str] = asyncio.Queue()     # message ids, in order
        self.queued: dict[str, str] = {}                      # id -> text, until sent (or cancelled)
        self.briefed = False                                  # had the full Margin note in a prompt
        self.client: Any = None
        self.reader: asyncio.Task | None = None
        self.done = asyncio.Event()                           # the turn in progress ended
        self.task: asyncio.Task | None = None
        self.started_at = time.time()
        self.last_activity = time.time()

    # -- options ----------------------------------------------------------
    def options(self) -> ClaudeAgentOptions:
        ws = self.mgr.ws
        opts = ClaudeAgentOptions(
            cwd=self.cwd,
            permission_mode=self.permission_mode,  # type: ignore[arg-type]
            can_use_tool=self._can_use_tool,
            env=ws.sdk_env(),
            # Load ~/.claude, the repo's .claude/ and CLAUDE.md just like the CLI.
            setting_sources=["user", "project", "local"],
            system_prompt={"type": "preset", "preset": "claude_code", "append": REMOTE_NOTE},
            hooks={
                "PreToolUse": [HookMatcher(matcher="Bash", hooks=[_block_host_display])],
                "UserPromptSubmit": [HookMatcher(hooks=[self._remind_remote])],
                "Stop": [HookMatcher(hooks=[self._on_stop])],
                "Notification": [HookMatcher(hooks=[self._on_notification])],
            },
            model=self.model,
            mcp_servers={"margin": self._margin_server()},
            allowed_tools=list(MARGIN_TOOLS),
        )
        if self.effort:
            opts.effort = self.effort  # type: ignore[assignment]
        if self.resume:
            opts.resume = self.session_id
        else:
            opts.session_id = self.session_id
        return opts

    # -- Margin's tools for Claude --------------------------------------
    def _margin_server(self) -> Any:
        server = create_sdk_mcp_server("margin", tools=self.margin_tools())
        # Loaded with the session, not deferred behind tool search: they're few
        # and small, and Claude should reach for them without looking them up.
        server["alwaysLoad"] = True  # type: ignore[typeddict-unknown-key]
        return server

    def margin_tools(self) -> list[Any]:
        mgr, sess = self.mgr, self

        @tool("publish_page",
              "Show a web page or service running on this computer in the project's Preview tab in Margin, "
              "under a name, so the user can open it on the iPad any time (until unpublished). Use it for "
              "dev servers, dashboards, docs and tools you start for this project. Publishing the same name "
              "again updates it.",
              {"type": "object", "properties": {
                  "name": {"type": "string", "description": "Short name, e.g. 'Station dashboard'"},
                  "url": {"type": "string", "description": "http://localhost:<port>/path on this computer"},
                  "description": {"type": "string", "description": "One line: what it is or what to look at"},
                  "kind": {"type": "string", "enum": ["page", "service"],
                           "description": "page: something to look at; service: an API or tool"}},
               "required": ["name", "url"]})
        async def publish_page(args: dict[str, Any]) -> dict[str, Any]:
            if not sess.project:
                return _tool_text("This session isn't in a Margin project, so there's no Preview tab to publish to.", True)
            try:
                p = mgr.published.publish(sess.project, str(args.get("name", "")), str(args.get("url", "")),
                                          str(args.get("description") or ""), str(args.get("kind") or "page"),
                                          sess.session_id)
            except PublishError as e:
                return _tool_text(str(e), True)
            mgr.publish_pages(sess.project, sess.session_id)
            return _tool_text(f"Published “{p['name']}” (localhost:{p['port']}{p['path']}) in {sess.project}'s Preview tab.")

        @tool("unpublish_page", "Remove a page published with publish_page from the project's Preview tab.",
              {"type": "object", "properties": {"name": {"type": "string"}}, "required": ["name"]})
        async def unpublish_page(args: dict[str, Any]) -> dict[str, Any]:
            if not sess.project or not mgr.published.remove(sess.project, str(args.get("name", ""))):
                return _tool_text("No page by that name.", True)
            mgr.publish_pages(sess.project, sess.session_id)
            return _tool_text("Removed.")

        @tool("set_action",
              "Put a button above the message box in Margin for this project, for things the user will want "
              "to do again: 'Flash firmware', 'Run tests', 'Deploy preview'. Give exactly one of: command (runs "
              "in a new shell in the project, output shown, shell stays open; the user sees the command before "
              "the first run), prompt (sends you that message), or url (opens a localhost page). Same label "
              "replaces it. Keep it to a few useful buttons.",
              {"type": "object", "properties": {
                  "label": {"type": "string", "description": "2-3 words"},
                  "command": {"type": "string", "description": "Shell command, run from the project folder"},
                  "cwd": {"type": "string", "description": "Folder inside the project to run it in"},
                  "prompt": {"type": "string"},
                  "url": {"type": "string", "description": "http://localhost:<port>/path"},
                  "description": {"type": "string", "description": "One line: what it does"},
                  "icon": {"type": "string", "description": "SF Symbol name, e.g. bolt, play, hammer"}},
               "required": ["label"]})
        async def set_action(args: dict[str, Any]) -> dict[str, Any]:
            root = sess.project_root()
            if not root:
                return _tool_text("This session isn't in a Margin project.", True)
            try:
                a = actions.set_action(root, str(args.get("label", "")),
                                       command=str(args.get("command") or ""), prompt=str(args.get("prompt") or ""),
                                       url=str(args.get("url") or ""), description=str(args.get("description") or ""),
                                       icon=str(args.get("icon") or ""), cwd=str(args.get("cwd") or ""))
            except actions.ActionError as e:
                return _tool_text(str(e), True)
            mgr.publish_actions(sess.project or "")
            return _tool_text(f"Button “{a['label']}” is above the message box in Margin.")

        @tool("remove_action", "Remove a button set with set_action.",
              {"type": "object", "properties": {"label": {"type": "string"}}, "required": ["label"]})
        async def remove_action(args: dict[str, Any]) -> dict[str, Any]:
            root = sess.project_root()
            if not root or not actions.remove_action(root, str(args.get("label", ""))):
                return _tool_text("No button with that label.", True)
            mgr.publish_actions(sess.project or "")
            return _tool_text("Removed.")

        @tool("show",
              "Point the user at something in Margin when it's worth their look: a web page (a localhost URL, "
              "e.g. after a design change), a file (a render, report, PDF, model; for text and code, the lines "
              "that matter), or a file's uncommitted changes. It's added to a short list above their message "
              "box in this chat; nothing opens or moves until they tap it, and it waits if they're elsewhere. "
              "Pointing at the same thing again replaces the older one.",
              {"type": "object", "properties": {
                  "url": {"type": "string", "description": "http://localhost:<port>/path"},
                  "file": {"type": "string", "description": "Path of a file in the project"},
                  "line": {"type": "integer", "description": "With file: first line to show (1-based)"},
                  "end_line": {"type": "integer", "description": "With file and line: last line"},
                  "changes": {"type": "string", "description": "Path of a file whose uncommitted changes to show"},
                  "title": {"type": "string", "description": "Short, e.g. 'New station page'"},
                  "note": {"type": "string", "description": "One line: what to look at"}},
               "required": ["title"]})
        async def show(args: dict[str, Any]) -> dict[str, Any]:
            url, file = str(args.get("url") or "").strip(), str(args.get("file") or "").strip()
            changes = str(args.get("changes") or "").strip()
            if sum(map(bool, (url, file, changes))) != 1:
                return _tool_text("Give one of url, file or changes.", True)
            item: dict[str, Any] = {"id": uuid.uuid4().hex[:8], "title": str(args.get("title") or "")[:80],
                                    "note": str(args.get("note") or "")[:200], "created_at": time.time()}
            if url:
                try:
                    port, path = parse_local_url(url)
                except PublishError as e:
                    return _tool_text(str(e), True)
                item |= {"kind": "page", "port": port, "path": path}
            else:
                rel = file or changes
                full = os.path.realpath(rel if os.path.isabs(rel) else os.path.join(sess.cwd, rel))
                if not os.path.isfile(full):
                    return _tool_text(f"No file at {full}.", True)
                item |= {"kind": "file" if file else "changes", "path": full}
                if file and args.get("line"):
                    first = max(1, int(args["line"]))
                    item |= {"line": first, "end_line": max(first, int(args.get("end_line") or first))}
            mgr.add_show(sess.session_id, item)
            return _tool_text("Added to the list above the user's message box; they'll open it when they're ready.")

        @tool("suggest_replies",
              "When you've asked the user something with a few clear answers, offer them as short replies they "
              "can tap instead of typing (each goes into their message box to edit or send, never sent for them). "
              "Up to 4, a few words each. Cleared when they send their next message. The replies are only "
              "shortcuts for what they might say next: they don't carry your answer, so still write your full "
              "answer as text.",
              {"type": "object", "properties": {
                  "options": {"type": "array", "items": {"type": "string"}, "maxItems": 4}},
               "required": ["options"]})
        async def suggest_replies(args: dict[str, Any]) -> dict[str, Any]:
            opts = [re.sub(r"\s+", " ", str(o)).strip()[:200] for o in (args.get("options") or [])]
            opts = [o for o in opts if o][:4]
            if not opts:
                return _tool_text("Give at least one option.", True)
            mgr.replies[sess.session_id] = opts
            mgr.bus.publish("session.replies", session_id=sess.session_id, replies=opts)
            sess.offered = sess.wrote
            if not sess.wrote:
                return _tool_text("Offered under the conversation. You haven't answered the user since your last "
                                  "command: the replies don't answer them. Write your full answer now, as text.")
            return _tool_text("Offered under the conversation. If your answer to the user isn't written out as "
                              "text yet, write it now; the replies don't carry it.")

        return [publish_page, unpublish_page, set_action, remove_action, show, suggest_replies]

    def project_root(self) -> str | None:
        if not self.project:
            return None
        try:
            return self.mgr.ws.project(self.project).path
        except KeyError:
            return None

    # -- lifecycle --------------------------------------------------------
    def _set_status(self, status: str) -> None:
        if status != self.status:
            self.status = status
            self.mgr.bus.publish("session.status", session_id=self.session_id, status=status,
                                 project=self.project)

    async def run(self) -> None:
        idle = max(60, self.mgr.ws.idle_disconnect_minutes * 60)
        try:
            await self._connect()
            if self.queue.empty():          # a message is waiting: go straight to running
                self._set_status("idle")
            while True:
                try:
                    first = await asyncio.wait_for(self.queue.get(), timeout=idle)
                except asyncio.TimeoutError:
                    if self.turn is not None or self.mgr.crons.get(self.session_id) \
                            or self.mgr.running_tasks(self.session_id):
                        continue                   # working on something it started itself, or will;
                                                   # or its background commands would end with it

                    break
                prompt = self._take(first)
                if prompt is None:
                    continue
                self.last_activity = time.time()
                if self.reconnect:
                    await self._connect()
                self.done.clear()
                if self.turn is None:
                    self._begin_turn()
                self._set_status("running")
                await self.client.query(prompt)
                await self._until_done()
        except asyncio.CancelledError:
            raise
        except Exception as e:  # surface to the app, keep the daemon alive
            log.exception("session %s failed", self.session_id)
            self.mgr.bus.publish("session.error", session_id=self.session_id, message=str(e))
            await self.mgr.notify({"kind": "error", "session_id": self.session_id,
                                   "title": f"{self.mgr.ws.name}: session error", "body": str(e)[:180]})
        finally:
            for p in [p for p in self.mgr.pending.values() if p.session_id == self.session_id]:
                if not p.future.done():
                    p.future.set_result(("deny", "session closed", False))
            await self._stop_reading()
            if self.client is not None:
                try:
                    await self.client.disconnect()
                except Exception:
                    pass
            if self.turn is not None:
                self._end_turn()
            self.mgr.claude_tasks.pop(self.session_id, None)    # they end with the Claude process
            if self.mgr.task_states.pop(self.session_id, None):
                self.mgr.bus.publish("session.tasks", session_id=self.session_id)
            self.mgr.set_crons(self.session_id, [])
            self._set_status("closed")
            self.mgr.live.pop(self.session_id, None)

    async def _until_done(self) -> None:
        """Wait for the turn to end, or for Claude Code to stop altogether."""
        waiter = asyncio.ensure_future(self.done.wait())
        try:
            await asyncio.wait({waiter, self.reader}, return_when=asyncio.FIRST_COMPLETED)
        finally:
            waiter.cancel()
        if not self.done.is_set() and self.reader.done():
            if exc := self.reader.exception():
                raise exc
            raise RuntimeError("Claude Code stopped")

    async def _read(self) -> None:
        """Everything Claude Code says, for as long as it's connected. Read
        all the time, not one reply per prompt: it can carry on after a turn
        has ended (a background command finished, or an early empty result
        came before the real work), and unread output backs up until its tool
        calls stall."""
        async for msg in self.client.receive_messages():
            self.last_activity = time.time()
            if self.turn is None and not isinstance(msg, (SystemMessage, ResultMessage)):
                self._begin_turn()
                self._set_status("running")
            self._track(msg)
            await self._handle(msg)
            if isinstance(msg, ResultMessage):
                if self.turn is not None:
                    self._end_turn()
                if self.status != "waiting":
                    self._set_status("idle")
                self.done.set()

    async def _stop_reading(self) -> None:
        if self.reader is not None:
            self.reader.cancel()
            try:
                await self.reader
            except BaseException:
                pass
            self.reader = None

    async def _connect(self) -> None:
        await self._stop_reading()
        if self.client is not None:
            # Effort is fixed per connection: reconnect and resume the same conversation.
            try:
                await self.client.disconnect()
            except Exception:
                pass
            self.resume = True
        self.reconnect = False
        self.client = self.mgr.client_factory(self.options())
        await self.client.connect()
        self.reader = asyncio.create_task(self._read())
        if not self.mgr.models and hasattr(self.client, "get_server_info"):
            try:
                info = await self.client.get_server_info() or {}
                self.mgr.models = [m for m in info.get("models") or [] if isinstance(m, dict)]
            except Exception:
                log.exception("server info")

    def _take(self, first: str) -> str | None:
        """Everything queued while Claude was working goes as one prompt, like
        Claude Code: a few voice notes in a row arrive together."""
        ids = [first]
        while not self.queue.empty():
            ids.append(self.queue.get_nowait())
        texts = [t for i in ids if (t := self.queued.pop(i, None)) is not None]
        if not texts:
            return None
        self.mgr.bus.publish("session.items", session_id=self.session_id,
                             items=[{"kind": "user_text", "text": t, "parent_tool_use_id": None} for t in texts])
        self.mgr.publish_queue(self)
        return "\n\n".join(texts)

    async def _remind_remote(self, input_data: dict[str, Any], tool_use_id: str | None,
                             context: Any) -> dict[str, Any]:
        # The first prompt through Margin carries the whole note: a session
        # started at the desk never had it in its system prompt.
        note = PROMPT_REMINDER if self.briefed else REMOTE_NOTE + "\n" + PROMPT_REMINDER
        self.briefed = True
        if report := self.mgr.take_display_report(self.session_id):
            note += "\n\n" + report
        return {"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": note}}

    async def _on_stop(self, input_data: dict[str, Any], tool_use_id: str | None,
                       context: Any) -> dict[str, Any]:
        # Claude Code's own account, at the end of each turn, of what's still
        # running and when it will wake itself up.
        self.mgr.claude_tasks[self.session_id] = (time.time(), {
            str(t.get("id")): str(t.get("status") or "running")
            for t in input_data.get("background_tasks") or [] if t.get("type") == "shell"})
        self.mgr.set_crons(self.session_id, input_data.get("session_crons") or [])
        if not input_data.get("stop_hook_active") and self._unanswered(str(input_data.get("last_assistant_message") or "")):
            self.offered = None
            return {"decision": "block", "reason": UNANSWERED}
        return {}

    def _unanswered(self, last: str) -> bool:
        """Offered replies and stopped without an answer: nothing written since
        its last command, or only a line after the replies ("they're below")."""
        if self.offered is None:
            return False
        return len(last.strip()) < 300 and (not self.wrote or not self.offered)

    async def _on_notification(self, input_data: dict[str, Any], tool_use_id: str | None,
                               context: Any) -> dict[str, Any]:
        kind = str(input_data.get("notification_type") or "")
        if kind == "permission_prompt":
            # Claude Code's moment to tell you an approval is waiting (it gives
            # you a few seconds first): push the ones not pushed yet.
            for req in [p for p in self.mgr.pending.values() if p.session_id == self.session_id]:
                await self.mgr.push_pending(req)
        elif kind != "idle_prompt":         # the "done" push already says so
            await self.mgr.notify({
                "kind": "notification", "session_id": self.session_id,
                "title": f"{self.mgr.ws.name}: {input_data.get('title') or 'Claude Code'}"
                         + (f" · {self.project}" if self.project else ""),
                "body": str(input_data.get("message") or "")[:180],
            })
        return {}

    # -- what it's doing right now (Claude Code's spinner line) -------------
    def _begin_turn(self) -> None:
        self.turn = {"started_at": time.time(), "tokens": 0, "doing": "Thinking", "detail": ""}
        self._turn_usage: dict[str, int] = {}
        self.wrote = False
        self.offered = None
        self._publish_turn()

    def _end_turn(self) -> None:
        self.turn = None
        self._publish_turn()

    def _publish_turn(self) -> None:
        self.mgr.bus.publish("session.activity", session_id=self.session_id,
                             activity=dict(self.turn) if self.turn else None)

    def _track(self, msg: Any) -> None:
        if self.turn is None or not isinstance(msg, AssistantMessage):
            return
        usage = msg.usage or {}
        # One API message arrives as several (one per block) with the same usage: count it once.
        key = msg.message_id or str(id(msg))
        self._turn_usage[key] = int(usage.get("output_tokens") or 0)
        self.turn["tokens"] = sum(self._turn_usage.values())
        for block in msg.content or []:
            if isinstance(block, ToolUseBlock):
                self.turn["doing"], self.turn["detail"] = _doing(block.name, block.input or {})
                if not msg.parent_tool_use_id and not block.name.startswith("mcp__margin__"):
                    self.wrote = False      # a line before running something isn't the answer
            elif isinstance(block, ThinkingBlock):
                self.turn["doing"], self.turn["detail"] = "Thinking", ""
            elif isinstance(block, TextBlock) and block.text.strip():
                self.turn["doing"], self.turn["detail"] = "Writing", ""
                if not msg.parent_tool_use_id:
                    self.wrote = True       # something the user sees, not a subagent's
        if msg.parent_tool_use_id:
            self.turn["doing"] = "Agent: " + self.turn["doing"].lower()
        self._publish_turn()

    def _task_event(self, msg: Any) -> None:
        """Claude Code says a background command started or ended, as it happens."""
        if isinstance(msg, TaskStartedMessage):
            status = "running"
            if msg.tool_use_id:
                self.starting.add(msg.tool_use_id)
        elif isinstance(msg, TaskUpdatedMessage):
            status = msg.status or (msg.patch or {}).get("status")
        else:
            status = msg.status
        if not status:
            return
        self.mgr.task_states.setdefault(self.session_id, {})[msg.task_id] = "running" if status == "pending" else status
        self.mgr.bus.publish("session.tasks", session_id=self.session_id)

    async def _handle(self, msg: Any) -> None:
        if isinstance(msg, (TaskStartedMessage, TaskUpdatedMessage, TaskNotificationMessage)):
            self._task_event(msg)
        if isinstance(msg, SystemMessage):
            return
        if isinstance(msg, ResultMessage):
            ev = {
                "session_id": self.session_id,
                "project": self.project,
                "is_error": msg.is_error,
                "subtype": msg.subtype,
                "num_turns": msg.num_turns,
                "duration_ms": msg.duration_ms,
                "cost_usd": msg.total_cost_usd,
                "result": normalize._clip(msg.result or "", 2000),
            }
            if not msg.num_turns and not (msg.result or "").strip() and not msg.is_error:
                return      # an empty result before any work (Claude carries on after it): not an answer
            self.mgr.bus.publish("session.result", **ev)
            if done := self.mgr.proposals.finish(self.session_id, ev["result"], bool(msg.is_error)):
                self.mgr.bus.publish("proposal", proposal=done.public())
            lines = (msg.result or "").strip().splitlines()
            summary = lines[0][:180] if lines else msg.subtype
            await self.mgr.notify({
                "kind": "result", "session_id": self.session_id,
                "title": f"{self.mgr.ws.name}: {'failed' if msg.is_error else 'done'}"
                         + (f" · {self.project}" if self.project else ""),
                "body": summary,
            })
            return
        items = normalize.from_sdk(msg)
        if items:
            self.mgr.bus.publish("session.items", session_id=self.session_id, items=items)
            # Its tool result is in the transcript now, with where the output goes.
            if self.starting & {i.get("tool_use_id") for i in items if i["kind"] == "tool_result"}:
                self.starting -= {i.get("tool_use_id") for i in items}
                self.mgr.bus.publish("session.tasks", session_id=self.session_id)

    # -- permissions ------------------------------------------------------
    async def _can_use_tool(self, tool_name: str, tool_input: dict[str, Any],
                            ctx: ToolPermissionContext) -> PermissionResultAllow | PermissionResultDeny:
        # Carrying out an approved plan: commands it listed (and read-only ones) don't ask again.
        if tool_name == "Bash":
            approved = self.mgr.proposals.approved_commands(self.session_id)
            if approved is not None and scope.allows(str(tool_input.get("command") or ""), approved, self.cwd):
                return PermissionResultAllow()
        loop = asyncio.get_running_loop()
        req = PendingPermission(
            id=uuid.uuid4().hex[:12],
            session_id=self.session_id,
            tool_name=tool_name,
            tool_input=tool_input,
            title=getattr(ctx, "title", None),
            description=getattr(ctx, "description", None) or getattr(ctx, "decision_reason", None),
            created_at=time.time(),
            suggestions=list(getattr(ctx, "suggestions", []) or []),
            future=loop.create_future(),
        )
        self.mgr.pending[req.id] = req
        self._set_status("waiting")
        if tool_name == "ExitPlanMode":
            # A plan for review: it becomes a proposal in the folio, not an approval card.
            prop = self.mgr.proposals.add(self.session_id, self.project, str(tool_input.get("plan") or ""), req.id)
            req.proposal_id = prop.id
            self.mgr.bus.publish("proposal", proposal=prop.public())
            self.mgr.push_later(req, {
                "kind": "proposal", "session_id": self.session_id, "proposal_id": prop.id,
                "title": f"{self.mgr.ws.name}: proposal ready" + (f" · {self.project}" if self.project else ""),
                "body": prop.title + (f" (v{prop.version})" if prop.version > 1 else ""),
            })
        else:
            self.mgr.bus.publish("permission.request", **req.public())
            self.mgr.push_later(req, {
                "kind": "permission", "session_id": self.session_id, "request_id": req.id,
                "title": f"{self.mgr.ws.name}: approve {tool_name}?",
                "body": req.title or _one_line(tool_input),
            })
        try:
            decision, message, always = await req.future
        finally:
            self.mgr.pending.pop(req.id, None)
            if req.push_timer:
                req.push_timer.cancel()
            if req.proposal_id is None:
                self.mgr.bus.publish("permission.resolved", request_id=req.id, session_id=self.session_id)
            if self.status == "waiting":
                self._set_status("running")
        if req.proposal_id is not None:
            result = _plan_decision(tool_input, decision, message, self.mgr.ws.approved_mode)
            if isinstance(result, PermissionResultAllow):
                self.permission_mode = self.mgr.ws.approved_mode
                self.mgr.publish_settings(self.session_id)
            return result
        if decision == "allow":
            return PermissionResultAllow(updated_permissions=req.suggestions if always else None)
        return PermissionResultDeny(message=message or "Denied from Margin", interrupt=message == INTERRUPTED)


def _plan_decision(tool_input: dict[str, Any], decision: str, feedback: str | None,
                   approved_mode: str = "auto") -> PermissionResultAllow | PermissionResultDeny:
    """Approve: Claude gets the plan back with the reviewer's notes appended and
    carries it out in `approved_mode` (auto: routine actions go through, risky ones are stopped). Send back: the feedback goes to
    Claude, which stays in plan mode and presents a revised version."""
    if decision == "allow":
        plan = str(tool_input.get("plan") or "")
        if feedback:
            plan += "\n\n## Reviewer notes (approved with these; follow them)\n\n" + feedback
        return PermissionResultAllow(
            updated_input={**tool_input, "plan": plan},
            updated_permissions=[PermissionUpdate(type="setMode", mode=approved_mode, destination="session")],  # type: ignore[arg-type]
        )
    return PermissionResultDeny(
        message="The reviewer sent this plan back for changes:\n\n" + (feedback or "(no notes)")
                + "\n\nRevise the plan and present the next version with ExitPlanMode, starting with what changed.",
        interrupt=False,
    )


def _one_line(inp: dict[str, Any]) -> str:
    for k in ("command", "file_path", "path", "url", "pattern", "description"):
        if k in inp:
            return str(inp[k])[:180]
    return str(inp)[:180]


class SessionManager:
    def __init__(self, ws: WorkspaceConfig, bus: EventBus,
                 client_factory: ClientFactory = ClaudeSDKClient,
                 notifier: Notifier | None = None) -> None:
        self.ws = ws
        self.bus = bus
        self.client_factory = client_factory
        self._notifier = notifier
        self.live: dict[str, LiveSession] = {}
        self.pending: dict[str, PendingPermission] = {}
        self._cwd_cache: dict[str, str] = {}
        self.proposals = ProposalStore.load(ws.state_path / "proposals.json")
        # session id -> {"permission_mode", "model", "effort"} chosen in the app; kept across restarts
        self._prefs_path = ws.state_path / "session_prefs.json"
        try:
            self.prefs: dict[str, dict[str, str]] = json.loads(self._prefs_path.read_text())
        except (OSError, ValueError):
            self.prefs = {}
        self.models: list[dict[str, Any]] = []   # from Claude Code, once a session connects
        self.published = PublishedStore(ws.state_path / "published.json")
        self.shows: dict[str, list[dict[str, Any]]] = {}   # session id -> what Claude pointed at, oldest first
        self.replies: dict[str, list[str]] = {}             # session id -> replies Claude offered
        self.crons: dict[str, list[dict[str, Any]]] = {}     # session id -> wakeups Claude scheduled
        # session id -> (when, {task id: status}): its background commands, at the end of its last turn
        self.claude_tasks: dict[str, tuple[float, dict[str, str]]] = {}
        # session id -> {task id: status}: background commands started or ended while live, as they happen
        self.task_states: dict[str, dict[str, str]] = {}
        self.approval_push_after = APPROVAL_PUSH_AFTER
        self._models_task: asyncio.Task | None = None
        self.started_at = time.time()
        # session id -> path -> (shown, detail): what the app could and couldn't display
        self.display: dict[str, dict[str, tuple[bool, str]]] = {}
        self._display_sent: dict[str, dict[str, tuple[bool, str]]] = {}

    async def notify(self, payload: dict[str, Any]) -> None:
        if self._notifier:
            try:
                await self._notifier(payload)
            except Exception:
                log.exception("notification failed")

    def running_tasks(self, session_id: str) -> bool:
        """Claude's background commands still running in this chat, by what
        Claude Code said as they started and ended, or at the end of its last turn."""
        states = dict(self.claude_tasks.get(session_id, (0, {}))[1])
        states.update(self.task_states.get(session_id, {}))
        return any(s == "running" for s in states.values())

    async def stop_task(self, session_id: str, task_id: str) -> None:
        """Stop one of Claude's background commands, as at the desk; the chat carries on."""
        sess = self.live.get(session_id)
        if sess is None or sess.client is None:
            raise KeyError(session_id)
        await sess.client.stop_task(task_id)

    def push_later(self, req: PendingPermission, payload: dict[str, Any]) -> None:
        """An approval or plan is pushed when Claude Code raises its own
        notification for it (a few seconds in, so not while you're answering
        it already), or after APPROVAL_PUSH_AFTER if it never does."""
        req.push = payload

        async def fallback() -> None:
            await asyncio.sleep(self.approval_push_after)
            await self.push_pending(req)
        req.push_timer = asyncio.create_task(fallback())

    async def push_pending(self, req: PendingPermission) -> None:
        payload, req.push = req.push, None
        if payload and req.id in self.pending:
            await self.notify(payload)

    def set_crons(self, session_id: str, found: list[dict[str, Any]]) -> None:
        items = [{"id": str(c.get("id")), "schedule": str(c.get("schedule") or ""),
                  "recurring": bool(c.get("recurring")), "prompt": str(c.get("prompt") or "")[:300],
                  "next_at": crons.next_fire(str(c.get("schedule") or ""))} for c in found]
        if items != self.crons.get(session_id, []):
            if items:
                self.crons[session_id] = items
            else:
                self.crons.pop(session_id, None)
            self.bus.publish("session.crons", session_id=session_id, crons=items)

    # -- starting / talking ----------------------------------------------
    def _mode(self, permission_mode: str | None, session_id: str | None = None) -> str:
        mode = (permission_mode or (self.prefs.get(session_id or "", {}).get("permission_mode"))
                or self.ws.default_permission_mode)
        if mode not in PERMISSION_MODES:
            raise ValueError(f"unknown permission mode {mode!r}")
        return mode

    def _spawn(self, sess: LiveSession) -> None:
        self.live[sess.session_id] = sess
        self._cwd_cache[sess.session_id] = sess.cwd
        sess.task = asyncio.create_task(sess.run(), name=f"session-{sess.session_id}")
        self.bus.publish("session.started", session_id=sess.session_id, project=sess.project,
                         cwd=sess.cwd, resumed=sess.resume)

    async def start(self, project: str, prompt: str, permission_mode: str | None = None) -> str:
        proj = self.ws.project(project)
        sid = str(uuid.uuid4())
        sess = LiveSession(self, sid, proj.name, proj.path, resume=False,
                           permission_mode=self._mode(permission_mode))
        self._spawn(sess)
        await self._enqueue(sess, prompt)
        return sid

    async def send(self, session_id: str, text: str, permission_mode: str | None = None) -> None:
        if self.replies.pop(session_id, None) is not None:
            self.bus.publish("session.replies", session_id=session_id, replies=[])
        sess = self.live.get(session_id)
        if sess is None:
            cwd = await self._find_cwd(session_id)
            if cwd is None:
                raise KeyError(session_id)
            sess = LiveSession(self, session_id, self.ws.project_for_cwd(cwd), cwd, resume=True,
                               permission_mode=self._mode(permission_mode, session_id))
            self._spawn(sess)
        elif permission_mode and permission_mode != sess.permission_mode:
            sess.permission_mode = self._mode(permission_mode)
            if sess.client is not None and hasattr(sess.client, "set_permission_mode"):
                await sess.client.set_permission_mode(sess.permission_mode)
            self.publish_settings(session_id)
        await self._enqueue(sess, text)

    # -- per-chat settings ------------------------------------------------
    def settings(self, session_id: str) -> dict[str, Any]:
        sess = self.live.get(session_id)
        prefs = self.prefs.get(session_id, {})
        return {
            "permission_mode": sess.permission_mode if sess else self._mode(None, session_id),
            "model": (sess.model if sess else prefs.get("model") or self.ws.model),
            "effort": sess.effort if sess else prefs.get("effort"),
            "models": [{k: m.get(k) for k in ("value", "displayName", "description", "supportedEffortLevels")}
                       for m in self.models],
            "modes": sorted(PERMISSION_MODES),
        }

    def want_models(self, session_id: str) -> None:
        """No session has connected yet: ask Claude Code for its model list in
        the background, then send the chat its settings again."""
        if self.models or (self._models_task and not self._models_task.done()) or not self.ws.projects:
            return

        async def fetch() -> None:
            client = self.client_factory(ClaudeAgentOptions(cwd=self.ws.projects[0].path, env=self.ws.sdk_env(),
                                                            setting_sources=["user"]))
            try:
                await asyncio.wait_for(client.connect(), 60)
                if hasattr(client, "get_server_info"):
                    info = await client.get_server_info() or {}
                    self.models = [m for m in info.get("models") or [] if isinstance(m, dict)]
            except Exception:
                log.exception("fetching the model list")
            finally:
                try:
                    await client.disconnect()
                except Exception:
                    pass
            if self.models:
                self.publish_settings(session_id)

        self._models_task = asyncio.create_task(fetch())

    def add_show(self, session_id: str, item: dict[str, Any]) -> None:
        same = lambda o: all(o.get(k) == item.get(k) for k in ("kind", "port", "path"))
        items = [o for o in self.shows.get(session_id, []) if not same(o)] + [item]
        self.shows[session_id] = items[-6:]
        self.bus.publish("session.show", session_id=session_id, shows=self.shows[session_id])

    def remove_show(self, session_id: str, show_id: str | None) -> None:
        items = self.shows.get(session_id, [])
        keep = [o for o in items if show_id is not None and o["id"] != show_id]
        if len(keep) != len(items):
            if keep:
                self.shows[session_id] = keep
            else:
                self.shows.pop(session_id, None)
            self.bus.publish("session.show", session_id=session_id, shows=keep)

    def publish_pages(self, project: str, session_id: str | None = None) -> None:
        self.bus.publish("published", project=project, session_id=session_id,
                         pages=self.published.list(project))

    def publish_actions(self, project: str) -> None:
        try:
            root = self.ws.project(project).path
        except KeyError:
            return
        self.bus.publish("actions", project=project, actions=actions.load(root))

    def publish_ideas(self, project: str) -> None:
        try:
            root = self.ws.project(project).path
        except KeyError:
            return
        self.bus.publish("ideas", project=project, ideas=ideas.load(root))

    def publish_settings(self, session_id: str) -> None:
        self.bus.publish("session.settings", session_id=session_id, settings=self.settings(session_id))

    async def update_settings(self, session_id: str, permission_mode: str | None = None,
                              model: str | None = None, effort: str | None = None) -> dict[str, Any]:
        """Change a chat's mode, model or effort. A live session switches now
        (effort from its next message); otherwise it applies when it resumes."""
        if permission_mode is not None:
            self._mode(permission_mode)
        if effort is not None and effort not in EFFORTS and effort != "":
            raise ValueError(f"unknown effort {effort!r}")
        prefs = self.prefs.setdefault(session_id, {})
        sess = self.live.get(session_id)
        if permission_mode:
            prefs["permission_mode"] = permission_mode
            if sess and permission_mode != sess.permission_mode:
                sess.permission_mode = permission_mode
                if sess.client is not None and hasattr(sess.client, "set_permission_mode"):
                    await sess.client.set_permission_mode(permission_mode)
        if model is not None:
            prefs["model"] = model
            if sess and model != sess.model:
                sess.model = model or self.ws.model
                if sess.client is not None and hasattr(sess.client, "set_model"):
                    await sess.client.set_model(model or None)
        if effort is not None:
            prefs["effort"] = effort
            if sess and (effort or None) != sess.effort:
                sess.effort = effort or None
                sess.reconnect = sess.client is not None
        prefs = {k: v for k, v in prefs.items() if v}
        if prefs:
            self.prefs[session_id] = prefs
        else:
            self.prefs.pop(session_id, None)
        try:
            self._prefs_path.write_text(json.dumps(self.prefs, indent=1))
        except OSError:
            log.exception("saving session prefs")
        self.publish_settings(session_id)
        return self.settings(session_id)

    async def _enqueue(self, sess: LiveSession, text: str) -> str:
        """While Claude works, messages wait in the session's queue (shown in
        the app, cancellable) and go together when it finishes."""
        qid = uuid.uuid4().hex[:10]
        sess.queued[qid] = text
        await sess.queue.put(qid)
        self.publish_queue(sess)
        return qid

    def publish_queue(self, sess: LiveSession) -> None:
        self.bus.publish("session.queue", session_id=sess.session_id, queued=self.queue_of(sess.session_id))

    def queue_of(self, session_id: str) -> list[dict[str, str]]:
        sess = self.live.get(session_id)
        return [{"id": i, "text": t} for i, t in sess.queued.items()] if sess else []

    def cancel_queued(self, session_id: str, qid: str) -> None:
        sess = self.live.get(session_id)
        if sess is None or sess.queued.pop(qid, None) is None:
            raise KeyError(qid)
        self.publish_queue(sess)

    def report_display(self, session_id: str, items: list[dict[str, Any]]) -> None:
        """The app says which referenced files it could show; Claude hears about
        changes with the next prompt."""
        d = self.display.setdefault(session_id, {})
        for it in items[:50]:
            if path := str(it.get("path") or ""):
                d[path] = (bool(it.get("ok")), str(it.get("detail") or "")[:300])

    def take_display_report(self, session_id: str) -> str | None:
        now, sent = self.display.get(session_id, {}), self._display_sent.setdefault(session_id, {})
        new = {p: v for p, v in now.items() if sent.get(p) != v}
        if not new:
            return None
        sent.update(new)
        lines = [f"- {'shown' if ok else 'FAILED'}: {p}" + (f" ({detail})" if detail else "")
                 for p, (ok, detail) in new.items()]
        return "[Margin display report] Files you referenced, as the iPad showed them:\n" + "\n".join(lines)

    async def interrupt(self, session_id: str) -> None:
        """Stop the current turn, like Esc in Claude Code: an approval Claude is
        waiting on is refused, then queued or new messages carry on from there.
        A plan awaiting review stays in the folio."""
        for req in list(self.pending.values()):
            if req.session_id == session_id and req.proposal_id is None and not req.future.done():
                req.future.set_result(("deny", INTERRUPTED, False))
        sess = self.live.get(session_id)
        if sess and sess.client is not None:
            await sess.client.interrupt()

    async def close(self, session_id: str) -> None:
        sess = self.live.get(session_id)
        if sess and sess.task:
            sess.task.cancel()

    def resolve_permission(self, request_id: str, decision: str, message: str | None = None,
                           always: bool = False) -> None:
        req = self.pending.get(request_id)
        if req is None:
            raise KeyError(request_id)
        if decision not in ("allow", "deny"):
            raise ValueError("decision must be allow or deny")
        if not req.future.done():
            req.future.set_result((decision, message, always))

    async def decide_proposal(self, proposal_id: str, decision: str, feedback: str | None = None) -> dict[str, Any]:
        """approve | revise. Answers the live plan request when the session is
        still waiting on it; otherwise resumes the session with the decision."""
        p = self.proposals.items.get(proposal_id)
        if p is None:
            raise KeyError(proposal_id)
        if decision not in ("approve", "revise"):
            raise ValueError("decision must be approve or revise")
        if p.status != "pending":
            raise ValueError(f"this proposal is already {p.status}")
        feedback = (feedback or "").strip() or None
        req = self.pending.get(p.request_id) if p.request_id else None
        self.proposals.decide(p, "approved" if decision == "approve" else "revise", feedback)
        if req is not None and not req.future.done():
            req.future.set_result(("allow" if decision == "approve" else "deny", feedback, False))
        elif decision == "approve":
            await self.send(p.session_id,
                            f"Approved: go ahead and carry out the plan (v{p.version})."
                            + (f"\n\nReviewer notes (follow these):\n\n{feedback}" if feedback else ""),
                            permission_mode=self.ws.approved_mode)
        else:
            await self.send(p.session_id,
                            f"I'm sending the plan (v{p.version}) back for changes:\n\n{feedback or '(no notes)'}"
                            "\n\nRevise it and present the next version with ExitPlanMode, starting with what changed.",
                            permission_mode="plan")
        self.bus.publish("proposal", proposal=p.public())
        return p.public()

    def save_markup(self, session_id: str, data: bytes) -> str:
        """Store a marked-up image from the app inside the session's project
        (.margin/markup/, kept out of git) so Claude can Read it."""
        cwd = self._cwd_cache.get(session_id)
        if cwd is None:
            raise KeyError(session_id)
        return save_markup_in(cwd, data)

    async def shutdown(self) -> None:
        tasks = [s.task for s in self.live.values() if s.task]
        for t in tasks:
            t.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)

    # -- reading ----------------------------------------------------------
    async def list(self, project: str | None = None, limit: int = 50) -> list[dict[str, Any]]:
        projects = [self.ws.project(project)] if project else self.ws.projects

        def _collect() -> list[dict[str, Any]]:
            out: dict[str, dict[str, Any]] = {}
            now = time.time()
            for p in projects:
                try:
                    infos = list_sessions(directory=p.path, limit=limit)
                except Exception:
                    log.exception("list_sessions failed for %s", p.path)
                    continue
                for i in infos:
                    modified = (i.last_modified or 0) / 1000.0
                    out[i.session_id] = {
                        "session_id": i.session_id,
                        "project": p.name,
                        "title": i.custom_title or i.summary or i.first_prompt or "(untitled)",
                        "first_prompt": i.first_prompt,
                        "git_branch": i.git_branch,
                        "cwd": i.cwd or p.path,
                        "last_modified": modified,
                        "created_at": (i.created_at or 0) / 1000.0 or None,
                    }
                    self._cwd_cache[i.session_id] = i.cwd or p.path
                    # Written lately, and not by the daemon this replaced: its Claude
                    # processes can write their last lines a few seconds after a restart.
                    out[i.session_id]["_recent"] = (now - modified < ACTIVE_ELSEWHERE_SECONDS
                                                    and modified > self.started_at + ACTIVE_ELSEWHERE_SECONDS)
            return list(out.values())

        rows = await asyncio.to_thread(_collect)
        # Overlay live state
        for sid, sess in self.live.items():
            row = next((r for r in rows if r["session_id"] == sid), None)
            if row is None:
                row = {"session_id": sid, "project": sess.project, "title": "(new session)",
                       "cwd": sess.cwd, "last_modified": sess.last_activity,
                       "created_at": sess.started_at, "_recent": False}
                rows.append(row)
            row["status"] = sess.status
        for r in rows:
            recent = r.pop("_recent", False)
            r.setdefault("status", "active_elsewhere" if recent else "stored")
            r["pending_permissions"] = sum(1 for p in self.pending.values()
                                           if p.session_id == r["session_id"] and p.proposal_id is None)
            if (prop := self.proposals.latest(r["session_id"])) is not None:
                r["proposal"] = {"id": prop.id, "status": prop.status, "version": prop.version}
        rows.sort(key=lambda r: r.get("last_modified") or 0, reverse=True)
        return rows[:limit]

    async def history(self, session_id: str, limit: int = 400) -> list[dict[str, Any]]:
        cwd = await self._find_cwd(session_id)

        def _read() -> list[dict[str, Any]]:
            msgs = get_session_messages(session_id, directory=cwd)
            items: list[dict[str, Any]] = []
            for m in msgs[-limit:]:
                for it in normalize.from_history(m.type, m.message):
                    it["parent_tool_use_id"] = m.parent_tool_use_id
                    items.append(it)
            return items

        return await asyncio.to_thread(_read)

    async def _find_cwd(self, session_id: str) -> str | None:
        if session_id in self._cwd_cache:
            return self._cwd_cache[session_id]

        def _search() -> str | None:
            for p in self.ws.projects:
                try:
                    info = get_session_info(session_id, directory=p.path)
                except Exception:
                    info = None
                if info:
                    return info.cwd or p.path
            return None

        cwd = await asyncio.to_thread(_search)
        if cwd:
            self._cwd_cache[session_id] = cwd
        return cwd

    def pending_list(self) -> list[dict[str, Any]]:
        return [p.public() for p in self.pending.values() if p.proposal_id is None]


def _doing(tool: str, args: dict[str, Any]) -> tuple[str, str]:
    """A tool call as a few words: ("Editing", "src/app.py")."""
    path = str(args.get("file_path") or args.get("notebook_path") or args.get("path") or "")
    short = os.path.basename(path) if path else ""
    verbs = {"Read": "Reading", "Edit": "Editing", "MultiEdit": "Editing", "Write": "Writing",
             "NotebookEdit": "Editing", "Glob": "Searching", "Grep": "Searching", "WebFetch": "Reading the web",
             "WebSearch": "Searching the web", "Task": "Running an agent", "Agent": "Running an agent",
             "TodoWrite": "Planning", "ExitPlanMode": "Presenting a plan"}
    if tool == "Bash":
        return "Running", str(args.get("description") or args.get("command") or "")[:80]
    if tool in ("Grep", "Glob"):
        return "Searching", str(args.get("pattern") or "")[:80]
    if tool in ("WebSearch",):
        return verbs[tool], str(args.get("query") or "")[:80]
    if tool in ("Task", "Agent"):
        return verbs[tool], str(args.get("description") or "")[:80]
    if tool.startswith("mcp__margin__"):
        return "Updating Margin", tool.removeprefix("mcp__margin__").replace("_", " ")
    return verbs.get(tool, tool), short


def _git_exclude(start: str, pattern: str) -> None:
    d = os.path.abspath(start)
    while True:
        git = os.path.join(d, ".git")
        if os.path.isdir(git):
            ex = os.path.join(git, "info", "exclude")
            os.makedirs(os.path.dirname(ex), exist_ok=True)
            existing = open(ex, encoding="utf-8").read() if os.path.exists(ex) else ""
            if pattern not in existing.splitlines():
                with open(ex, "a", encoding="utf-8") as f:
                    f.write(("" if existing.endswith("\n") or not existing else "\n") + pattern + "\n")
            return
        parent = os.path.dirname(d)
        if parent == d:
            return
        d = parent


def apply_workspace_env(ws: WorkspaceConfig) -> None:
    """The SDK's list/get helpers read CLAUDE_CONFIG_DIR from os.environ, so a
    workspace daemon sets it for its own process at startup."""
    if ws.claude_config_dir:
        os.environ["CLAUDE_CONFIG_DIR"] = os.path.expanduser(ws.claude_config_dir)


def save_markup_in(cwd: str, data: bytes) -> str:
    """Write a markup image under <cwd>/.margin/markup/; returns its absolute path."""
    if not data.startswith(b"\x89PNG") and not data.startswith(b"\xff\xd8"):
        raise ValueError("markup must be a PNG or JPEG")
    d = os.path.join(cwd, ".margin", "markup")
    os.makedirs(d, exist_ok=True)
    name = time.strftime("%Y%m%d-%H%M%S-") + uuid.uuid4().hex[:6] + (".png" if data[:1] == b"\x89" else ".jpg")
    with open(os.path.join(d, name), "wb") as f:
        f.write(data)
    _git_exclude(cwd, ".margin/")
    # Absolute: the session's shell may have moved to a subfolder.
    return os.path.join(os.path.realpath(d), name)


def _tool_text(text: str, error: bool = False) -> dict[str, Any]:
    return {"content": [{"type": "text", "text": text}], **({"is_error": True} if error else {})}
