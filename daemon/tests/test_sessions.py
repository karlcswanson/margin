"""Session manager tests with a fake Agent SDK client (no Claude calls)."""
import asyncio
import os
import sys
import tempfile

import pytest

from claude_agent_sdk import (
    AssistantMessage,
    PermissionResultAllow,
    PermissionResultDeny,
    ResultMessage,
    TextBlock,
    ToolPermissionContext,
    ToolUseBlock,
)

from margind import files
from margind.config import Project, WorkspaceConfig
from margind.events import EventBus
from margind.sessions import SessionManager


class FakeClient:
    instances: list["FakeClient"] = []

    def __init__(self, options):
        self.options = options
        self.prompts: list[str] = []
        self.decisions: list = []
        self.connected = False
        self.asked: asyncio.Queue = asyncio.Queue()
        FakeClient.instances.append(self)

    async def connect(self):
        self.connected = True

    async def disconnect(self):
        self.connected = False

    async def interrupt(self):
        pass

    async def query(self, prompt):
        self.prompts.append(prompt)
        self.asked.put_nowait(prompt)

    async def receive_messages(self):
        # The SDK's stream: one reply per prompt, for as long as it's connected.
        while True:
            await self.asked.get()
            async for m in self.receive_response():
                yield m

    async def receive_response(self):
        yield AssistantMessage(content=[TextBlock(text="Looking at the board."),
                                        ToolUseBlock(id="t1", name="Bash", input={"command": "kicad-cli pcb drc x"})],
                               model="fake")
        decision = await self.options.can_use_tool("Bash", {"command": "kicad-cli pcb drc x"},
                                                   ToolPermissionContext(suggestions=[]))
        self.decisions.append(decision)
        yield ResultMessage(subtype="success", duration_ms=10, duration_api_ms=5, is_error=False,
                            num_turns=1, session_id="x", result="DRC clean.\nmore", total_cost_usd=0.01)


def make_ws(tmp: str) -> WorkspaceConfig:
    proj = os.path.join(tmp, "proj")
    os.makedirs(os.path.join(proj, "sub"))
    open(os.path.join(proj, "board.kicad_pcb"), "w").write("(kicad_pcb)")
    open(os.path.join(proj, ".env"), "w").write("SECRET=1")
    return WorkspaceConfig(name="Personal", tokens=["t"], projects=[Project("pcb", proj)],
                           state_dir=os.path.join(tmp, "state"))


async def _wait_for(bus_events, pred, timeout=2.0):
    end = asyncio.get_running_loop().time() + timeout
    while asyncio.get_running_loop().time() < end:
        for e in bus_events():
            if pred(e):
                return e
        await asyncio.sleep(0.01)
    raise AssertionError("event not seen")


def test_full_turn_with_approval():
    FakeClient.instances.clear()

    async def run():
        with tempfile.TemporaryDirectory() as tmp:
            ws = make_ws(tmp)
            bus = EventBus()
            notes = []

            async def notifier(p):
                notes.append(p)

            mgr = SessionManager(ws, bus, client_factory=FakeClient, notifier=notifier)
            sid = await mgr.start("pcb", "run DRC", permission_mode="default")
            events = lambda: bus.replay(0)

            req = await _wait_for(events, lambda e: e["type"] == "permission.request")
            assert req["tool_name"] == "Bash" and req["session_id"] == sid
            assert any(n["kind"] == "permission" for n in notes)
            assert mgr.live[sid].status == "waiting"

            mgr.resolve_permission(req["request_id"], "allow")
            res = await _wait_for(events, lambda e: e["type"] == "session.result")
            assert res["result"].startswith("DRC clean")
            assert notes[-1]["kind"] == "result" and notes[-1]["body"] == "DRC clean."

            client = FakeClient.instances[-1]
            assert isinstance(client.decisions[0], PermissionResultAllow)
            assert client.options.session_id == sid and client.options.resume is None
            assert client.options.cwd == ws.projects[0].path
            kinds = [i["kind"] for e in events() if e["type"] == "session.items" for i in e["items"]]
            assert kinds == ["user_text", "text", "tool_use"]

            # second turn reuses the live client
            await mgr.send(sid, "now export gerbers")
            req2 = await _wait_for(events, lambda e: e["type"] == "permission.request" and e["request_id"] != req["request_id"])
            mgr.resolve_permission(req2["request_id"], "deny", "not yet")
            await _wait_for(events, lambda e: e["type"] == "session.result" and e["seq"] > res["seq"])
            assert isinstance(client.decisions[1], PermissionResultDeny)
            assert client.decisions[1].message == "not yet"
            assert len(FakeClient.instances) == 1

            await mgr.shutdown()
            assert sid not in mgr.live
    asyncio.run(run())


class EarlyResultClient(FakeClient):
    """Answers a prompt with an empty result first and does the work after
    it, then carries on by itself later (a background command finishing)."""

    async def receive_response(self):
        yield ResultMessage(subtype="success", duration_ms=61, duration_api_ms=0, is_error=False,
                            num_turns=0, session_id="x", result="")
        yield AssistantMessage(content=[TextBlock(text="Checking the page.")], model="fake")
        yield ResultMessage(subtype="success", duration_ms=10, duration_api_ms=5, is_error=False,
                            num_turns=2, session_id="x", result="It is the new repo's page.")
        await asyncio.sleep(0.05)
        yield AssistantMessage(content=[TextBlock(text="The build finished.")], model="fake")
        yield ResultMessage(subtype="success", duration_ms=10, duration_api_ms=5, is_error=False,
                            num_turns=1, session_id="x", result="Build passed.")


def test_reply_after_an_early_empty_result_still_arrives():
    async def run():
        with tempfile.TemporaryDirectory() as tmp:
            bus = EventBus()
            notes = []

            async def notifier(p):
                notes.append(p)

            mgr = SessionManager(make_ws(tmp), bus, client_factory=EarlyResultClient, notifier=notifier)
            sid = await mgr.start("pcb", "which page is this?", permission_mode="default")
            events = lambda: bus.replay(0)
            await _wait_for(events, lambda e: e["type"] == "session.result" and e["result"] == "Build passed.")
            texts = [i.get("text") for e in events() if e["type"] == "session.items" for i in e["items"]]
            assert texts == ["which page is this?", "Checking the page.", "The build finished."]
            results = [e["result"] for e in events() if e["type"] == "session.result"]
            assert results == ["It is the new repo's page.", "Build passed."]       # the empty one isn't announced
            assert [n["body"] for n in notes if n["kind"] == "result"] == ["It is the new repo's page.", "Build passed."]
            statuses = [e["status"] for e in events() if e["type"] == "session.status"]
            assert statuses[-2:] == ["running", "idle"] and mgr.live[sid].turn is None
            assert statuses[0] == "running"     # its first message was waiting: no "Ready" flash before it
            await mgr.shutdown()
    asyncio.run(run())


def test_resume_stored_session_uses_resume_option():
    async def run():
        with tempfile.TemporaryDirectory() as tmp:
            ws = make_ws(tmp)
            bus = EventBus()
            mgr = SessionManager(ws, bus, client_factory=FakeClient)
            mgr._cwd_cache["old-session"] = ws.projects[0].path + "/sub"
            await mgr.send("old-session", "continue")
            await _wait_for(lambda: bus.replay(0), lambda e: e["type"] == "permission.request")
            client = FakeClient.instances[-1]
            assert client.options.resume == "old-session" and client.options.session_id is None
            assert mgr.live["old-session"].project == "pcb"
            await mgr.shutdown()
    asyncio.run(run())


def test_file_access_is_confined():
    with tempfile.TemporaryDirectory() as tmp:
        ws = make_ws(tmp)
        names = [e["name"] for e in files.listing(ws, "pcb")]
        assert names == ["sub", "board.kicad_pcb"]          # dirs first, .env hidden
        assert files.listing(ws, "pcb")[1]["kind"] == "kicad"
        for bad in ("../../etc/passwd", ".env", "sub/../../x"):
            try:
                files.resolve(ws, "pcb", bad)
            except files.PathError:
                continue
            raise AssertionError(f"{bad} was allowed")


def test_event_replay():
    bus = EventBus(buffer_size=3)
    for i in range(5):
        bus.publish("x", i=i)
    assert [e["i"] for e in bus.replay(0)] == [2, 3, 4]
    assert [e["i"] for e in bus.replay(4)] == [4]


def test_interrupt_refuses_the_waiting_approval():
    FakeClient.instances.clear()

    async def run():
        with tempfile.TemporaryDirectory() as tmp:
            bus = EventBus()
            mgr = SessionManager(make_ws(tmp), bus, client_factory=FakeClient)
            sid = await mgr.start("pcb", "run DRC", permission_mode="default")
            events = lambda: bus.replay(0)
            await _wait_for(events, lambda e: e["type"] == "permission.request")

            await mgr.interrupt(sid)
            await _wait_for(events, lambda e: e["type"] == "session.result")
            decision = FakeClient.instances[-1].decisions[0]
            assert isinstance(decision, PermissionResultDeny) and decision.interrupt
            assert mgr.pending_list() == []
            assert any(e["type"] == "permission.resolved" for e in events())
            await mgr.shutdown()
    asyncio.run(run())


def test_messages_sent_while_working_queue_and_go_together():
    async def run():
        with tempfile.TemporaryDirectory() as tmp:
            bus = EventBus()
            mgr = SessionManager(make_ws(tmp), bus, client_factory=FakeClient)
            sid = await mgr.start("pcb", "run DRC", permission_mode="default")
            events = lambda: bus.replay(0)
            req = await _wait_for(events, lambda e: e["type"] == "permission.request")

            await mgr.send(sid, "also check the silkscreen")
            await mgr.send(sid, "and the drill sizes")
            await mgr.send(sid, "never mind this one")
            q = mgr.queue_of(sid)
            assert [x["text"] for x in q] == ["also check the silkscreen", "and the drill sizes", "never mind this one"]
            mgr.cancel_queued(sid, q[2]["id"])
            texts = lambda: [i["text"] for e in events() if e["type"] == "session.items"
                             for i in e["items"] if i["kind"] == "user_text"]
            assert texts() == ["run DRC"]                  # queued ones aren't in the transcript yet

            mgr.resolve_permission(req["request_id"], "allow")
            await _wait_for(events, lambda e: e["type"] == "permission.request" and e["request_id"] != req["request_id"])
            client = FakeClient.instances[-1]
            assert client.prompts[-1] == "also check the silkscreen\n\nand the drill sizes"
            assert texts() == ["run DRC", "also check the silkscreen", "and the drill sizes"]
            assert mgr.queue_of(sid) == []
            await mgr.shutdown()
    asyncio.run(run())


def test_relative_media_paths_resolve_from_root_or_a_moved_shell():
    with tempfile.TemporaryDirectory() as tmp:
        ws = make_ws(tmp)
        root = ws.projects[0].path
        os.makedirs(os.path.join(root, "enclosure", "v4"))
        open(os.path.join(root, "enclosure", "v4", "case.stl"), "w").write("solid")
        sub = os.path.join(root, "sub")
        # Relative to the project root while the session sat in a subfolder
        assert files.resolve_any(ws, "enclosure/v4/case.stl", sub).name == "case.stl"
        # Relative to a folder the shell moved into
        assert files.resolve_any(ws, "v4/case.stl", root).name == "case.stl"
        # Two copies (repo/ and an older station/): the one changed most recently
        for d in ("station", "repo"):
            os.makedirs(os.path.join(root, d, "web"))
            open(os.path.join(root, d, "web", "verify.js"), "w").write(d)
        os.utime(os.path.join(root, "station", "web", "verify.js"), (1, 1))
        assert files.resolve_any(ws, "web/verify.js", root).parent.parent.name == "repo"


class QuietClient(FakeClient):
    """Answers without asking for anything; records mode/model switches."""
    switches: list = []

    async def set_permission_mode(self, mode):
        QuietClient.switches.append(("mode", mode))

    async def set_model(self, model):
        QuietClient.switches.append(("model", model))

    async def get_server_info(self):
        return {"models": [{"value": "sonnet", "displayName": "Sonnet", "supportedEffortLevels": ["low"]}]}

    async def receive_response(self):
        yield ResultMessage(subtype="success", duration_ms=1, duration_api_ms=1, is_error=False,
                            num_turns=1, session_id="x", result="ok", total_cost_usd=0.0)


def test_settings_switch_live_and_persist():
    FakeClient.instances.clear()
    QuietClient.switches.clear()

    async def run():
        with tempfile.TemporaryDirectory() as tmp:
            ws = make_ws(tmp)
            bus = EventBus()
            mgr = SessionManager(ws, bus, client_factory=QuietClient)
            sid = await mgr.start("pcb", "hello")
            events = lambda: bus.replay(0)
            await _wait_for(events, lambda e: e["type"] == "session.result")
            s = await mgr.update_settings(sid, permission_mode="auto", model="sonnet", effort="low")
            assert s["permission_mode"] == "auto" and s["model"] == "sonnet" and s["effort"] == "low"
            assert s["models"][0]["value"] == "sonnet"
            assert ("mode", "auto") in QuietClient.switches and ("model", "sonnet") in QuietClient.switches
            # Effort needs a new connection: the next message reconnects, resuming, with it.
            await mgr.send(sid, "again")
            await _wait_for(events, lambda e: e["type"] == "session.result" and len(FakeClient.instances) == 2
                            and len(FakeClient.instances[-1].prompts) == 1)
            last = FakeClient.instances[-1].options
            assert last.effort == "low" and last.model == "sonnet" and last.resume == sid
            # A fresh manager (daemon restart) remembers the choices.
            mgr2 = SessionManager(ws, EventBus(), client_factory=QuietClient)
            again = mgr2.settings(sid)
            assert again["permission_mode"] == "auto" and again["model"] == "sonnet"
            for sess in list(mgr.live.values()):
                sess.task.cancel()

    asyncio.run(run())


def test_claude_publishes_pages_for_its_project():
    from margind.sessions import LiveSession

    async def run():
        with tempfile.TemporaryDirectory() as tmp:
            ws = make_ws(tmp)
            bus = EventBus()
            mgr = SessionManager(ws, bus, client_factory=FakeClient)
            sess = LiveSession(mgr, "s1", "pcb", ws.projects[0].path, resume=False, permission_mode="default")
            tools = {t.name: t for t in sess.margin_tools()}
            publish, unpublish = tools["publish_page"], tools["unpublish_page"]
            opts = sess.options()
            assert "margin" in opts.mcp_servers and "mcp__margin__publish_page" in opts.allowed_tools
            assert opts.mcp_servers["margin"]["alwaysLoad"] is True        # not deferred behind tool search

            r = await publish.handler({"name": "Dashboard", "url": "http://localhost:5173/owner?x=1",
                                       "description": "the owner page"})
            assert "is_error" not in r
            r = await publish.handler({"name": "Elsewhere", "url": "https://example.com/"})
            assert r["is_error"]
            r = await publish.handler({"name": "dashboard", "url": "http://127.0.0.1:5174/"})   # same name: updated
            pages = mgr.published.list("pcb")
            assert [(p["name"], p["port"], p["path"]) for p in pages] == [("dashboard", 5174, "/")]
            assert pages[0]["alive"] is False
            ev = [e for e in bus.replay(0) if e["type"] == "published"][-1]
            assert ev["project"] == "pcb" and ev["pages"][0]["name"] == "dashboard"
            # kept across restarts
            assert SessionManager(ws, EventBus(), client_factory=FakeClient).published.list("pcb")[0]["port"] == 5174
            assert "is_error" not in await unpublish.handler({"name": "Dashboard"})
            assert mgr.published.list("pcb") == []

    asyncio.run(run())


@pytest.mark.skipif(sys.platform == "win32", reason="runs a POSIX shell command in a terminal")
def test_buttons_claude_sets_up_and_the_user_runs():
    from fastapi.testclient import TestClient

    from margind.server import create_app
    from margind.sessions import LiveSession

    with tempfile.TemporaryDirectory() as tmp:
        ws = make_ws(tmp)
        ws.terminal_screen = False
        bus = EventBus()
        mgr = SessionManager(ws, bus, client_factory=FakeClient)
        with TestClient(create_app(ws, manager=mgr, bus=bus)) as c:
            H = {"Authorization": "Bearer t"}
            sess = LiveSession(mgr, "s1", "pcb", ws.projects[0].path, resume=False, permission_mode="default")
            tools = {t.name: t for t in sess.margin_tools()}

            async def call(name, args):
                return await tools[name].handler(args)

            assert "is_error" not in asyncio.run(call("set_action", {"label": "Say hi", "command": "echo hi-$((40+2))",
                                                                     "icon": "bolt", "description": "greets"}))
            assert asyncio.run(call("set_action", {"label": "Both", "command": "x", "prompt": "y"}))["is_error"]
            assert asyncio.run(call("set_action", {"label": "Out", "command": "x", "cwd": "../.."}))["is_error"]
            listed = c.get("/v1/actions?project=pcb", headers=H).json()
            assert [(a["label"], a["kind"], a["icon"]) for a in listed] == [("Say hi", "run", "bolt")]
            assert ".margin/" in open(os.path.join(ws.projects[0].path, ".git", "info", "exclude")).read() \
                if os.path.isdir(os.path.join(ws.projects[0].path, ".git")) else True

            # Running needs the version the user saw.
            body = {"project": "pcb", "label": "Say hi", "fingerprint": "stale"}
            assert c.post("/v1/actions/run", headers=H, json=body).status_code == 409
            body["fingerprint"] = listed[0]["fingerprint"]
            t = c.post("/v1/actions/run", headers=H, json=body).json()["terminal"]
            with c.websocket_connect(f"/v1/terminals/{t['id']}/stream", headers=H) as sock:
                sock.receive_json()
                got = b""
                while b"hi-42" not in got or b"[exit 0]" not in got:
                    m = sock.receive()
                    got += m.get("bytes") or b""
            assert c.delete("/v1/actions?project=pcb&label=Say%20hi", headers=H).json() == {"ok": True}
            assert c.get("/v1/actions?project=pcb", headers=H).json() == []


def test_claude_points_at_things_without_taking_over():
    from fastapi.testclient import TestClient

    from margind.server import create_app
    from margind.sessions import LiveSession

    with tempfile.TemporaryDirectory() as tmp:
        ws = make_ws(tmp)
        bus = EventBus()
        mgr = SessionManager(ws, bus, client_factory=FakeClient)
        sess = LiveSession(mgr, "s1", "pcb", ws.projects[0].path, resume=False, permission_mode="default")
        tools = {t.name: t for t in sess.margin_tools()}
        show, replies = tools["show"], tools["suggest_replies"]
        assert asyncio.run(show.handler({"title": "x"}))["is_error"]
        assert asyncio.run(show.handler({"title": "x", "file": "nope.png"}))["is_error"]
        assert asyncio.run(show.handler({"title": "x", "file": "board.kicad_pcb", "url": "http://localhost:1/"}))["is_error"]
        assert "is_error" not in asyncio.run(show.handler({"title": "Board", "file": "board.kicad_pcb"}))
        assert "is_error" not in asyncio.run(show.handler({"title": "Page", "url": "http://localhost:5173/x"}))
        assert "is_error" not in asyncio.run(show.handler({"title": "Lines", "file": "board.kicad_pcb", "line": 3, "end_line": 1}))
        assert "is_error" not in asyncio.run(show.handler({"title": "Diff", "changes": "board.kicad_pcb"}))
        kinds = [(o["kind"], o.get("line"), o.get("end_line")) for o in mgr.shows["s1"]]
        # pointing at the same file again replaced the first one; all are kept, oldest first
        assert kinds == [("page", None, None), ("file", 3, 3), ("changes", None, None)]

        # Offering replies without having answered: told to write the answer.
        sess._begin_turn()
        r = asyncio.run(replies.handler({"options": ["Yes, ship it", " ", "No"]}))
        assert "is_error" not in r and "haven't answered" in r["content"][0]["text"]
        assert mgr.replies["s1"] == ["Yes, ship it", "No"]
        # A line before running a command isn't the answer either.
        sess._track(AssistantMessage(content=[TextBlock(text="I'm looking now."),
                                              ToolUseBlock(id="t1", name="Bash", input={"command": "go version"})],
                                     model="m", message_id="b"))
        assert "haven't answered" in asyncio.run(replies.handler({"options": ["Yes"]}))["content"][0]["text"]
        sess._track(AssistantMessage(content=[TextBlock(text="It needs Go 1.25.")], model="m", message_id="c"))
        r = asyncio.run(replies.handler({"options": ["Yes, ship it", "No"]}))
        assert "haven't answered" not in r["content"][0]["text"]
        sess._end_turn()

        with TestClient(create_app(ws, manager=mgr, bus=bus)) as c:
            H = {"Authorization": "Bearer t"}
            h = c.get("/v1/sessions/s1/messages", headers=H).json()
            assert len(h["shows"]) == 3 and h["replies"] == ["Yes, ship it", "No"]
            first = mgr.shows["s1"][0]["id"]
            c.delete(f"/v1/sessions/s1/show?id={first}", headers=H)
            assert len(mgr.shows["s1"]) == 2
            c.delete("/v1/sessions/s1/show", headers=H)
            assert "s1" not in mgr.shows
            assert [e["shows"] for e in bus.replay(0) if e["type"] == "session.show"][-1] == []



def test_what_claude_is_doing_like_the_spinner_line():
    from margind.sessions import LiveSession

    with tempfile.TemporaryDirectory() as tmp:
        ws = make_ws(tmp)
        bus = EventBus()
        mgr = SessionManager(ws, bus, client_factory=FakeClient)
        sess = LiveSession(mgr, "s1", "pcb", ws.projects[0].path, resume=False, permission_mode="default")
        sess._begin_turn()
        assert sess.turn["doing"] == "Thinking" and sess.turn["tokens"] == 0
        use = {"output_tokens": 120}
        # one API message split into two blocks with the same usage: counted once
        sess._track(AssistantMessage(content=[TextBlock(text="Checking")], model="m", usage=use, message_id="a"))
        sess._track(AssistantMessage(content=[ToolUseBlock(id="t", name="Edit", input={"file_path": "/x/src/app.py"})],
                                     model="m", usage=use, message_id="a"))
        assert (sess.turn["doing"], sess.turn["detail"], sess.turn["tokens"]) == ("Editing", "app.py", 120)
        sess._track(AssistantMessage(content=[ToolUseBlock(id="u", name="Bash", input={"command": "make", "description": "Build it"})],
                                     model="m", usage={"output_tokens": 30}, message_id="b"))
        assert (sess.turn["doing"], sess.turn["detail"], sess.turn["tokens"]) == ("Running", "Build it", 150)
        sess._end_turn()
        acts = [e["activity"] for e in bus.replay(0) if e["type"] == "session.activity"]
        assert acts[0]["doing"] == "Thinking" and acts[-1] is None
