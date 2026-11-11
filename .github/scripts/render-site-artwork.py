"""Render original site artwork with Pillow and a local Anybody variable TTF.

Usage: python3 .github/scripts/render-site-artwork.py --font path/to/Anybody.ttf
The font's source and SIL OFL licence are recorded in DESIGN.md and site/fonts/.
"""

import argparse
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[2]
GREEN = "#c1f17b"
ORCHID = "#d7b8f3"
INK = "#20271e"
SCALE = 2


def font(path, size, weight=750, width=108):
    face = ImageFont.truetype(str(path), size * SCALE)
    face.set_variation_by_axes([width, weight])
    return face


def mouse():
    image = Image.new("RGBA", (460 * SCALE, 490 * SCALE))
    draw = ImageDraw.Draw(image)

    def rounded(box, radius, fill):
        draw.rounded_rectangle(tuple(v * SCALE for v in box), radius * SCALE, fill)

    rounded((104, 27, 359, 465), 124, "#9873b5")
    rounded((96, 16, 351, 452), 124, ORCHID)
    rounded((104, 24, 220, 210), 55, "#e8d5fb")
    rounded((230, 24, 343, 210), 55, "#e8d5fb")
    rounded((78, 210, 105, 265), 13, "#b28acc")
    rounded((81, 277, 108, 332), 13, "#f2faac")
    rounded((201, 65, 248, 175), 23, "#a77dc6")
    rounded((210, 71, 239, 169), 14, "#45324f")
    for y in (83, 94, 147, 158):
        draw.line((215 * SCALE, y * SCALE, 234 * SCALE, y * SCALE), "#bd98d7", 2 * SCALE)
    draw.ellipse((213 * SCALE, 108 * SCALE, 237 * SCALE, 132 * SCALE), "#70577d")
    draw.line([(x * SCALE, y * SCALE) for x, y in
               [(197, 350), (212, 366), (224, 350), (236, 366), (251, 350)]],
              fill="#815f9b", width=6 * SCALE, joint="curve")
    return image.rotate(17, Image.Resampling.BICUBIC, expand=True)


def render(font_path):
    image = Image.new("RGB", (1200 * SCALE, 630 * SCALE), GREEN)
    draw = ImageDraw.Draw(image)
    draw.text((55 * SCALE, 40 * SCALE), "Whisker", font=font(font_path, 31), fill=INK)
    heading = font(font_path, 79)
    while draw.textlength("Same mouse.", font=heading) > 615 * SCALE:
        heading = font(font_path, heading.size // SCALE - 1)
    draw.text((52 * SCALE, 151 * SCALE), "Same mouse.", font=heading, fill=INK)
    draw.text((52 * SCALE, 242 * SCALE), "New moves.", font=heading, fill=INK)
    draw.text((56 * SCALE, 369 * SCALE), "Mouse & trackball control for macOS",
              font=font(font_path, 22, 500, 100), fill=INK)
    draw.rectangle((56 * SCALE, 467 * SCALE, 360 * SCALE, 522 * SCALE), fill=INK)
    draw.text((75 * SCALE, 484 * SCALE), "Build from source",
              font=font(font_path, 21, 650, 100), fill=GREEN)
    draw.text((56 * SCALE, 566 * SCALE), "Free. Open source. Yours.",
              font=font(font_path, 20, 500, 100), fill=INK)
    sculpture = mouse()
    image.paste(sculpture, (610 * SCALE, 22 * SCALE), sculpture)
    image.resize((1200, 630), Image.Resampling.LANCZOS).save(ROOT / "site/og.png", optimize=True)

    icon = Image.new("RGB", (256 * SCALE, 256 * SCALE), GREEN)
    sculpture.thumbnail((210 * SCALE, 233 * SCALE), Image.Resampling.LANCZOS)
    icon.paste(sculpture, ((icon.width - sculpture.width) // 2,
                          (icon.height - sculpture.height) // 2), sculpture)
    for size, target in [(256, "assets/icon.png"), (180, "apple-touch-icon.png"), (64, "favicon.png")]:
        icon.resize((size, size), Image.Resampling.LANCZOS).save(ROOT / "site" / target, optimize=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--font", required=True, type=Path)
    render(parser.parse_args().font)
