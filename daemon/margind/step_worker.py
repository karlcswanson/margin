"""STEP -> margin-parts JSON, run as a script by a Python that has OpenCascade
(cadquery-ocp), which is usually not the daemon's own interpreter. Only the
stdlib is imported at module level so the daemon (and tests) can use the
packing helpers without OCP.

    python step_worker.py model.step out.json

One entry per leaf part instance, positions in the model's units, colours as
sRGB. Parts whose faces carry several colours (KiCad exports colour pads, body
and pins separately) keep one entry but add "groups": contiguous index ranges,
one per colour, largest first; the part's "color" is that of the first group.
"""
from __future__ import annotations

import base64
import json
import math
import os
import sys
from array import array

FORMAT = "margin-parts/1"
MAX_TRIANGLES = 1_500_000
GREY = (0.7, 0.7, 0.72, 1.0)
# names STEP writers give things that say nothing about the part
_GENERIC = {"", "COMPOUND", "SOLID", "SHELL", "FACE", "PART", "ASSEMBLY", "NONE"}


def b64(a: array) -> str:
    """Little-endian bytes of a float32/uint32 array, base64."""
    if sys.byteorder == "big":
        a = array(a.typecode, a)
        a.byteswap()
    return base64.b64encode(a.tobytes()).decode("ascii")


def meaningful(name: str | None) -> bool:
    if not name:
        return False
    n = name.strip()
    return not (n.upper() in _GENERIC or n.isdigit() or n.startswith("=>[")
                or n.startswith("Open CASCADE STEP translator"))


def unique_names(names: list[str]) -> list[str]:
    """"Bolt", "Bolt", "Bolt" -> "Bolt", "Bolt 2", "Bolt 3"."""
    seen: dict[str, int] = {}
    out = []
    for n in names:
        seen[n] = seen.get(n, 0) + 1
        out.append(n if seen[n] == 1 else f"{n} {seen[n]}")
    return out


class Part:
    """Triangles of one part instance, bucketed by colour."""

    def __init__(self, name: str, color: tuple[float, ...]):
        self.name, self.color = name, color
        self.buckets: dict[tuple[float, ...], tuple[array, array, array]] = {}

    def bucket(self, color: tuple[float, ...] | None) -> tuple[array, array, array]:
        color = color or self.color
        if color not in self.buckets:
            self.buckets[color] = (array("f"), array("f"), array("I"))
        return self.buckets[color]

    @property
    def triangles(self) -> int:
        return sum(len(b[2]) for b in self.buckets.values()) // 3

    def pack(self) -> dict:
        pos, nrm, idx = array("f"), array("f"), array("I")
        groups = []
        for color, (p, n, i) in sorted(self.buckets.items(), key=lambda kv: -len(kv[1][2])):
            if not i:
                continue
            base = len(pos) // 3
            groups.append({"color": [round(c, 4) for c in color], "start": len(idx), "count": len(i)})
            pos.extend(p)
            nrm.extend(n)
            idx.extend(v + base for v in i)
        out = {"name": self.name, "color": groups[0]["color"] if groups else list(self.color),
               "positions": b64(pos), "normals": b64(nrm), "indices": b64(idx)}
        if len(groups) > 1:
            out["groups"] = groups
        return out


def pack(parts: list[Part], units: str = "mm") -> dict:
    parts = [p for p in parts if p.triangles]
    for p, n in zip(parts, unique_names([p.name for p in parts])):
        p.name = n
    return {"format": FORMAT, "units": units, "parts": [p.pack() for p in parts]}


# ---- OpenCascade side --------------------------------------------------------

def convert(src: str, max_triangles: int = MAX_TRIANGLES) -> dict:
    from OCP.Bnd import Bnd_Box
    from OCP.BRep import BRep_Tool
    from OCP.BRepBndLib import BRepBndLib
    from OCP.BRepLib import BRepLib_ToolTriangulatedShape
    from OCP.BRepMesh import BRepMesh_IncrementalMesh
    from OCP.BRepTools import BRepTools
    from OCP.IFSelect import IFSelect_RetDone
    from OCP.Interface import Interface_Static
    from OCP.Quantity import Quantity_ColorRGBA, Quantity_TypeOfColor
    from OCP.STEPCAFControl import STEPCAFControl_Reader
    from OCP.TCollection import TCollection_ExtendedString
    from OCP.TDataStd import TDataStd_Name
    from OCP.TDF import TDF_Label, TDF_LabelSequence
    from OCP.TDocStd import TDocStd_Document
    from OCP.TopAbs import TopAbs_FACE, TopAbs_FORWARD, TopAbs_REVERSED
    from OCP.TopExp import TopExp_Explorer
    from OCP.TopLoc import TopLoc_Location
    from OCP.TopoDS import TopoDS
    from OCP.XCAFDoc import XCAFDoc_ColorGen, XCAFDoc_ColorSurf, XCAFDoc_DocumentTool

    fallback = os.path.splitext(os.path.basename(src))[0] or "Part"
    doc = TDocStd_Document(TCollection_ExtendedString("XmlOcaf"))
    reader = STEPCAFControl_Reader()
    reader.SetColorMode(True)
    reader.SetNameMode(True)
    if reader.ReadFile(src) != IFSelect_RetDone or not reader.Transfer(doc):
        raise SystemExit(f"can't read {src} as STEP")
    # OCCT converts lengths to its working unit on read (mm unless configured)
    units = (Interface_Static.CVal_s("xstep.cascade.unit") or "MM").lower()
    shapes = XCAFDoc_DocumentTool.ShapeTool_s(doc.Main())
    colors = XCAFDoc_DocumentTool.ColorTool_s(doc.Main())

    def name_of(label) -> str | None:
        attr = TDataStd_Name()
        return attr.Get().ToExtString() if label.FindAttribute(TDataStd_Name.GetID_s(), attr) else None

    def color_of(label) -> tuple[float, ...] | None:
        c = Quantity_ColorRGBA()
        for kind in (XCAFDoc_ColorSurf, XCAFDoc_ColorGen):
            if colors.GetColor_s(label, kind, c):
                r, g, b = c.GetRGB().Values(Quantity_TypeOfColor.Quantity_TOC_sRGB)
                return (r, g, b, c.Alpha())
        return None

    def faces(shape):
        ex = TopExp_Explorer(shape, TopAbs_FACE)
        while ex.More():
            yield TopoDS.Face_s(ex.Current())
            ex.Next()

    def face_colors(label) -> dict[int, list]:
        """Colours set on sub-shapes (solids, faces) of a part, per face; faces win over solids."""
        subs = TDF_LabelSequence()
        shapes.GetSubShapes_s(label, subs)
        found = []
        for i in range(1, subs.Length() + 1):
            sub = subs.Value(i)
            color = color_of(sub)
            if color:
                found.append((shapes.GetShape_s(sub), color))
        out: dict[int, list] = {}
        for shape, color in sorted(found, key=lambda sc: int(sc[0].ShapeType())):   # compound .. face
            for f in faces(shape):
                f = f.Oriented(TopAbs_FORWARD)
                bucket = out.setdefault(hash(f), [])
                bucket[:] = [fc for fc in bucket if not fc[0].IsSame(f)] + [(f, color)]
        return out

    # 1. walk the assembly tree down to leaf shapes, composing locations
    leaves = []     # (proto shape, location, name, colour, face colours)
    face_color_cache: dict[int, dict] = {}

    def walk(label, loc, comp_names, prod_names, color):
        if not colors.IsVisible_s(label):
            return
        color = color_of(label) or color
        prod_names = [name_of(label), *prod_names]
        if shapes.IsAssembly_s(label):
            comps = TDF_LabelSequence()
            shapes.GetComponents_s(label, comps)
            for i in range(1, comps.Length() + 1):
                comp = comps.Value(i)
                if not colors.IsVisible_s(comp):
                    continue
                ref = TDF_Label()
                shapes.GetReferredShape_s(comp, ref)
                walk(ref, loc.Multiplied(shapes.GetLocation_s(comp)),
                     [name_of(comp), *comp_names], prod_names, color_of(comp) or color)
            return
        shape = shapes.GetShape_s(label)
        if shape.IsNull():
            return
        # innermost meaningful instance name ("R4"), else product name ("Bolt")
        name = next((n for n in comp_names + prod_names if meaningful(n)), None) or fallback
        if hash(shape) not in face_color_cache:
            face_color_cache[hash(shape)] = face_colors(label)
        leaves.append((shape, loc, name.strip(), color, face_color_cache[hash(shape)]))

    roots = TDF_LabelSequence()
    shapes.GetFreeShapes(roots)
    for i in range(1, roots.Length() + 1):
        walk(roots.Value(i), TopLoc_Location(), [], [], None)

    # 2. mesh, coarsening until the whole model fits the triangle budget
    box = Bnd_Box()
    for shape, loc, *_ in leaves:
        BRepBndLib.Add_s(shape.Moved(loc), box)
    diag = 0.0 if box.IsVoid() else math.sqrt(box.SquareExtent())
    deflection = diag / 1000 if diag > 0 else 0.1
    protos = {}
    for shape, *_ in leaves:
        protos.setdefault(hash(shape), shape)

    def triangulation(face):
        loc = TopLoc_Location()
        return BRep_Tool.Triangulation_s(face, loc), loc

    for attempt in range(5):        # gives up coarsening after that and keeps the last mesh
        if attempt:
            for shape in protos.values():
                BRepTools.Clean_s(shape)
            deflection *= max(2.0, 1.5 * total / max_triangles)
        for shape in protos.values():
            BRepMesh_IncrementalMesh(shape, deflection, False, 0.5, True)
        per_proto = {}
        for k, shape in protos.items():
            per_proto[k] = sum(t.NbTriangles() for t, _ in map(triangulation, faces(shape)) if t is not None)
        total = sum(per_proto[hash(shape)] for shape, *_ in leaves)
        if total <= max_triangles:
            break

    # 3. pull the triangles out, in model space
    local: dict[tuple, tuple | None] = {}    # per proto face: nodes, normals, triangles (face location applied)

    def face_mesh(face):
        k = (hash(face), face.Orientation())
        if k not in local:
            tri, floc = triangulation(face)
            if tri is None or tri.NbTriangles() == 0:
                local[k] = None
                return None
            if not tri.HasNormals():
                try:
                    BRepLib_ToolTriangulatedShape.ComputeNormals_s(face, tri)
                except Exception:
                    tri.ComputeNormals()    # averaged from the mesh itself
            t = floc.Transformation()
            m = [[t.Value(r, c) for c in range(1, 5)] for r in range(1, 4)]
            flip = (face.Orientation() == TopAbs_REVERSED) != t.IsNegative()
            sign = -1.0 if face.Orientation() == TopAbs_REVERSED else 1.0
            nodes, normals = [], []
            for i in range(1, tri.NbNodes() + 1):
                p = tri.Node(i)
                nodes.append(_apply(m, p.X(), p.Y(), p.Z()))
                n = tri.Normal(i)
                normals.append(_rotate(m, sign * n.X(), sign * n.Y(), sign * n.Z()))
            tris = []
            for i in range(1, tri.NbTriangles() + 1):
                a, b, c = tri.Triangle(i).Get()
                tris.append((a - 1, c - 1, b - 1) if flip else (a - 1, b - 1, c - 1))
            local[k] = (nodes, normals, tris)
        return local[k]

    parts = []
    for shape, loc, name, color, fcolors in leaves:
        part = Part(name, color or GREY)
        t = loc.Transformation()
        m = [[t.Value(r, c) for c in range(1, 5)] for r in range(1, 4)]
        neg = t.IsNegative()
        for face in faces(shape):
            mesh = face_mesh(face)
            if mesh is None:
                continue
            fwd = face.Oriented(TopAbs_FORWARD)
            fc = next((c for f, c in fcolors.get(hash(fwd), []) if f.IsSame(fwd)), None)
            pos, nrm, idx = part.bucket(fc)
            base = len(pos) // 3
            nodes, normals, tris = mesh
            for x, y, z in nodes:
                pos.extend(_apply(m, x, y, z))
            for x, y, z in normals:
                nrm.extend(_rotate(m, x, y, z))
            for a, b, c in tris:
                idx.extend((base + a, base + c, base + b) if neg else (base + a, base + b, base + c))
        parts.append(part)
    return pack(parts, units)


def _apply(m, x, y, z):
    return (m[0][0] * x + m[0][1] * y + m[0][2] * z + m[0][3],
            m[1][0] * x + m[1][1] * y + m[1][2] * z + m[1][3],
            m[2][0] * x + m[2][1] * y + m[2][2] * z + m[2][3])


def _rotate(m, x, y, z):
    nx = m[0][0] * x + m[0][1] * y + m[0][2] * z
    ny = m[1][0] * x + m[1][1] * y + m[1][2] * z
    nz = m[2][0] * x + m[2][1] * y + m[2][2] * z
    d = math.sqrt(nx * nx + ny * ny + nz * nz) or 1.0
    return (nx / d, ny / d, nz / d)


def main(argv: list[str]) -> None:
    src, out = argv[-2], argv[-1]
    data = convert(src)
    with open(out, "w") as f:
        json.dump(data, f, separators=(",", ":"))
    print(f"{len(data['parts'])} parts", file=sys.stderr)


if __name__ == "__main__":
    main(sys.argv)
