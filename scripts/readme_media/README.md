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
| `docs/images/banner.png`, `lifecycle.png`, `tool-slots.png`, `recall.png`, `ship-steps.png` | `render_diagrams.py` | each `<svg class="diagram">` in `diagrams.html`. The scores in `recall.png` come from the fixture below; `ship-steps.png` is for `docs/ship.md` |
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

`render_diagrams.py` rewrites every diagram, and one whose source did not change can still come out
with different bytes. Commit only the PNGs you meant to change and restore the rest with
`git checkout -- docs/images/<name>.png`. If `uv run` leaves a `uv.lock` at the repo root, delete
it: it is not part of the kit.

## The recall diagram's numbers

Every score, reason and verdict in `recall.png` is what `bin/recall.py` prints for this fixture. The
seed (dana's TEST-130) and the five tracker rows are the ones selftest section 63(b) uses; the four
prior tickets are added here. Run it from the repo root, and redraw the diagram from its output
whenever recall's scoring changes.

```bash
X="$(mktemp -d)"
python3 - "$X" <<'PY'
import json, pathlib, sys
X = pathlib.Path(sys.argv[1])
(X / ".claude/config").mkdir(parents=True)
(X / ".claude/config/stack.yaml").write_text("project:\n  key_prefix: TEST\n")
recs = []
def ticket(owner, key, title, summary, sql, tags, refs=(), day="2024-01-15", objects=(), readme=None):
    d = X / "tickets" / owner / key
    d.mkdir(parents=True)
    (d / "README.md").write_text(f"# {key}: {title}\n\n{readme or summary}\n")
    (d / "q.sql").write_text(sql + "\n")
    recs.append(dict(id=key, owner=owner, title=title, summary=summary, tags=list(tags), cross_refs=list(refs),
                     objects=list(objects), status="Completed", date=day))
ticket("dana", "TEST-130", "Returns rate by region", "Break the returns rate out by region.",  # selftest 63(b)'s seed
       "SELECT * FROM ANALYTICS.RETURNS;", ["returns", "data-quality"], day="2024-05-01",
       objects=["analytics.returns"], readme="Follow-up to TEST-50: break the returns rate out by region.")
ticket("bob", "TEST-118", "Returns baseline", "Weekly returns rate baseline.", "SELECT * FROM ANALYTICS.RETURNS r "
       "JOIN ANALYTICS.ORDERS o ON o.id = r.order_id;", ["returns"], ["TEST-94"], "2024-03-12")
ticket("alice", "TEST-127", "Region mapping", "Map each store to its sales region.", "SELECT * FROM ANALYTICS.REGIONS;",
       ["regions", "data-quality"], day="2024-04-02")
ticket("bob", "TEST-94", "Order volume weekly", "Weekly order counts by region.", "SELECT * FROM ANALYTICS.ORDERS;",
       ["orders"], day="2023-11-20")
ticket("carol", "TEST-102", "Store lookup refresh", "Reload the store list.", "SELECT * FROM ANALYTICS.REGIONS;", ["stores"])
(X / "records.json").write_text(json.dumps({"records": recs}))
row = lambda key, title, text, labels=(): dict(key=key, title=title, description=text, labels=list(labels), created="2023-06-01")
(X / "rows.json").write_text(json.dumps([  # selftest 63(b)'s file_a
    row("TEST-50", "Carrier handoff audit", "Check the handoff times."),
    row("TEST-61", "Dock scheduling cleanup", "Reorder the dock slots.", ["Returns"]),
    row("TEST-130", "Returns rate by region", "This is the repo ticket itself."),
    row("TEST-70", "Region rate drift", "Looking at drift."),
    row("TEST-80", "Payroll tax export", "Quarterly filing.")]))
PY
export CLAUDE_PROJECT_DIR="$X"
python3 bin/ingest_index_records.py --from-json "$X/records.json" && python3 bin/build_ticket_index.py
python3 bin/recall.py --for dana/TEST-130                            # the ranked list and its verdict
python3 bin/recall.py --for dana/TEST-130 --external "$X/rows.json"  # the tracker branch
```

TEST-118's tables are left out of its record on purpose, so the scan of its `q.sql` is what finds
them, as the diagram's left panel says. It should print TEST-118 at 9.0 (`obj:analytics.returns~1.00
tag:returns kw:2`), TEST-127 at 4.0 (`tag:data-quality kw:1`) and TEST-94 at 1.0 (`kw:1`) with
`verdict: strong`, then the tracker's TEST-50 at 5.0 (`ref`), TEST-61 at 3.0 (`tag:returns`) and
TEST-70 at 2.0 (`kw:2`). TEST-130 is left out of the tracker list because it already has a folder,
and TEST-80 because it shares nothing. TEST-102 shares a table only with TEST-127; it is there so
every table appears in at least two tickets, which keeps `analytics.returns` at full weight.

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
