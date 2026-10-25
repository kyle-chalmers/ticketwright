"""Draw the Ticketwright logo (light and dark) and the square icon source as SVG.

The mark is a ticket stub in KC AI Labs lime: a check on the ticket (the work, reviewed) and an
orange dot on the stub (the one thing a person approves before anything leaves). The wordmark is
Space Grotesk SemiBold, the kclabs.ai heading face, outlined to paths so the SVGs need no font and
render the same on GitHub, PyPI and the plugin directory.

    curl -L -o /tmp/sg/SpaceGrotesk.ttf \\
      "https://github.com/google/fonts/raw/main/ofl/spacegrotesk/SpaceGrotesk%5Bwght%5D.ttf"
    uv run --with fonttools --with uharfbuzz python scripts/readme_media/brand.py \\
      --font /tmp/sg/SpaceGrotesk.ttf
    rsvg-convert -w 1024 -h 1024 scripts/readme_media/icon.svg -o .claude-plugin/icon.png

Space Grotesk is under the SIL Open Font License; only outlines of its glyphs ship here.
"""

from __future__ import annotations

import argparse
import io
from pathlib import Path

from _common import BLACK, CREAM, HERE, IMAGES, LIME, ORANGE

TICKET = (
    "M14 18H86A10 10 0 0 1 96 28V41A9 9 0 0 0 96 59V72A10 10 0 0 1 86 82H14"
    "A10 10 0 0 1 4 72V59A9 9 0 0 0 4 41V28A10 10 0 0 1 14 18Z"
)


def mark(outline: str | None) -> str:
    """The ticket mark in a 100x100 box. `outline` strokes the ticket edge for light grounds."""
    edge = f' stroke="{outline}" stroke-width="3" stroke-linejoin="round"' if outline else ""
    return (
        f'<path d="{TICKET}" fill="{LIME}"{edge}/>'
        f'<path d="M66 25V75" stroke="{BLACK}" stroke-width="3" stroke-linecap="round" '
        'stroke-dasharray="0.1 7.5"/>'
        f'<path d="M20 51L32 63L53 37" fill="none" stroke="{BLACK}" stroke-width="8.5" '
        'stroke-linecap="round" stroke-linejoin="round"/>'
        f'<circle cx="78.5" cy="50" r="5.75" fill="{ORANGE}"/>'
    )


def outline_text(font: Path, text: str, weight: float, size: float) -> tuple[str, float]:
    """One SVG path for `text`, shaped by HarfBuzz, baseline at y=0. Returns (d, advance)."""
    import uharfbuzz as hb
    from fontTools.pens.svgPathPen import SVGPathPen
    from fontTools.pens.transformPen import TransformPen
    from fontTools.ttLib import TTFont
    from fontTools.varLib.instancer import instantiateVariableFont

    buf = io.BytesIO()
    instantiateVariableFont(TTFont(font), {"wght": weight}, inplace=False).save(buf)
    data = buf.getvalue()
    hb_font = hb.Font(hb.Face(data))
    shaped = hb.Buffer()
    shaped.add_str(text)
    shaped.guess_segment_properties()
    hb.shape(hb_font, shaped, {"kern": True, "liga": True})
    ttf = TTFont(io.BytesIO(data))
    glyphs, order = ttf.getGlyphSet(), ttf.getGlyphOrder()
    scale = size / hb_font.face.upem
    pen = SVGPathPen(glyphs)
    x = 0
    for info, pos in zip(shaped.glyph_infos, shaped.glyph_positions):
        moved = (scale, 0, 0, -scale, (x + pos.x_offset) * scale, -pos.y_offset * scale)
        glyphs[order[info.codepoint]].draw(TransformPen(pen, moved))
        x += pos.x_advance
    return pen.getCommands(), x * scale


def logo(font: Path, dark: bool) -> str:
    size, gap, baseline = 76.0, 22.0, 77.0
    first, first_w = outline_text(font, "Ticket", 600, size)
    second, second_w = outline_text(font, "wright", 600, size)
    width = 100 + gap + first_w + second_w + 4
    ink = CREAM if dark else BLACK
    accent = LIME if dark else BLACK
    title = "Ticketwright"
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width:.1f} 104" '
        f'width="{width * 0.6:.0f}" height="62" role="img" aria-label="{title}">'
        f"<title>{title}</title>"
        f"{mark(None if dark else BLACK)}"
        f'<path transform="translate({100 + gap} {baseline})" fill="{ink}" d="{first}"/>'
        f'<path transform="translate({100 + gap + first_w:.2f} {baseline})" fill="{accent}" '
        f'd="{second}"/></svg>\n'
    )


def icon() -> str:
    # Full-bleed canvas; the directory and app stores round the corners themselves.
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" width="1024" height="1024" '
        'role="img" aria-label="Ticketwright"><title>Ticketwright</title>'
        f'<rect width="100" height="100" fill="{BLACK}"/>'
        f'<g transform="translate(14 14) scale(0.72)">{mark(None)}</g></svg>\n'
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--font", type=Path, required=True, help="Space Grotesk variable .ttf")
    args = parser.parse_args()
    IMAGES.mkdir(parents=True, exist_ok=True)
    outputs = {
        IMAGES / "logo-light.svg": logo(args.font, dark=False),
        IMAGES / "logo-dark.svg": logo(args.font, dark=True),
        HERE / "icon.svg": icon(),
    }
    for path, svg in outputs.items():
        path.write_text(svg, encoding="utf-8")
        print(f"wrote {path.relative_to(IMAGES.parent.parent)}  {len(svg) // 1024} KB")


if __name__ == "__main__":
    main()
