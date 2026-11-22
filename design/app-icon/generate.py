# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT
#
# Generates the auto-dj app icon layers as SVG on Icon Composer's 1024 pt canvas:
# the four hot cue pads auto-dj places, A to D (IN, BRIDGE, DROP, OUT), as a 2 x 2
# grid on the deck, like the docs' pad mark. Each pad is a lit rim around a face.
# Strokes are outlined into filled paths, and every layer is a full-canvas,
# transparent, white SVG with no background rectangle, so the layers stay aligned
# when Icon Composer imports them. Colours, glass and opacity live in
# AppIcon.icon/icon.json, which Icon Composer owns.
#
#   python3 design/app-icon/generate.py design/app-icon/AppIcon.icon/Assets
#
# Needs skia-pathops and fonttools (pip install skia-pathops fonttools).

import sys
from pathlib import Path

import pathops
from fontTools.pens.svgPathPen import SVGPathPen

CANVAS = 1024

PAD = 296  # a pad's side
GAP = 48  # between pads
RADIUS = 72  # a pad's corner radius
RIM = 52  # the lit rim's width
FACE_GAP = 18  # between the rim and the face inside it

GRID = 2 * PAD + GAP
ORIGIN = (CANVAS - GRID) / 2

# Pads in Rekordbox's order: A B on top, C D below.
PADS = {"a": (0, 0), "b": (1, 0), "c": (0, 1), "d": (1, 1)}


def svg_d(path: pathops.Path) -> str:
    pen = SVGPathPen(None, ntos=lambda v: f"{v:.2f}".rstrip("0").rstrip("."))
    path.draw(pen)
    return pen.getCommands()


def svg(name: str, d: str) -> str:
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{CANVAS}" height="{CANVAS}" '
        f'viewBox="0 0 {CANVAS} {CANVAS}">\n'
        f"  <title>{name}</title>\n"
        f'  <path fill="#FFFFFF" fill-rule="evenodd" d="{d}"/>\n'
        f"</svg>\n"
    )


def rounded_rect(x: float, y: float, w: float, h: float, r: float) -> pathops.Path:
    # Straight sides and four cubic corners (kappa approximation), clockwise.
    k = 0.5522847498 * r
    p = pathops.Path()
    p.moveTo(x + r, y)
    p.lineTo(x + w - r, y)
    p.cubicTo(x + w - r + k, y, x + w, y + r - k, x + w, y + r)
    p.lineTo(x + w, y + h - r)
    p.cubicTo(x + w, y + h - r + k, x + w - r + k, y + h, x + w - r, y + h)
    p.lineTo(x + r, y + h)
    p.cubicTo(x + r - k, y + h, x, y + h - r + k, x, y + h - r)
    p.lineTo(x, y + r)
    p.cubicTo(x, y + r - k, x + r - k, y, x + r, y)
    p.close()
    return p


def inset(x: float, y: float, d: float) -> pathops.Path:
    return rounded_rect(x + d, y + d, PAD - 2 * d, PAD - 2 * d, max(RADIUS - d, 8))


def corner(col: int, row: int) -> tuple[float, float]:
    return ORIGIN + col * (PAD + GAP), ORIGIN + row * (PAD + GAP)


def rim(col: int, row: int) -> pathops.Path:
    x, y = corner(col, row)
    return pathops.op(rounded_rect(x, y, PAD, PAD, RADIUS), inset(x, y, RIM), pathops.PathOp.DIFFERENCE)


def face(col: int, row: int) -> pathops.Path:
    x, y = corner(col, row)
    return inset(x, y, RIM + FACE_GAP)


# Back to front within each pad: its face, then its rim.
LAYERS = {}
for i, (pad, (col, row)) in enumerate(PADS.items(), start=1):
    LAYERS[f"{i}-{pad}-face"] = lambda c=col, r=row: face(c, r)
    LAYERS[f"{i}-{pad}-rim"] = lambda c=col, r=row: rim(c, r)


def main() -> None:
    out = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    out.mkdir(parents=True, exist_ok=True)
    for name, build in LAYERS.items():
        (out / f"{name}.svg").write_text(svg(name, svg_d(build())))


if __name__ == "__main__":
    main()
