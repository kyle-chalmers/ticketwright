"""Shared helpers for the README media scripts (maintainer tools, not part of the kit or package)."""

from __future__ import annotations

import glob
import os
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
IMAGES = REPO / "docs" / "images"

# KC AI Labs brand tokens (kclabs.ai globals.css). Lime is the accent; orange marks only what a
# person does or approves; everything sits on the near-black canvas.
BLACK = "#030303"
CARD = "#0a0a0a"
CARD_2 = "#141414"
LINE = "#303030"
LIME = "#c4ff00"
LIME_DEEP = "#9ecc00"
ORANGE = "#e47d5b"
CREAM = "#f5f5f5"
MUTED = "#b8b8b8"


def find_chromium() -> str | None:
    """Return a Chromium executable to drive with Playwright, or None for its default.

    Order: $TICKETWRIGHT_CHROMIUM, then a preinstalled Playwright browser under
    $PLAYWRIGHT_BROWSERS_PATH (or /opt/pw-browsers). None means "let Playwright use
    the browser from `playwright install chromium`".
    """
    explicit = os.environ.get("TICKETWRIGHT_CHROMIUM")
    if explicit:
        return explicit
    roots = [os.environ.get("PLAYWRIGHT_BROWSERS_PATH", ""), "/opt/pw-browsers"]
    for root in filter(None, roots):
        patterns = (
            "chromium-*/chrome-linux/chrome",
            "chromium-*/chrome-mac/Chromium.app/Contents/MacOS/Chromium",
            "chromium-*/chrome-win/chrome.exe",
        )
        for pattern in patterns:
            hits = sorted(glob.glob(str(Path(root) / pattern)))
            if hits:
                return hits[-1]
    return None


def launch(playwright):
    """Launch headless Chromium with the executable from find_chromium()."""
    exe = find_chromium()
    kwargs = {"executable_path": exe} if exe else {}
    return playwright.chromium.launch(**kwargs)


_FONT_HOSTS = ("https://fonts.googleapis.com/", "https://fonts.gstatic.com/")
_font_cache: dict[str, tuple[int, str, bytes]] = {}


def route_web_fonts(page) -> None:
    """Fetch Google Fonts through Python instead of the browser.

    Headless Chromium ignores HTTPS_PROXY and the system CA bundle that urllib
    honours, so behind a corporate or sandbox proxy the web fonts silently fall
    back to the system sans. Fetching them here keeps renders identical across
    machines; when the fetch fails the page falls back to its font stack.
    """

    def handler(route) -> None:
        url = route.request.url
        if url not in _font_cache:
            headers = {"User-Agent": route.request.headers.get("user-agent", "Mozilla/5.0")}
            try:
                req = urllib.request.Request(url, headers=headers)
                with urllib.request.urlopen(req, timeout=20) as resp:
                    ctype = resp.headers.get("Content-Type", "application/octet-stream")
                    _font_cache[url] = (resp.status, ctype, resp.read())
            except (OSError, urllib.error.URLError):
                route.abort()
                return
        status, ctype, body = _font_cache[url]
        route.fulfill(
            status=status,
            body=body,
            headers={"Content-Type": ctype, "Access-Control-Allow-Origin": "*"},
        )

    for host in _FONT_HOSTS:
        page.route(f"{host}**", handler)
