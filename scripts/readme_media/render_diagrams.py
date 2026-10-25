"""Render the README diagrams in diagrams.html to docs/images/<id>.png at 2x.

Each <svg class="diagram" id="..."> in the template is one image. The template is the source of
truth; edit it, rerun this, and commit both. Over --max-kb, a PNG is re-saved as a 256-colour
palette image (needs Pillow), which these flat-colour diagrams survive without visible change.

    uv run --with playwright --with pillow python scripts/readme_media/render_diagrams.py
"""

from __future__ import annotations

import argparse
import io

from _common import HERE, IMAGES, launch, route_web_fonts
from playwright.sync_api import sync_playwright

TEMPLATE = HERE / "diagrams.html"


def shrink(png: bytes, max_kb: int) -> bytes:
    if len(png) <= max_kb * 1024:
        return png
    try:
        from PIL import Image
    except ImportError:
        print(f"  note: {len(png) // 1024} KB > {max_kb} KB; add --with pillow to shrink")
        return png
    img = Image.open(io.BytesIO(png))
    if "A" in img.getbands():  # rounded corners: palette quantizing would drop the alpha
        return png
    img = img.convert("RGB")
    buf = io.BytesIO()
    img.quantize(colors=256, method=Image.Quantize.MEDIANCUT).save(buf, "PNG", optimize=True)
    return buf.getvalue() if buf.tell() < len(png) else png


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--scale", type=float, default=2.0)
    parser.add_argument("--max-kb", type=int, default=400)
    args = parser.parse_args()
    with sync_playwright() as pw:
        browser = launch(pw)
        page = browser.new_page(viewport={"width": 1240, "height": 800},
                                device_scale_factor=args.scale)
        route_web_fonts(page)
        page.goto(TEMPLATE.as_uri(), wait_until="networkidle")
        page.evaluate("document.fonts.ready")
        for el in page.locator("svg.diagram").all():
            name = el.get_attribute("id")
            png = shrink(el.screenshot(type="png", omit_background=True), args.max_kb)
            out = IMAGES / f"{name}.png"
            out.write_bytes(png)
            print(f"wrote {out.relative_to(IMAGES.parent.parent)}  {len(png) // 1024} KB")
        browser.close()


if __name__ == "__main__":
    main()
