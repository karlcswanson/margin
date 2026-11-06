"""STEP -> margin-parts JSON: packing, caching and the route with a stub
worker, plus one real conversion when an OpenCascade Python is on this host."""
import asyncio
import base64
import json
import os
import subprocess
import sys
import tempfile
import textwrap
from array import array
from pathlib import Path

import pytest

fastapi = pytest.importorskip("fastapi")
from fastapi.testclient import TestClient  # noqa: E402

from margind import step, step_worker  # noqa: E402
from margind.events import EventBus  # noqa: E402
from margind.render import RenderError  # noqa: E402
from margind.server import create_app  # noqa: E402
from margind.sessions import SessionManager  # noqa: E402
from test_sessions import FakeClient, make_ws  # noqa: E402

H = {"Authorization": "Bearer t"}


def floats(s: str) -> list[float]:
    a = array("f", base64.b64decode(s))
    if sys.byteorder == "big":
        a.byteswap()
    return list(a)


def uints(s: str) -> list[int]:
    a = array("I", base64.b64decode(s))
    if sys.byteorder == "big":
        a.byteswap()
    return list(a)


def test_pack_groups_names_and_little_endian():
    red, blue = (1.0, 0.0, 0.0, 1.0), (0.0, 0.0, 1.0, 0.5)
    bolt = step_worker.Part("Bolt", red)
    p, n, i = bolt.bucket(None)                       # part colour
    p.extend([0, 0, 0, 1, 0, 0, 0, 1, 0])
    n.extend([0, 0, 1] * 3)
    i.extend([0, 1, 2])
    p, n, i = bolt.bucket(blue)                       # a face with its own colour, bigger
    p.extend([0, 0, 1, 1, 0, 1, 0, 1, 1, 1, 1, 1])
    n.extend([0, 0, 1] * 4)
    i.extend([0, 1, 2, 1, 3, 2])
    empty = step_worker.Part("Washer", red)           # no triangles: dropped
    data = step_worker.pack([bolt, empty, step_worker.Part("Bolt", red), bolt_copy(bolt)])
    assert data["format"] == "margin-parts/1" and data["units"] == "mm"
    assert [x["name"] for x in data["parts"]] == ["Bolt", "Bolt 2"]
    first = data["parts"][0]
    assert first["color"] == [0.0, 0.0, 1.0, 0.5]     # dominant group's colour
    assert first["groups"] == [{"color": [0.0, 0.0, 1.0, 0.5], "start": 0, "count": 6},
                               {"color": [1.0, 0.0, 0.0, 1.0], "start": 6, "count": 3}]
    pos, nrm, idx = floats(first["positions"]), floats(first["normals"]), uints(first["indices"])
    assert len(pos) == len(nrm) == 7 * 3
    assert idx == [0, 1, 2, 1, 3, 2, 4, 5, 6]         # second bucket offset past the first
    assert base64.b64decode(first["indices"])[:8] == b"\0\0\0\0\1\0\0\0"
    json.dumps(data)


def bolt_copy(part):
    other = step_worker.Part(part.name, part.color)
    p, n, i = other.bucket(None)
    p.extend([0, 0, 0, 1, 0, 0, 0, 1, 0])
    n.extend([0, 0, 1] * 3)
    i.extend([0, 1, 2])
    return other


def test_names():
    assert step_worker.unique_names(["Bolt", "Nut", "Bolt", "Bolt"]) == ["Bolt", "Nut", "Bolt 2", "Bolt 3"]
    assert step_worker.meaningful("R4") and step_worker.meaningful("Bolt-1")
    for junk in (None, "", "=>[0:1:1:3]", "COMPOUND", "2", "Open CASCADE STEP translator 7.9 1"):
        assert not step_worker.meaningful(junk)


STUB = textwrap.dedent("""
    import json, sys
    src, out = sys.argv[-2:]
    if open(src).read().startswith("bad"):
        sys.exit("ISO-10303-21 header missing")
    with open(out + ".runs", "a") as f:
        f.write("x")
    json.dump({"format": "margin-parts/1", "units": "mm", "parts": []}, open(out, "w"))
""")


@pytest.fixture
def stub_worker(monkeypatch, tmp_path):
    worker = tmp_path / "worker.py"
    worker.write_text(STUB)
    monkeypatch.setattr(step, "WORKER", worker)
    monkeypatch.setattr(step, "_found", {None: sys.executable})
    return worker


def test_route_converts_once_and_caches(stub_worker):
    with tempfile.TemporaryDirectory() as tmp:
        ws = make_ws(tmp)
        root = ws.projects[0].path
        Path(root, "case.STEP").write_text("ISO-10303-21;")
        Path(root, "broken.stp").write_text("bad")
        with TestClient(create_app(ws, manager=SessionManager(ws, EventBus(), client_factory=FakeClient), bus=EventBus())) as c:
            assert c.get("/v1/info", headers=H).json()["step"] is True
            r = c.get("/v1/render", headers=H, params={"path": "case.STEP", "cwd": root, "view": "parts"})
            assert r.status_code == 200 and r.headers["content-type"].startswith("application/json")
            assert r.json() == {"format": "margin-parts/1", "units": "mm", "parts": []}
            r = c.get("/v1/render", headers=H, params={"path": "case.STEP", "cwd": root})   # default view
            assert r.status_code == 200
            runs = list((ws.state_path / "renders").glob("*.runs"))
            assert len(runs) == 1 and runs[0].read_text() == "x"                # converted once

            r = c.get("/v1/render", headers=H, params={"path": "case.STEP", "cwd": root, "view": "3d"})
            assert r.status_code == 422
            r = c.get("/v1/render", headers=H, params={"path": "broken.stp", "cwd": root})
            assert r.status_code == 422 and "header missing" in r.json()["detail"]
            assert not list((ws.state_path / "renders").glob("*.tmp.json"))


def test_without_opencascade_says_how_to_get_it(monkeypatch):
    monkeypatch.setattr(step, "_found", {None: None})
    with tempfile.TemporaryDirectory() as tmp:
        ws = make_ws(tmp)
        src = Path(ws.projects[0].path, "case.stp")
        src.write_text("ISO-10303-21;")
        with pytest.raises(RenderError, match="set cad_python"):
            asyncio.run(step.convert(ws, src))
        with TestClient(create_app(ws, manager=SessionManager(ws, EventBus(), client_factory=FakeClient), bus=EventBus())) as c:
            assert c.get("/v1/info", headers=H).json()["step"] is False
            r = c.get("/v1/render", headers=H, params={"path": str(src)})
            assert r.status_code == 422 and "cadquery-ocp" in r.json()["detail"]


def test_configured_python_without_ocp_is_rejected(monkeypatch):
    monkeypatch.setattr(step, "_found", {})
    monkeypatch.setattr(step, "_has_ocp", lambda py: False)
    with tempfile.TemporaryDirectory() as tmp:
        ws = make_ws(tmp)
        ws.cad_python = sys.executable
        assert step.cad_python(ws) is None
        assert step._found == {sys.executable: None}


# ---- real conversion ---------------------------------------------------------

MAKE_STEP = textwrap.dedent("""
    import sys
    from OCP.BRepPrimAPI import BRepPrimAPI_MakeBox
    from OCP.gp import gp_Trsf, gp_Vec
    from OCP.Quantity import Quantity_Color, Quantity_ColorRGBA, Quantity_TypeOfColor
    from OCP.STEPCAFControl import STEPCAFControl_Writer
    from OCP.STEPControl import STEPControl_AsIs
    from OCP.TCollection import TCollection_ExtendedString
    from OCP.TDataStd import TDataStd_Name
    from OCP.TDocStd import TDocStd_Document
    from OCP.TopLoc import TopLoc_Location
    from OCP.XCAFDoc import XCAFDoc_ColorSurf, XCAFDoc_DocumentTool

    doc = TDocStd_Document(TCollection_ExtendedString("XmlOcaf"))
    shapes = XCAFDoc_DocumentTool.ShapeTool_s(doc.Main())
    colors = XCAFDoc_DocumentTool.ColorTool_s(doc.Main())
    asm = shapes.NewShape()
    TDataStd_Name.Set_s(asm, TCollection_ExtendedString("pair"))
    for name, rgb, dx in (("Red box", (1, 0, 0), 0), ("Blue box", (0, 0, 1), 30)):
        label = shapes.AddShape(BRepPrimAPI_MakeBox(10, 10, 10).Shape(), False)
        TDataStd_Name.Set_s(label, TCollection_ExtendedString(name))
        colors.SetColor(label, Quantity_ColorRGBA(Quantity_Color(*rgb, Quantity_TypeOfColor.Quantity_TOC_sRGB), 1.0),
                        XCAFDoc_ColorSurf)
        t = gp_Trsf()
        t.SetTranslation(gp_Vec(dx, 0, 0))
        shapes.AddComponent(asm, label, TopLoc_Location(t))
    shapes.UpdateAssemblies()
    w = STEPCAFControl_Writer()
    w.SetColorMode(True)
    w.SetNameMode(True)
    assert w.Transfer(doc, STEPControl_AsIs)
    w.Write(sys.argv[1])
""")


def _ocp_python():
    step._found.pop(None, None)
    return step.cad_python()


@pytest.mark.skipif(not _ocp_python(), reason="no Python with OpenCascade (cadquery-ocp) on this host")
def test_real_step_two_coloured_boxes():
    with tempfile.TemporaryDirectory() as tmp:
        ws = make_ws(tmp)
        src = Path(ws.projects[0].path, "pair.step")
        subprocess.run([step.cad_python(), "-c", MAKE_STEP, str(src)], check=True, capture_output=True, timeout=120)
        out = asyncio.run(step.convert(ws, src))
        data = json.loads(out.read_text())
        assert data["format"] == "margin-parts/1" and data["units"] == "mm"
        parts = {p["name"]: p for p in data["parts"]}
        assert sorted(parts) == ["Blue box", "Red box"]
        assert parts["Red box"]["color"] == pytest.approx([1, 0, 0, 1], abs=0.01)
        assert parts["Blue box"]["color"] == pytest.approx([0, 0, 1, 1], abs=0.01)
        for p in parts.values():
            pos, nrm, idx = floats(p["positions"]), floats(p["normals"]), uints(p["indices"])
            assert len(pos) == len(nrm) and len(idx) == 12 * 3     # a box is 12 triangles
            assert max(idx) < len(pos) // 3
            v = [tuple(pos[3 * k:3 * k + 3]) for k in idx]
            volume = sum(a[0] * (b[1] * c[2] - b[2] * c[1]) - a[1] * (b[0] * c[2] - b[2] * c[0])
                         + a[2] * (b[0] * c[1] - b[1] * c[0]) for a, b, c in zip(v[0::3], v[1::3], v[2::3])) / 6
            assert volume == pytest.approx(1000, rel=1e-3)                      # wound outward
        xs = floats(parts["Blue box"]["positions"])[0::3]
        assert min(xs) == pytest.approx(30) and max(xs) == pytest.approx(40)   # component location applied
        assert asyncio.run(step.convert(ws, src)) == out                     # cached
        # an unreachable triangle budget coarsens, then keeps the coarsest mesh
        code = ("import json, sys; sys.path.insert(0, sys.argv[1]); import step_worker; "
                "print(json.dumps(step_worker.convert(sys.argv[2], max_triangles=1)))")
        r = subprocess.run([step.cad_python(), "-c", code, str(step.WORKER.parent), str(src)],
                           check=True, capture_output=True, timeout=120)
        assert [len(uints(p["indices"])) for p in json.loads(r.stdout)["parts"]] == [36, 36]
