# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT
#
# Renders design/app-icon/preview.png from AppIcon.icon with Icon Composer's own
# renderer (ictool, in Xcode), so the preview shows the real Liquid Glass: the
# icon in its default, dark, clear and tinted appearances, then at Dock and
# Finder sizes on a light and a dark desktop.
#
#   python3 design/app-icon/preview.py
#
# Needs Xcode 26+ and Pillow (pip install pillow).

import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

HERE = Path(__file__).resolve().parent
ICON = HERE / "AppIcon.icon"
ICTOOL = Path(
    "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
)

TILE = 340
MARGIN = 56
APPEARANCES = [("Default", "Default"), ("Dark", "Dark"), ("Clear", "ClearDark"), ("Tinted", "TintedDark")]
SIZES = [180, 128, 64, 32, 16]
PAGE = "#F0EFEA"
INK = "#3A3B40"
DESKTOPS = ["#D8D4C8", "#16171A"]


def render(rendition: str, size: int, out: Path) -> Image.Image:
    f = out / f"{rendition}-{size}.png"
    subprocess.run(
        [
            str(ICTOOL), str(ICON), "--export-image", "--output-file", str(f), "--platform", "macOS",
            "--rendition", rendition, "--width", str(size), "--height", str(size), "--scale", "2",
        ],
        check=True,
        capture_output=True,
    )
    return Image.open(f).convert("RGBA").resize((size, size), Image.LANCZOS)


def main() -> None:
    if not ICTOOL.exists():
        sys.exit(f"ictool not found: {ICTOOL}")
    width = MARGIN + len(APPEARANCES) * (TILE + MARGIN)
    strip = 260
    height = MARGIN + TILE + 70 + strip + MARGIN
    page = Image.new("RGBA", (width, height), PAGE)
    draw = ImageDraw.Draw(page)
    font = ImageFont.load_default(26)
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp)
        for i, (label, rendition) in enumerate(APPEARANCES):
            x = MARGIN + i * (TILE + MARGIN)
            page.alpha_composite(render(rendition, TILE, out), (x, MARGIN))
            draw.text((x, MARGIN + TILE + 18), label, fill=INK, font=font)
        half = (width - 3 * MARGIN) // 2
        for j, (desk, rendition) in enumerate(zip(DESKTOPS, ["Default", "Dark"])):
            x0 = MARGIN + j * (half + MARGIN)
            y0 = MARGIN + TILE + 70
            panel = Image.new("RGBA", (half, strip), (0, 0, 0, 0))
            ImageDraw.Draw(panel).rounded_rectangle((0, 0, half - 1, strip - 1), 24, fill=desk)
            page.alpha_composite(panel, (x0, y0))
            x = x0 + 40
            for s in SIZES:
                page.alpha_composite(render(rendition, s, out), (x, y0 + (strip - s) // 2))
                x += s + 36
    page.convert("RGB").save(HERE / "preview.png", optimize=True)


if __name__ == "__main__":
    main()
