"""Plan-mode proposals: review loop, decisions after restarts, markup uploads."""
import asyncio
import os
import tempfile

from claude_agent_sdk import (
    AssistantMessage,
    PermissionResultAllow,
    PermissionResultDeny,
    ResultMessage,
    TextBlock,
    ToolPermissionContext,
)

from margind.events import EventBus
from margind.proposals import ProposalStore
from margind.sessions import SessionManager
from test_sessions import make_ws

PLAN_V1 = "# Plan: move the USB connector\n\n## 1. Move J1\nShift it 2 mm left."
PLAN_V2 = "# Plan: move the USB connector\n\n## 1. Move J1\nShift it 3 mm left."


class PlanClient:
    """Presents a plan; if sent back, presents v2; once approved, finishes."""
    instances: list["PlanClient"] = []

    def __init__(self, options):
        self.options = options
        self.results: list = []
        self.modes: list[str] = []
        self.asked: asyncio.Queue = asyncio.Queue()
        PlanClient.instances.append(self)

    async def connect(self): pass
    async def disconnect(self): pass
    async def interrupt(self): pass
    async def query(self, prompt):
        self.prompt = prompt
        self.asked.put_nowait(prompt)

    async def receive_messages(self):
        while True:
            await self.asked.get()
            async for m in self.receive_response():
                yield m
    async def set_permission_mode(self, mode): self.modes.append(mode)

    async def receive_response(self):
        for plan in (PLAN_V1, PLAN_V2):
            r = await self.options.can_use_tool("ExitPlanMode", {"plan": plan}, ToolPermissionContext(suggestions=[]))
            self.results.append(r)
            if isinstance(r, PermissionResultAllow):
                break
        yield AssistantMessage(content=[TextBlock(text="Moved J1.")], model="fake")
        yield ResultMessage(subtype="success", duration_ms=1, duration_api_ms=1, is_error=False,
                            num_turns=3, session_id="x", result="Moved J1 3 mm left; DRC clean.")


async def wait(pred, timeout=2.0):
    end = asyncio.get_running_loop().time() + timeout
    while asyncio.get_running_loop().time() < end:
        if (v := pred()):
            return v
        await asyncio.sleep(0.01)
    raise AssertionError("condition not met")


def test_review_loop_send_back_then_approve_with_notes():
    PlanClient.instances.clear()

    async def run():
        with tempfile.TemporaryDirectory() as tmp:
            ws = make_ws(tmp)
            bus = EventBus()
            mgr = SessionManager(ws, bus, client_factory=PlanClient)
            sid = await mgr.start("pcb", "move the usb connector", "plan")

            v1 = await wait(lambda: mgr.proposals.latest(sid))
            assert v1.version == 1 and v1.title == "move the USB connector" and v1.status == "pending"
            assert mgr.pending_list() == []            # plans aren't shown as approval cards
            await mgr.decide_proposal(v1.id, "revise", "On 1: 3 mm, not 2.")

            v2 = await wait(lambda: (p := mgr.proposals.latest(sid)) and p.version == 2 and p)
            assert mgr.proposals.items[v1.id].status == "revise"
            await mgr.decide_proposal(v2.id, "approve", "Re-run DRC after.")

            done = await wait(lambda: (p := mgr.proposals.items[v2.id]).status == "done" and p)
            assert done.outcome.startswith("Moved J1") and done.feedback == "Re-run DRC after."

            sent_back, approved = PlanClient.instances[0].results
            assert isinstance(sent_back, PermissionResultDeny) and "3 mm, not 2" in sent_back.message
            assert isinstance(approved, PermissionResultAllow)
            assert approved.updated_input["plan"].endswith("Re-run DRC after.")
            assert approved.updated_permissions[0].mode == "auto"

            # survives a restart, without the live request
            again = ProposalStore.load(ws.state_path / "proposals.json")
            assert again.items[v2.id].status == "done" and again.items[v2.id].request_id is None
            await mgr.shutdown()

    asyncio.run(run())


def test_decision_after_restart_resumes_the_session():
    async def run():
        with tempfile.TemporaryDirectory() as tmp:
            ws = make_ws(tmp)
            mgr = SessionManager(ws, EventBus(), client_factory=PlanClient)
            p = mgr.proposals.add("sess-1", "pcb", PLAN_V1, request_id=None)   # as if loaded after restart
            mgr._cwd_cache["sess-1"] = ws.projects[0].path
            sent = []

            async def fake_send(session_id, text, permission_mode=None):
                sent.append((session_id, text, permission_mode))
            mgr.send = fake_send
            await mgr.decide_proposal(p.id, "approve", "Keep the old footprint.")
            assert sent[0][2] == "auto" and "Keep the old footprint." in sent[0][1]
            try:
                await mgr.decide_proposal(p.id, "revise", "x")
                raise AssertionError("second decision should fail")
            except ValueError:
                pass

    asyncio.run(run())


def test_markup_lands_in_project_and_is_git_excluded():
    with tempfile.TemporaryDirectory() as tmp:
        ws = make_ws(tmp)
        root = ws.projects[0].path
        os.makedirs(os.path.join(root, ".git", "info"))
        mgr = SessionManager(ws, EventBus())
        mgr._cwd_cache["s"] = root
        rel = mgr.save_markup("s", b"\x89PNG\r\n\x1a\nrest")
        assert os.path.isabs(rel) and os.sep + os.path.join(".margin", "markup", "") in rel and os.path.isfile(rel)
        mgr.save_markup("s", b"\x89PNG\r\n\x1a\nagain")
        assert open(os.path.join(root, ".git", "info", "exclude")).read().count(".margin/") == 1
        try:
            mgr.save_markup("s", b"<svg/>")
            raise AssertionError("non-image accepted")
        except ValueError:
            pass


def test_approved_plan_commands_run_without_asking():
    plan = PLAN_V1 + "\n\n## Commands I'll run\n```\npython3 check.py\n```\n"

    class ScopedClient(PlanClient):
        async def receive_response(self):
            r = await self.options.can_use_tool("ExitPlanMode", {"plan": plan}, ToolPermissionContext(suggestions=[]))
            self.results.append(r)
            self.results.append(await self.options.can_use_tool(
                "Bash", {"command": "python3 check.py && git diff"}, ToolPermissionContext(suggestions=[])))
            yield ResultMessage(subtype="success", duration_ms=1, duration_api_ms=1, is_error=False,
                                num_turns=1, session_id="x", result="ok")

    async def run():
        with tempfile.TemporaryDirectory() as tmp:
            ws = make_ws(tmp)
            mgr = SessionManager(ws, EventBus(), client_factory=ScopedClient)
            sid = await mgr.start("pcb", "go", "plan")
            p = await wait(lambda: mgr.proposals.latest(sid))
            assert p.commands == ["python3 check.py"]
            await mgr.decide_proposal(p.id, "approve")
            await wait(lambda: mgr.proposals.items[p.id].status == "done")
            client = ScopedClient.instances[-1]
            assert isinstance(client.results[1], PermissionResultAllow)   # no approval card
            await mgr.shutdown()

    asyncio.run(run())
