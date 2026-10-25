"""Build docs/images/demo.gif: one ticket through Ticketwright, in a Claude Code chat.

A rendered walkthrough, not a screen recording: /ticket opens TEST-130 with bob's TEST-118 ranked
as prior work and waits for plan approval, /build runs it, /review walks the validation pyramid to
your sign-off and an APPROVE, and /ship shows its delivery plan and stops until you say go ahead.
The words come from the skills' own say-this text (see claude_flow.py), so rerun this when a
skill's wording changes. Frames are HTML scenes screenshotted by headless Chromium, then stitched
by ffmpeg with a generated palette.

    uv run --with playwright python scripts/readme_media/render_gif.py

Needs ffmpeg on PATH and a Chromium Playwright can drive (see _common.find_chromium; on a laptop
run `uv run --with playwright playwright install chromium` once, or set TICKETWRIGHT_CHROMIUM).
"""

from __future__ import annotations

import argparse
import html
import math
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _common import BLACK, CREAM, IMAGES, LIME, MUTED, ORANGE, launch, route_web_fonts  # noqa: E402
from claude_flow import CSS, STEPS, Step, chat_frame, check_clean, user  # noqa: E402

OUT = IMAGES / "demo.gif"
LOGO = IMAGES / "logo-dark.svg"
STAGE_W, STAGE_H = 960, 600
FPS = 8
TICK = 1 / FPS

STAGE_HTML = """<!doctype html>
<html><head><meta charset="utf-8">
<link href="https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@400;500;600;700&family=JetBrains+Mono:wght@400;700&display=swap" rel="stylesheet">
<style>
  :root { --lime:%(lime)s; --orange:%(orange)s; --cream:%(cream)s; --muted:%(muted)s; --bg:%(bg)s; }
  html, body { margin:0; padding:0; }
  body { width:%(w)dpx; height:%(h)dpx; overflow:hidden; background:var(--bg); color:var(--cream);
    font-family:"Space Grotesk",-apple-system,"Segoe UI","Helvetica Neue",Arial,sans-serif;
    position:relative; }
  .glow { position:absolute; inset:0; background:
    radial-gradient(700px 360px at 50%% 30%%, rgba(196,255,0,.07), transparent 70%%),
    radial-gradient(500px 260px at 95%% 110%%, rgba(228,125,91,.10), transparent 70%%); }
  #stage { position:absolute; inset:0; }
  .caption { position:absolute; top:0; left:24px; right:24px; height:56px; display:flex;
    align-items:center; gap:12px; font-size:17px; font-weight:600; white-space:nowrap; }
  .caption .n { width:26px; height:26px; border-radius:50%%; background:var(--lime); color:#030303;
    display:flex; align-items:center; justify-content:center; font-size:14px; font-weight:700; }
  .caption > * { white-space:nowrap; flex-shrink:0; }
  .caption .sub { color:var(--muted); font-weight:400; font-size:15px; }
  .bar { height:30px; display:flex; align-items:center; padding:0 12px; gap:7px; position:relative; }
  .bar i { width:11px; height:11px; border-radius:50%%; display:block; }
  .bar i:nth-child(1){background:#ff5f57} .bar i:nth-child(2){background:#febc2e}
  .bar i:nth-child(3){background:#28c840}
  .bar .t { position:absolute; left:0; right:0; text-align:center; font-size:12.5px; pointer-events:none; }
  .card { position:absolute; inset:0; display:flex; flex-direction:column; align-items:center;
    justify-content:center; gap:26px; text-align:center; }
  .card img { height:64px; }
  .card h1 { margin:0; font-size:34px; font-weight:600; letter-spacing:-.02em; line-height:1.25; }
  .card h1 em { font-style:normal; color:var(--lime); }
  .card p { margin:0; font-size:18px; color:var(--muted); line-height:1.5; }
  .card code { font-family:"JetBrains Mono","DejaVu Sans Mono",Menlo,monospace; color:var(--cream);
    background:rgba(196,255,0,.10); padding:3px 9px; border-radius:6px; font-size:13px; }
  .card .tag { font-size:13px; letter-spacing:.08em; text-transform:uppercase; color:var(--muted); }
  .arrow { color:var(--orange); padding:0 6px; }
%(extra)s</style></head>
<body><div class="glow"></div><div id="stage"></div></body></html>
"""


class Recorder:
    """Screenshots stage scenes into numbered PNGs, each held for a duration."""

    def __init__(self, page, frames_dir: Path) -> None:
        self.page = page
        self.dir = frames_dir
        self.frames: list[tuple[Path, float]] = []

    def scene(self, inner_html: str, seconds: float) -> None:
        check_clean(inner_html)
        self.page.evaluate(
            """async (h) => {
                document.getElementById('stage').innerHTML = h;
                await Promise.all([...document.images].map(i => i.decode().catch(() => null)));
            }""",
            inner_html,
        )
        path = self.dir / f"f{len(self.frames):04d}.png"
        self.page.screenshot(path=str(path))
        ticks = max(1, round(seconds / TICK))
        self.frames.append((path, ticks * TICK))

    @property
    def seconds(self) -> float:
        return sum(d for _, d in self.frames)


def play(rec: Recorder, step: Step, feed: list[str]) -> list[str]:
    """Type the step's prompt (when it has one), send it, then reveal its beats."""
    prompt = step.prompt
    if prompt:
        rec.scene(chat_frame(step.cap, feed), 0.4)
        n = min(8, max(3, math.ceil(len(prompt) / 8)))
        for k in range(1, n + 1):
            rec.scene(chat_frame(step.cap, feed, prompt[: math.ceil(len(prompt) * k / n)]), TICK)
        rec.scene(chat_frame(step.cap, feed, prompt), 0.4)
        feed = feed + [user(prompt)]
        rec.scene(chat_frame(step.cap, feed), 0.4)
    for op, item, hold in step.beats:
        feed = feed[:-1] + [item] if op == "set" else feed + [item]
        rec.scene(chat_frame(step.cap, feed), hold)
    return feed


def _title_scene() -> str:
    return (
        f'<div class="card"><img src="{LOGO.as_uri()}" alt="">'
        '<h1>ticket <span class="arrow">&rarr;</span> reviewed answer '
        '<span class="arrow">&rarr;</span> <em>team brain</em></h1>'
        "<p>Open, build, review and ship in Claude Code.<br>"
        "You approve the plan, sign off the numbers, and say when it goes out.</p>"
        '<span class="tag">A rendered walkthrough</span></div>'
    )


def _end_scene() -> str:
    first = "claude plugin marketplace add https://github.com/kyle-chalmers/ticketwright.git"
    second = "claude plugin install ticketwright@ticketwright"
    first, second = first + " --scope project", second + " --scope project"
    return (
        f'<div class="card"><img src="{LOGO.as_uri()}" alt="" style="height:52px">'
        "<h1>Every shipped ticket makes<br>the <em>next one faster</em>.</h1>"
        f"<p><code>{html.escape(first)}</code><br><br><code>{html.escape(second)}</code></p>"
        '<span class="tag">A KC AI Labs project</span></div>'
    )


def stitch(frames: list[tuple[Path, float]], work: Path, out: Path, width: int) -> None:
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        raise SystemExit("ffmpeg not found on PATH")
    listing = work / "frames.txt"
    lines = []
    for path, seconds in frames:
        lines += [f"file '{path.as_posix()}'", f"duration {seconds:.3f}"]
    lines.append(f"file '{frames[-1][0].as_posix()}'")
    listing.write_text("\n".join(lines) + "\n", encoding="utf-8")
    graph = (
        f"fps={FPS},scale={width}:-1:flags=lanczos,split[a][b];"
        "[a]palettegen=max_colors=160:stats_mode=full[p];"
        "[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle"
    )
    subprocess.run(
        [ffmpeg, "-y", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", str(listing)]
        + ["-filter_complex", graph, "-loop", "0", str(out)],
        check=True,
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--work", type=Path, help="Scratch dir for frames (default: a temp dir).")
    parser.add_argument("--out", type=Path, default=OUT)
    parser.add_argument("--width", type=int, default=STAGE_W)
    args = parser.parse_args()

    from playwright.sync_api import sync_playwright

    with tempfile.TemporaryDirectory(prefix="ticketwright-gif-") as tmp:
        work = (args.work or Path(tmp)).resolve()
        frames_dir = work / "frames"
        if frames_dir.exists():
            shutil.rmtree(frames_dir)
        frames_dir.mkdir(parents=True)
        stage = work / "stage.html"
        stage.write_text(
            STAGE_HTML
            % {"w": STAGE_W, "h": STAGE_H, "extra": CSS, "lime": LIME, "orange": ORANGE,
               "cream": CREAM, "muted": MUTED, "bg": BLACK},
            encoding="utf-8",
        )

        with sync_playwright() as pw:
            browser = launch(pw)
            page = browser.new_page(
                viewport={"width": STAGE_W, "height": STAGE_H}, device_scale_factor=1
            )
            route_web_fonts(page)
            page.goto(stage.as_uri(), wait_until="networkidle")
            page.evaluate("document.fonts.ready")
            rec = Recorder(page, frames_dir)
            rec.scene(_title_scene(), 3.0)
            feed: list[str] = []
            for step in STEPS:
                feed = play(rec, step, feed)
            rec.scene(_end_scene(), 3.5)
            browser.close()

        stitch(rec.frames, work, args.out, args.width)
    size = args.out.stat().st_size
    print(
        f"wrote {args.out.name}: {len(rec.frames)} scenes, {rec.seconds:.1f}s, {size / 1e6:.2f} MB"
    )


if __name__ == "__main__":
    main()
