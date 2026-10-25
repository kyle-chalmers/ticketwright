# README media

These scripts make the images the README, the plugin directory listing and the GitHub social
preview use. They are maintainer tools: not part of the kit, not in the PyPI wheel, and not run
in CI. Each one runs with `uv run --with ...`, so nothing is added to `pyproject.toml` and the kit
stays stdlib-only.

| Output | Made by | Source |
|---|---|---|
| `docs/images/logo-light.svg`, `logo-dark.svg` | `brand.py` | the mark geometry in `brand.py`, plus Space Grotesk SemiBold outlined to paths |
| `scripts/readme_media/icon.svg` | `brand.py` | the same mark on a full-bleed black square |
| `.claude-plugin/icon.png` (1024x1024) | `rsvg-convert` | `icon.svg`. The Claude plugin directory takes it as the listing icon once, at the first save in the developer portal. Rendering it again later changes only the repo copy |
| `docs/images/lifecycle.png`, `tool-slots.png` | `render_diagrams.py` | each `<svg class="diagram">` in `diagrams.html` |
| `docs/images/demo.gif` | `render_gif.py` | the scenes in `claude_flow.py` |
| `docs/images/social-preview.png` (1280x640) | `render_social.py` | `social_preview.html`; upload it by hand under Settings, General, Social preview |

## The brand

Ticketwright is a KC AI Labs project, so it uses the kclabs.ai tokens: near-black `#030303` with
`#0a0a0a` and `#141414` cards, lime `#c4ff00` as the accent, cream `#f5f5f5` text and muted
`#b8b8b8`. Orange `#e47d5b` marks only what a person does or approves (the plan approval, the
sign-off, the go-ahead), never decoration. Headings and labels are Space Grotesk, code is
JetBrains Mono. The tokens live in `_common.py`.

The mark is a ticket stub: a check on the ticket for the reviewed work, and an orange dot on the
stub for the one thing a person approves before anything leaves. Lime text on white fails
contrast, so the light logo sets the whole wordmark in black and keeps the lime on the mark.

## Regenerate

Run from the repo root. The browser scripts drive headless Chromium through Playwright: they use
`$TICKETWRIGHT_CHROMIUM` when set (your installed Chrome works, for example
`/Applications/Google Chrome.app/Contents/MacOS/Google Chrome`), then a preinstalled Playwright
browser, and otherwise Playwright's own download (`uv run --with playwright playwright install
chromium`, once). Web fonts come from Google Fonts and fall back to system fonts when offline.

```bash
# Logo and icon. Download the font once; only its glyph outlines are committed.
curl -L -o /tmp/SpaceGrotesk.ttf \
  "https://github.com/google/fonts/raw/main/ofl/spacegrotesk/SpaceGrotesk%5Bwght%5D.ttf"
uv run --with fonttools --with uharfbuzz python scripts/readme_media/brand.py --font /tmp/SpaceGrotesk.ttf
rsvg-convert -w 1024 -h 1024 scripts/readme_media/icon.svg -o .claude-plugin/icon.png

# Diagrams, after editing diagrams.html.
uv run --with playwright --with pillow python scripts/readme_media/render_diagrams.py

# Walkthrough GIF (needs ffmpeg on PATH), after editing claude_flow.py.
uv run --with playwright python scripts/readme_media/render_gif.py

# Social preview.
uv run --with playwright python scripts/readme_media/render_social.py
```

## What each script does

- `brand.py` draws the mark, outlines "Ticketwright" from Space Grotesk SemiBold with HarfBuzz
  shaping, and writes the two logos and the icon source. The SVGs need no font to render. Space
  Grotesk is under the SIL Open Font License; only outlines of its glyphs are committed.
- `render_diagrams.py` screenshots every `<svg class="diagram">` in `diagrams.html` at 2x and
  palette-shrinks any PNG over 400 KB.
- `render_gif.py` plays one ticket through a Claude Code chat: `/ticket` ranks bob's TEST-118 as
  prior work for alice's TEST-130 and waits for plan approval, `/build` runs it, `/review` walks
  the validation pyramid to your sign-off and an APPROVE, and `/ship` shows its delivery plan and
  stops until you say go ahead. It is a **rendered walkthrough, not a screen recording**, and the
  README caption says so. The words in `claude_flow.py` come from the skills' own say-this text,
  so edit `STEPS` when a skill's wording changes. Every scene passes `check_clean()`, which
  refuses home paths, real email addresses and the industry vocabulary selftest section 13b bans.
  It writes a looping 960x600 GIF at 8 fps through an ffmpeg palette (about 34 seconds, about
  0.65 MB). Keep it under 4 MB: the plugin directory stops validating at 5 MiB per file.
- `render_social.py` screenshots `social_preview.html` at 1280x640.
