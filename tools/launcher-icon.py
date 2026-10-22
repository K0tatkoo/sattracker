#!/usr/bin/env python3
"""Orbit's mark, drawn once and written into every place that shows it.

    pip3 install shapely          # once
    python3 tools/launcher-icon.py

The mark ("ringed planet", the owner's pick on 2026-10-22, O1 on the concept
sheet): a planet and its ring, tilted 24 degrees. The ring's far side goes
behind the planet, its near side passes in front with a clear gap either
side, and the satellite rides the near side as a bead. Drawn on the sites'
24-unit icon grid with their 2-unit line.

It is drawn the way the concept sheet drew it: lines, then the gaps cut out
where something passes in front. But the cutting happens here, with real
geometry (shapely), and what comes out is filled shapes — nothing painted in
the background colour to fake a gap. So the same mark works on any
background, in Android's one-colour themed icons and in the iPhone's tinted
icons.

Writes:
  app/src/main/res/drawable/ic_launcher_background.xml   the flat violet plate
  app/src/main/res/drawable/ic_launcher_foreground.xml   the mark in white, 108 x 108
  app/src/main/res/drawable/ic_launcher_monochrome.xml   the same, for themed icons
  app/src/main/assets/globe.html                          the page's #i-orbit symbol
  ios/Shared/OrbitMarkGeometry.swift                      the same shapes for SwiftUI

ios/tools/app-icon.py renders the iPhone icons from this file, and the store's
web/nebula3d/ops/vd2svg.py the tile on its Apps page and the portfolio's.
"""
import math
import os
import re

try:
    from shapely import affinity
    from shapely.geometry import LineString, MultiPolygon, Point
except ImportError:
    raise SystemExit("tools/launcher-icon.py draws with shapely: pip3 install shapely")

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, ".."))
RES = os.path.join(ROOT, "app", "src", "main", "res", "drawable")

LINE = 2.0              # the sites' line width on the 24-unit grid
TILT = -24.0            # degrees; negative lifts the ring's right end
RX, RY = 10.8, 2.8      # the ring
PLANET = 5.4            # the planet's outline (centre of its line)
CROSSING = 5.9          # the near side's gap runs this far either side of the centre
CROSSING_HALF = 1.7     # ... and this far either side of the ring's line
BEAD_T = 40.0           # where the bead sits on the ring (degrees, see ring_point)
BEAD = 1.8              # the bead's radius
BEAD_CLEAR = 2.7        # what the bead cuts away round itself
QUALITY = 64            # segments per quarter circle
SIMPLIFY = 0.004        # grid units: far below a pixel even on the 1024 px icon

PLATE = "#FF6A45FF"
WHITE = "#FFFFFFFF"


def ring_point(t):
    """The ring before the tilt: t in degrees, clockwise on screen from the
    right tip (y points down), so 0..180 is the near half."""
    r = math.radians(t)
    return RX * math.cos(r), RY * math.sin(r)


def ring_line(t0, t1, steps=720):
    return LineString([ring_point(t0 + (t1 - t0) * i / steps) for i in range(steps + 1)])


def mark():
    """The mark as one shape on the 24-unit grid, centred on (12, 12)."""
    def stroke(line, half):
        return line.buffer(half, quad_segs=QUALITY)

    def disc(c, r):
        return Point(c).buffer(r, quad_segs=QUALITY)

    far = stroke(ring_line(180, 360), LINE / 2)
    planet = disc((0, 0), PLANET)
    outline = disc((0, 0), PLANET + LINE / 2).difference(disc((0, 0), PLANET - LINE / 2))
    t_cross = math.degrees(math.acos(CROSSING / RX))
    crossing = stroke(ring_line(t_cross, 180 - t_cross), CROSSING_HALF)
    near = stroke(ring_line(0, 180), LINE / 2)
    bead = ring_point(BEAD_T)

    shape = far.difference(planet).union(outline)    # the far side goes behind the planet
    shape = shape.difference(crossing).union(near)   # the near side passes in front
    shape = shape.difference(disc(bead, BEAD_CLEAR)).union(disc(bead, BEAD))
    shape = affinity.rotate(shape, TILT, origin=(0, 0))
    shape = affinity.translate(shape, 12, 12)
    return shape.simplify(SIMPLIFY)


MARK = mark()
INK = MARK.bounds      # (min x, min y, max x, max y) on the grid
# On the launcher the mark's longer side is 14 of the 24 units a 72 dp plate
# spans, as Spectra's: 42 dp across, well inside the 66 dp circle every
# launcher mask leaves visible.
LAUNCHER_SCALE = 14 / 24 * 72 / (INK[2] - INK[0])


def num(v):
    s = f"{v:.3f}".rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s


def polygons(shape):
    return list(shape.geoms) if isinstance(shape, MultiPolygon) else [shape]


def rings(cx=12.0, cy=12.0, scale=1.0):
    """Every outline of the mark (outer edges and holes), as point lists, with
    the grid's centre moved to (cx, cy) at `scale` per grid unit."""
    out = []
    for poly in polygons(MARK):
        for ring in [poly.exterior, *poly.interiors]:
            pts = list(ring.coords)[:-1]
            out.append([(cx + (x - 12) * scale, cy + (y - 12) * scale) for x, y in pts])
    return out


def path_data(cx=12.0, cy=12.0, scale=1.0):
    """One path for the whole mark; fill it even-odd."""
    return " ".join("M" + " ".join(f"{num(x)},{num(y)}" for x, y in pts) + "Z" for pts in rings(cx, cy, scale))


def vector(size, viewport, note, body):
    return (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        f"<!-- {note} Written by tools/launcher-icon.py; edit that, not this. -->\n"
        '<vector xmlns:android="http://schemas.android.com/apk/res/android"\n'
        f'    android:width="{size}dp"\n'
        f'    android:height="{size}dp"\n'
        f'    android:viewportWidth="{viewport}"\n'
        f'    android:viewportHeight="{viewport}">\n'
        f"{body}"
        "</vector>\n"
    )


def vector_mark(color):
    return (
        "    <path\n"
        f'        android:pathData="{path_data(54, 54, LAUNCHER_SCALE)}"\n'
        f'        android:fillColor="{color}"\n'
        '        android:fillType="evenOdd" />\n')


def page_symbol():
    """The page's #i-orbit: filled, so the CSS's line widths do not touch it."""
    return (f'<symbol id="i-orbit" viewBox="0 0 24 24"><path d="{path_data()}" '
            f'fill="currentColor" fill-rule="evenodd" stroke="none"/></symbol>')


def swift_geometry():
    def ring(pts):
        return "        [" + ", ".join(f"({num(x)}, {num(y)})" for x, y in pts) + "],\n"
    return (
        "// Written by tools/launcher-icon.py; edit that, not this.\n"
        "\n"
        "/// Orbit's mark (\"ringed planet\") on the 24-unit icon grid: the outlines\n"
        "/// of one filled shape, outer edges and holes alike — fill them even-odd.\n"
        "/// The same shape the Android icon, the page and the iPhone icon are made of.\n"
        "enum OrbitMarkGeometry {\n"
        f"    static let bounds = (minX: {num(INK[0])}, minY: {num(INK[1])}, maxX: {num(INK[2])}, maxY: {num(INK[3])})\n"
        "    static let outlines: [[(Double, Double)]] = [\n"
        + "".join(ring(r) for r in rings()) +
        "    ]\n"
        "}\n")


FILES = {
    os.path.join(RES, "ic_launcher_background.xml"): vector(
        108, 108, "The plate: one flat violet, the app's accent fill.",
        f'    <path\n        android:pathData="M0,0h108v108h-108z"\n        android:fillColor="{PLATE}" />\n'),
    os.path.join(RES, "ic_launcher_foreground.xml"): vector(
        108, 108,
        "Adaptive-icon foregrounds are 108 x 108 with the middle 72 visible; the mark sits in the middle.",
        vector_mark(WHITE)),
    os.path.join(RES, "ic_launcher_monochrome.xml"): vector(
        108, 108, "Themed icons tint this one colour, so it is the foreground's mark alone.",
        vector_mark(WHITE)),
    os.path.join(ROOT, "ios", "Shared", "OrbitMarkGeometry.swift"): swift_geometry(),
}

if __name__ == "__main__":
    for path, text in FILES.items():
        with open(path, "w") as f:
            f.write(text)
        print("wrote", os.path.relpath(path, ROOT))
    page = os.path.join(ROOT, "app", "src", "main", "assets", "globe.html")
    html = open(page).read()
    new, n = re.subn(r'<symbol id="i-orbit".*?</symbol>', lambda _: page_symbol(), html, flags=re.S)
    if n != 1:
        raise SystemExit("globe.html: expected one #i-orbit symbol")
    with open(page, "w") as f:
        f.write(new)
    print("wrote", os.path.relpath(page, ROOT), "(#i-orbit)")
