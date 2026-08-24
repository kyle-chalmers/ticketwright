#!/usr/bin/env python3
"""Render tickets/INDEX.md (the ticket catalog) + tickets/OBJECTS.md (object → tickets reverse index).

Deterministic and LLM-free: safe to run in CI / a pre-commit hook, byte-identical for the
same on-disk state (no timestamps). Good one-line summaries aren't something regex can
write, so the LLM-authored fields (summary / status / best-date / tags) live in
`tickets/index_data.json` — produced by the refresh skill (index mode) / enrich step and
refreshed per ticket at close. This script only *renders* that data and keeps the catalog
complete: every ticket folder on disk gets a row, enriched or not.

What counts as a "ticket" depends on `project.id_mode` in `.claude/config/stack.yaml`:

  keyed (default) — any immediate sub-folder of `tickets/<owner>/` whose name contains a tracker
    key; the prefixes come from `key_prefixes`, else `key_prefix` (default: any `LETTERS-digits`).
    Emoji-prefixed names like "☑️ ENG-12_thing" work too. Folders with no tracker key (adhoc-*,
    scratch-*, ℹ️ …) are reference/scratch work and are skipped.
  slug — the folder NAME is the id, for repos with no tracker at all. Cross-references are then
    only `[[wiki-links]]`, never bare prose (see resolve_cross_refs).

Usage:
  build_ticket_index.py            # (re)write tickets/INDEX.md
  build_ticket_index.py --check    # exit 1 if any RENDERED file is stale vs a fresh render (gate):
                                   # INDEX.md, OBJECTS.md, and the graph nodes when enabled. The
                                   # curated store (index_data.json) is an input, so it isn't gated.
  build_ticket_index.py --stats    # print coverage: enriched / un-enriched / stale / orphans; exit 0
  build_ticket_index.py --prune    # drop orphan curated records (no folder on disk) from the store

Stdlib only.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import statistics
import subprocess
import sys
from datetime import date
from pathlib import Path
from urllib.parse import quote

ISO_DATE = re.compile(r"\b(\d{4})-(\d{2})-(\d{2})\b")
# A README date counts as a completion date only on a completion/delivery line (avoids grabbing
# unrelated dates like a contract end-date).
COMPLETION_HINT = re.compile(
    r"complet|deploy|deliver|filed|shipped|merged|go.?live|sold|placement|"
    r"as.?of|update|follow.?up|status|done|closed",
    re.IGNORECASE,
)
EMOJI_STATUS = {"☑️": "Completed", "\U0001f6e0️": "In Progress"}  # ☑️ / 🛠️
SUMMARY_MAX = 180
STATUS_ORDER = ["Deployed", "Completed", "In Review", "In Progress", "Blocked", "Unknown"]

# ── Obsidian graph-view auto-config (.obsidian/graph.json) ─────────────────────────────────────
# The renderer owns exactly two things in graph.json: the `search` filter and its two color groups
# (keyed by these constant query strings). It creates the file if missing and re-creates those
# managed pieces if deleted, but preserves every other key (forces, zoom, display toggles) and any
# color group the user adds. Positive filter → the Graph view opens on JUST the tickets↔objects web.
OBSIDIAN_TICKET_QUERY = 'path:"tickets/graph/"'      # ticket nodes live here
OBSIDIAN_OBJECT_QUERY = 'path:"tickets/objects/"'    # object nodes live here (trailing / ≠ tickets/OBJECTS.md)
OBSIDIAN_SEARCH = f"{OBSIDIAN_TICKET_QUERY} OR {OBSIDIAN_OBJECT_QUERY}"
OBSIDIAN_MANAGED_QUERIES = {OBSIDIAN_TICKET_QUERY, OBSIDIAN_OBJECT_QUERY}
# Search values we authored and may refresh; any other non-empty `search` is a user edit we leave.
# On a future filter change, add the old value here so upgrades migrate cleanly (not treated as manual).
OBSIDIAN_KNOWN_SEARCHES = {OBSIDIAN_SEARCH}
OBSIDIAN_TICKET_RGB = 12910336   # #C4FF00 lime  — ticket nodes (kclabs.ai brand green)
OBSIDIAN_OBJECT_RGB = 14974299   # #E47D5B coral — object nodes (kclabs.ai accent)


def repo_root() -> Path:
    # TICKETWRIGHT_PROJECT is the harness-neutral spelling (bin/kit_paths.py --project agrees);
    # CLAUDE_PROJECT_DIR is still honored so existing installs keep working. Read inline rather than
    # imported: selftest fixtures copy this script on its own, so a sibling import would break them.
    for var in ("TICKETWRIGHT_PROJECT", "CLAUDE_PROJECT_DIR"):
        if os.environ.get(var):
            return Path(os.environ[var]).resolve()
    try:  # run by hand from inside a repo (no env var) → prefer the actual repo, not the kit dir
        top = subprocess.run(["git", "rev-parse", "--show-toplevel"],
                             capture_output=True, text=True).stdout.strip()
        if top:
            return Path(top).resolve()
    except OSError:
        pass
    return Path(__file__).resolve().parent.parent  # bin/ -> repo root (last resort)


def _yaml_list(text: str, key: str) -> list[str]:
    """Parse a scalar YAML list (inline `[a, b]` or block `- a`) for one key. Regex-only (stdlib)."""
    m = re.search(rf"^\s*{re.escape(key)}:\s*\[([^\]]*)\]", text, re.MULTILINE)
    if m:
        return [p.strip().strip("\"'") for p in m.group(1).split(",") if p.strip()]
    out, lines = [], text.splitlines()
    for i, ln in enumerate(lines):
        if re.match(rf"^\s*{re.escape(key)}:\s*$", ln):
            for nxt in lines[i + 1:]:
                mm = re.match(r"^\s*-\s*[\"']?([^\"'#\s][^\"'#]*?)[\"']?\s*(?:#.*)?$", nxt)
                if mm:
                    out.append(mm.group(1).strip())
                elif nxt.strip() == "":
                    continue
                else:
                    break
            break
    return out


def load_config(root: Path) -> dict:
    """The few fields the index needs, read through the three-tier resolver.

    Every key here lives under `project.*`, which the resolver reserves to tier 1 — so today this
    returns exactly what the regex reader returned. That is the point: ONE code path for config,
    with no behavior change to prove. It also migrates recall.py, ingest_index_records.py,
    enrich_ticket.py, regenerate_ticket_index.py and ticket_index_context.py, none of which read
    stack.yaml any other way and none of which need editing.

    Contract this must never break: all six keys are always present (callers index with `[]`, not
    `.get()`), and this NEVER raises or exits — the resolver's exit codes are its CLI surface only.
    """
    cfg = {"prefixes": [], "url_template": None, "graph_notes": True, "graph_config": True,
           "ticket_subdirs": [], "id_mode": "keyed"}
    try:
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        from effective_config import resolve  # type: ignore
        project = resolve(root).project
    except Exception:  # noqa: BLE001 — see the fallback's docstring; a hook must never hard-fail
        return _load_config_regex(root)
    if not isinstance(project, dict):
        return _load_config_regex(root)

    prefixes = project.get("key_prefixes")
    if isinstance(prefixes, list):
        cfg["prefixes"] = [str(p).strip() for p in prefixes if str(p).strip()]
    elif isinstance(prefixes, str) and prefixes.strip():
        cfg["prefixes"] = [prefixes.strip()]
    if not cfg["prefixes"]:
        one = project.get("key_prefix")
        if one is not None and str(one).strip():
            cfg["prefixes"] = [str(one).strip()]

    url = project.get("ticket_url_template")
    if url is not None and str(url).strip() and str(url).strip().lower() != "null":
        cfg["url_template"] = str(url).strip()

    for key in ("graph_notes", "graph_config"):
        val = project.get(key)
        if val is not None and str(val).strip().lower() in ("false", "no", "off", "0"):
            cfg[key] = False

    subdirs = project.get("ticket_subdirs")
    if isinstance(subdirs, list):
        cfg["ticket_subdirs"] = [str(d).strip() for d in subdirs if str(d).strip()]

    if str(project.get("id_mode", "")).strip().lower() == "slug":
        cfg["id_mode"] = "slug"
    return cfg


def _load_config_regex(root: Path) -> dict:
    """The pre-resolver reader: narrow regexes over stack.yaml, kept as the FALLBACK.

    Retained deliberately. `load_config` is reached by two SessionStart/PostToolUse hooks
    (regenerate_ticket_index, ticket_index_context) and hooks must fail open, so a repo whose
    stack.yaml uses a construct outside the resolver's supported subset — an anchor, say, which
    yq and these regexes both read fine — must keep rendering its catalog rather than becoming
    a hard "malformed config" error.
    """
    cfg = {"prefixes": [], "url_template": None, "graph_notes": True, "graph_config": True,
           "ticket_subdirs": [], "id_mode": "keyed"}
    f = root / ".claude" / "config" / "stack.yaml"
    if not f.is_file():
        return cfg
    text = f.read_text(errors="replace")
    m = re.search(r"^\s*key_prefixes:\s*\[([^\]]*)\]", text, re.MULTILINE)
    if m:
        cfg["prefixes"] = [p.strip().strip("\"'") for p in m.group(1).split(",") if p.strip()]
    if not cfg["prefixes"]:
        # block-list form:  key_prefixes:\n  - ENG\n  - OPS
        lines = text.splitlines()
        for i, ln in enumerate(lines):
            if re.match(r"^\s*key_prefixes:\s*$", ln):
                for nxt in lines[i + 1:]:
                    mm = re.match(r"^\s*-\s*[\"']?([A-Za-z0-9_-]+)", nxt)
                    if mm:
                        cfg["prefixes"].append(mm.group(1))
                    elif nxt.strip() == "":
                        continue
                    else:
                        break
                break
    if not cfg["prefixes"]:
        m = re.search(r"^\s*key_prefix:\s*[\"']?([A-Za-z0-9_-]+)", text, re.MULTILINE)
        if m:
            cfg["prefixes"] = [m.group(1)]
    m = re.search(r"^\s*ticket_url_template:\s*(.+)$", text, re.MULTILINE)
    if m:
        # strip only a whitespace-preceded inline comment (YAML rule), so a '#fragment' in the URL survives
        v = re.sub(r"\s+#.*$", "", m.group(1)).strip().strip("\"'")
        if v and v.lower() != "null":
            cfg["url_template"] = v
    m = re.search(r"^\s*graph_notes:\s*(\S+)", text, re.MULTILINE)
    if m and m.group(1).strip().strip("\"'").lower() in ("false", "no", "off", "0"):
        cfg["graph_notes"] = False
    # graph_config: whether to also write/merge .obsidian/graph.json (default on; independent opt-out)
    m = re.search(r"^\s*graph_config:\s*(\S+)", text, re.MULTILINE)
    if m and m.group(1).strip().strip("\"'").lower() in ("false", "no", "off", "0"):
        cfg["graph_config"] = False
    cfg["ticket_subdirs"] = _yaml_list(text, "ticket_subdirs")
    # id_mode: `keyed` (default) = folder names carry a tracker key like ENG-1234.
    #          `slug`            = the folder name IS the id, for repos with no tracker at all.
    m = re.search(r"^\s*id_mode:\s*[\"']?([A-Za-z_-]+)", text, re.MULTILINE)
    if m and m.group(1).strip().lower() == "slug":
        cfg["id_mode"] = "slug"
    return cfg


# A slug id is the whole folder name: lowercase, digit- or letter-initial, no spaces. Restrictive on
# purpose — the id doubles as a git branch name, a filename and a wiki-link target. Dots are excluded
# rather than allowed-and-filtered: `git check-ref-format` rejects `a..b`, a trailing `.`, and a
# `.lock` suffix, and excluding `.` outright rules out all three without special cases.
SLUG_ID = re.compile(r"^[a-z0-9][a-z0-9_-]*$")

# A wiki-link shown as an example is not a reference, so code gets blanked before scanning.
_INLINE_CODE = re.compile(r"(`+)[\s\S]*?\1")
# Leading blockquote markers and list bullets, so a fence nested in either is still seen as a fence.
_CONTAINER_PREFIX = re.compile(r"^[ \t]*(?:>[ \t]*)*(?:[-*+][ \t]+|\d+[.)][ \t]+)?")
_FENCE_MARK = re.compile(r"([`~])\1{2,}")


def _strip_code(text: str) -> str:
    """Blank out code spans and fenced blocks so an example wiki-link isn't read as a reference.

    A line scanner rather than a regex: it handles fences of either character and any length, a
    closing fence longer than its opener, an unclosed fence (blanks to end of file), and fences
    nested inside a blockquote or list item — each of which defeated a separate regex attempt.

    Deliberately a heuristic, not a Markdown parser. Indented code blocks are **not** stripped: four
    leading spaces is far more often list-continuation or a wrapped line than code, and treating it
    as code silently drops real links. The asymmetry is intentional — for a payload whose cost is one
    row in `OBJECTS.md`, missing a real edge is worse than keeping a stray one.
    """
    out: list[str] = []
    fence: tuple[str, int] | None = None
    for ln in text.splitlines():
        body = _CONTAINER_PREFIX.sub("", ln)
        m = _FENCE_MARK.match(body)
        if fence is None:
            if m:
                fence = (m.group(1), len(m.group(0)))
                out.append("")
            else:
                out.append(_INLINE_CODE.sub(" ", ln))
        else:
            char, length = fence
            closes = (m and m.group(1) == char and len(m.group(0)) >= length
                      and not body[len(m.group(0)):].strip())
            if closes:
                fence = None
            out.append("")
    return "\n".join(out)


def strip_status_emoji(name: str) -> tuple[str, str | None]:
    """Split a leading status emoji off a folder name → (remainder, mapped status or None)."""
    for k, v in EMOJI_STATUS.items():
        if name.startswith(k):
            return name[len(k):].strip(), v
    return name, None


def key_regex(prefixes: list[str]) -> re.Pattern:
    if prefixes:
        return re.compile(rf"(?:{'|'.join(re.escape(p) for p in prefixes)})-\d+")
    return re.compile(r"[A-Z][A-Z0-9]+-\d+")  # generic fallback when stack.yaml is absent


NEVER = re.compile(r"(?!x)x")   # matches nothing


def id_key_regex(cfg: dict) -> re.Pattern:
    """The pattern that decides which ids carry a tracker number.

    In slug mode the answer is always "none of them". A folder name is free to look exactly like a
    key (`a-1`), and a repo may still carry a stale `key_prefix` from before it went trackerless — so
    the configured prefixes are not evidence that an id is keyed. Returning a never-matching pattern
    is safe because slug mode uses `key_re` for nothing else: discovery matches `SLUG_ID`, and
    cross-references are wiki-links.
    """
    return NEVER if cfg.get("id_mode") == "slug" else key_regex(cfg["prefixes"])


def title_prefix_regex(prefixes: list[str]) -> re.Pattern:
    alt = "|".join(re.escape(p) for p in prefixes) if prefixes else r"[A-Z][A-Z0-9]+"
    return re.compile(rf"^(?:{alt})-\d+\S*\s*[:\-–—]\s*")


def ticket_url(template: str | None, tid: str, key_re: re.Pattern | None = None) -> str | None:
    # {id} = full key (e.g. ENG-12); {number} = trailing integer (e.g. 12), for trackers whose
    # native id is a bare number (Azure Boards, GitHub Issues) even when folders use a prefix.
    if not template:
        return None
    return template.replace("{id}", tid).replace("{number}", str(ticket_number(tid, key_re)))


def ticket_number(tid: str, key_re: re.Pattern | None = None) -> int:
    """The integer part of a tracker key, or 0 when the id isn't one.

    Pass `key_re` (from `key_regex`) to make this strict: the id must *fully* match it to have a
    number. That matters because a bare `re.search` for `-\\d+` finds digits anywhere, so a slug id
    like `signup-funnel-lift-2024` reads as ticket 2024 and sorts among real keys.

    `key_re` rather than a shape test or a mode flag, because it is already the authority on what a
    keyed id looks like. No hardcoded shape can do the job: a configured prefix may contain `_` or
    `-` or start with a digit (`ACME_US-42`, `ACME-WEST-42`, `1ENG-42`), while a slug is free to look
    exactly like a key (`a-1`). Only the configured prefixes distinguish them.

    Omitting `key_re` keeps the original loose behavior, so callers that don't have one are unchanged.
    """
    if key_re is not None and not key_re.fullmatch(tid):
        return 0
    m = re.search(r"-(\d+)", tid)
    return int(m.group(1)) if m else 0


def ref_key(tid: str, key_re: re.Pattern | None = None):
    """Total order for ids: tracker number first (so ENG-12 vs OPS-12 is stable), then the id
    itself — which is what orders slug ids, since they all score 0."""
    return (ticket_number(tid, key_re), tid)


def sha256_file(path: Path) -> str | None:
    try:
        return hashlib.sha256(path.read_bytes()).hexdigest()
    except OSError:
        return None


# Qualified SQL object refs in a ticket's code. Keyword-anchored for PRECISION: it matches
# `FROM schema.obj` / `JOIN db.schema.obj` even inside a SQL string in a .py file, but NOT
# `os.path.join` / `df.merge` (no FROM/JOIN/… keyword precedes them).
SQL_OBJECT = re.compile(
    r"(?i)\b(?:from|join|into|update|table|view)\s+([A-Za-z_]\w*(?:\.[A-Za-z_]\w+){1,2})"
)
# Python `from pkg.mod import ...` / `import pkg.mod` share the SQL `from` keyword — skip those lines
# so `from os.path import join` doesn't get logged as a data object.
PY_IMPORT = re.compile(r"^\s*(?:from\s+\S+\s+import\b|import\s)")


def extract_objects(ticket_dir: Path, cap: int = 40) -> list[str]:
    """Best-effort deterministic object refs from a ticket's *.sql/*.py (qualified names only)."""
    found: dict[str, str] = {}  # case-insensitive key -> first-seen form
    for pat in ("*.sql", "*.py"):
        for f in sorted(ticket_dir.rglob(pat)):
            try:
                txt = f.read_text(errors="replace")
            except OSError:
                continue
            for line in txt.splitlines():
                if PY_IMPORT.match(line):
                    continue  # Python import — not a data object
                for name in SQL_OBJECT.findall(line):
                    found.setdefault(name.lower(), name)
    return sorted(found.values(), key=str.lower)[:cap]


def find_readme(ticket_dir: Path, subdirs: list[str] | None = None) -> Path | None:
    """Locate a ticket's README. A repo's convention may differ from "root README.md" (e.g. the
    README lives in final_deliverables/) — coverage + enrichment must follow the same rule
    everywhere. Order: ticket root -> each configured `project.ticket_subdirs` -> the first
    README*.md within bounded depth (<=2). Deterministic (sorted). None if the folder has none."""
    root = ticket_dir / "README.md"
    if root.is_file():
        return root
    for sub in (subdirs or []):
        cand = ticket_dir / sub / "README.md"
        if cand.is_file():
            return cand
    hits = sorted(p for p in ticket_dir.rglob("README*.md")
                  if p.is_file() and len(p.relative_to(ticket_dir).parts) <= 2)
    return hits[0] if hits else None


def discover(root: Path, key_re: re.Pattern | None = None, subdirs: list[str] | None = None,
             id_mode: str | None = None) -> list[dict]:
    """Every ticket folder, one level under tickets/<owner>/. Cheap (few file reads).

    In `keyed` mode a folder qualifies by containing a tracker key, and the *matched key* is the id
    (so `☑️ ENG-12 signup lift` → `ENG-12`). In `slug` mode the whole folder name is the id, so a repo
    with no tracker at all still gets a catalog.
    """
    if key_re is None or subdirs is None or id_mode is None:
        cfg = load_config(root)
        if key_re is None:
            key_re = key_regex(cfg["prefixes"])
        if subdirs is None:
            subdirs = cfg["ticket_subdirs"]
        if id_mode is None:
            id_mode = cfg["id_mode"]
    out: dict[tuple[str, str], dict] = {}
    tickets = root / "tickets"
    if not tickets.is_dir():
        return []
    for owner_dir in sorted(p for p in tickets.iterdir() if p.is_dir()):
        owner = owner_dir.name
        for d in sorted(p for p in owner_dir.iterdir() if p.is_dir()):
            bare, emoji = strip_status_emoji(d.name)
            if id_mode == "slug":
                if not SLUG_ID.match(bare):
                    continue
                tid = bare
            else:
                m = key_re.search(d.name)
                if not m:
                    continue
                tid = m.group(0)
            # Two folders can reduce to one id — `foo` and `☑️ foo`. The later one wins
            # (deterministic by sort order), but say so, or a ticket that exists on disk just isn't in
            # the catalog with nothing to explain why. Slug mode only: keyed mode has always collapsed
            # `ENG-12 a` / `ENG-12 b` silently and this change promises keyed behaviour is untouched.
            prior = out.get((owner, tid))
            if prior is not None and id_mode == "slug":
                print(f"build_ticket_index: {owner}/{tid}: two folders map to one id — "
                      f"'{prior['dir'].name}' and '{d.name}'; using the latter",
                      file=sys.stderr)
            out[(owner, tid)] = {
                "owner": owner, "id": tid, "dir": d,
                "readme": find_readme(d, subdirs), "emoji_status": emoji,
            }
    return list(out.values())


def split_ref(ref: str) -> tuple[str | None, str]:
    """Normalize one cross-ref string against the ticket locator grammar: `owner/id` → (owner, id);
    a bare `id` → (None, id). The single authority on the qualified form — recall.py imports it,
    so the parser, the graph renderer and recall scoring can never disagree on what qualifies."""
    if "/" in ref:
        owner, tid = ref.split("/", 1)
        if owner and tid:
            return owner, tid
    return None, ref


def _ref_sort_key(ref: str, key_re: re.Pattern | None = None):
    owner, tid = split_ref(ref)
    return (ticket_number(tid, key_re), tid, owner or "")


WIKI_LINK = re.compile(r"(?<!\\)\[\[[ \t]*([^\]|#\n]+?)[ \t]*(?:[|#][^\]\n]*)?\]\]")


def resolve_cross_refs(text: str, self_id: str, key_re: re.Pattern,
                       id_mode: str = "keyed", known_ids: set[str] | None = None,
                       self_owner: str | None = None,
                       known_pairs: set[tuple[str, str]] | None = None) -> list[str]:
    """The ticket ids a README references — bare (`ENG-12`) or owner-qualified (`alice/ENG-12`).

    Discovery and cross-reference resolution look like one job and are not — this is the one place
    where sharing a pattern between them is actively wrong.

    A tracker key (`ENG-1234`) is self-evidently a reference wherever it appears, so `keyed` mode
    pattern-matches the prose and can legitimately name a ticket that has no folder here.

    A slug has no such shape. Any pattern loose enough to match a folder called `signup-funnel-lift` also
    matches ordinary English, so pattern-matching prose in slug mode would turn stray words into
    `OBJECTS.md` rows and graph edges. A ticket is free to be named after an ordinary phrase
    (`data-quality`), so bare prose mentions deliberately never count.

    Slug mode therefore recognizes **exactly one** form: a `[[wiki-link]]` naming a known id. That is
    the form the graph layer itself emits and what an Obsidian user types, so it costs almost nothing
    to require.

    OWNER-QUALIFIED REFERENCES (both modes, when `known_pairs` is supplied): a wiki-link whose last
    two path segments name an existing (owner, id) pair — `[[bob/ENG-1]]`, `[[tickets/bob/ENG-1]]` —
    is recorded as the qualified `bob/ENG-1`, honoring the owner the author explicitly wrote instead
    of re-deriving it later. The decision is PER LINK: a separate bare `[[chargeback-lift]]` next to a
    qualified `[[bob/chargeback-lift]]` is its own deliberate reference and both survive. In keyed
    mode a bare pattern hit is dropped when a qualified ref names the same id, because the qualified
    link's own text contains the key and the pattern scan cannot tell the two apart. Keyed refs may
    always name a ticket with no folder here, and qualified ones keep that: `[[bob/ENG-999]]` stays
    `bob/ENG-999` when `bob` is a KNOWN OWNER and the id is a full tracker key, folder or not. Any
    other `a/b` target falls through to the old leaf-reduction, so path-style links like
    `[[graph/notes]]` keep resolving exactly as before; slug mode requires the pair to exist, since
    a slug ref has no meaning without its folder.

    It is deliberately this narrow. Three successive attempts tried to also honour markdown link
    destinations — first by pattern (leaked images, external URLs, escaped brackets), then by
    resolving destinations on disk (leaked non-existent paths, symlinked trees, angle-bracket
    destinations). Each round of hardening bought a smaller correctness gain than the complexity it
    added, for a payload whose entire cost of being wrong is a spurious row in `OBJECTS.md` and a
    stray edge in a graph view. One unambiguous marker beats an approximate Markdown parser: an edge
    now requires an author to have actually written a link, and cannot be manufactured by prose.
    """
    known = {i for i in (known_ids or ()) if i != self_id}
    pairs = known_pairs or set()
    owners = {o for (o, _) in pairs}
    qualified: set[str] = set()
    found: set[str] = set()
    # `(?<!\\)` so an escaped `\[[notes]]` stays literal text. Optional `|alias` / `#heading` are
    # Obsidian syntax; the target may be written as a path or with a `.md` suffix.
    scan = _strip_code(text)          # a wiki-link inside an example isn't a reference
    for m in WIKI_LINK.finditer(scan):
        t = m.group(1).strip()
        t = t[:-3] if t.endswith(".md") else t
        parts = t.split("/")
        if len(parts) >= 2:
            pair = (parts[-2], parts[-1])
            is_qualified = pair in pairs or (
                id_mode != "slug" and parts[-2] in owners and key_re.fullmatch(parts[-1]))
            if is_qualified:
                if pair != (self_owner, self_id):
                    qualified.add(f"{pair[0]}/{pair[1]}")
                continue  # consumed as qualified — its leaf is not ALSO a bare reference
        if id_mode == "slug" and parts[-1] in known:
            found.add(parts[-1])

    if id_mode != "slug":
        qualified_ids = {split_ref(q)[1] for q in qualified}
        bare = {r for r in key_re.findall(text) if r != self_id and r not in qualified_ids}
        return sorted(bare | qualified, key=lambda i: _ref_sort_key(i, key_re))
    return sorted(found | qualified, key=lambda i: _ref_sort_key(i, key_re))


def parse_readme(path: Path, self_id: str, key_re: re.Pattern, title_re: re.Pattern,
                 id_mode: str = "keyed", known_ids: set[str] | None = None,
                 self_owner: str | None = None,
                 known_pairs: set[tuple[str, str]] | None = None) -> dict:
    """Deterministic fallback extraction for un-enriched tickets."""
    try:
        text = path.read_text(errors="replace")
    except OSError:
        return {"title": None, "date": None, "summary": None, "cross_refs": []}
    lines = text.splitlines()

    title, h1_idx = None, None
    for i, ln in enumerate(lines):
        mm = re.match(r"^#\s+(.*\S)\s*$", ln)
        if mm:
            title = title_re.sub("", mm.group(1)).strip()
            # Slug mode strips the id prefix against this ticket's *literal* id rather than a
            # generic pattern — `# data-quality: what we found` must keep its title when
            # `data-quality` isn't this ticket, so a regex over any `word-word:` won't do.
            if id_mode == "slug":
                for sep in (":", "-", "–", "—"):
                    pre = f"{self_id}{sep}"
                    if title.lower().startswith(pre.lower()):
                        title = title[len(pre):].strip()
                        break
            h1_idx = i
            break

    dates = []
    for ln in lines:
        if not COMPLETION_HINT.search(ln):
            continue
        for y, mo, da in ISO_DATE.findall(ln):
            if not (2000 <= int(y) <= 2100):  # drop sentinels like 2999-12-31
                continue
            try:
                dates.append(date(int(y), int(mo), int(da)).isoformat())
            except ValueError:
                pass
    best_date = max(dates) if dates else None

    summary = None
    skip = ("#", ">", "-", "*", "|", "`", "!", "=", "~")
    for ln in lines[(h1_idx + 1) if h1_idx is not None else 0:]:
        s = ln.strip()
        if not s or s.startswith(skip) or s.startswith("**") or s == "---":
            continue
        s = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", s)
        s = re.sub(r"[*_`]", "", s).strip()
        if len(s) < 12:
            continue
        summary = (s[: SUMMARY_MAX - 1].rstrip() + "…") if len(s) > SUMMARY_MAX else s
        break

    refs = resolve_cross_refs(text, self_id, key_re, id_mode, known_ids, self_owner, known_pairs)
    return {"title": title, "date": best_date, "summary": summary, "cross_refs": refs}


def load_data(root: Path) -> dict[tuple[str, str], dict]:
    """Load the enrichment store. Missing file is fine; a malformed one fails closed."""
    f = root / "tickets" / "index_data.json"
    if not f.is_file():
        return {}
    try:
        data = json.loads(f.read_text())
    except (OSError, json.JSONDecodeError) as e:
        sys.exit(f"ERROR: tickets/index_data.json is unreadable/malformed ({e}). Fix or remove it.")
    if not isinstance(data, dict) or not isinstance(data.get("tickets"), list):
        sys.exit("ERROR: tickets/index_data.json must be an object with a 'tickets' list.")
    out = {}
    for t in data["tickets"]:
        if isinstance(t, dict) and isinstance(t.get("owner"), str) and isinstance(t.get("id"), str):
            out[(t["owner"], t["id"])] = t
    return out


def find_orphans(root: Path, rows: list[dict]) -> list[str]:
    """Curated store records (index_data.json) with no ticket folder on disk — silent drift the
    catalog otherwise hides (a folder renamed/deleted after its record was written)."""
    on_disk = {(r["owner"], r["id"]) for r in rows}
    return sorted(f"{o}/{i}" for (o, i) in load_data(root) if (o, i) not in on_disk)


def build_rows(root: Path) -> list[dict]:
    cfg = load_config(root)
    key_re = id_key_regex(cfg)
    title_re = title_prefix_regex(cfg["prefixes"])
    data = load_data(root)
    rows = []
    tickets = discover(root, key_re, cfg["ticket_subdirs"], cfg["id_mode"])
    # Slug mode resolves cross-refs by identity, not by pattern, so it needs the full id set up front.
    known_ids = {t["id"] for t in tickets} if cfg["id_mode"] == "slug" else None
    # Both modes recognize owner-qualified wiki-links, so both need the (owner, id) pairs.
    known_pairs = {(t["owner"], t["id"]) for t in tickets}
    for t in tickets:
        owner, tid, d, readme = t["owner"], t["id"], t["dir"], t["readme"]
        entry = data.get((owner, tid))
        parsed = parse_readme(readme, tid, key_re, title_re, cfg["id_mode"], known_ids, owner, known_pairs) \
            if readme else {"title": None, "date": None, "summary": None, "cross_refs": []}
        cur_hash = sha256_file(readme) if readme else None

        title = parsed["title"] or (entry or {}).get("title") or tid
        enriched = bool(entry and entry.get("summary"))
        stale = bool(
            entry and entry.get("summary") and readme and entry.get("readme_hash") and cur_hash
            and entry["readme_hash"] != cur_hash
        )
        if entry and entry.get("summary"):
            summary = entry["summary"]
            status = entry.get("status") or t["emoji_status"] or "Unknown"
            date_val = entry.get("date") or parsed["date"]
            tags = entry.get("tags") or []
        else:
            summary = parsed["summary"] or "—"
            status = t["emoji_status"] or "Unknown"
            date_val = parsed["date"]
            tags = []
        if entry and entry.get("cross_refs"):
            cross_refs = entry["cross_refs"]
        elif readme:
            cross_refs = parsed["cross_refs"]
        else:
            cross_refs = []
        # objects = enriched (LLM) ∪ deterministic grep of the ticket's SQL/py; case-insensitive dedup.
        obj_map: dict[str, str] = {}
        for o in list((entry or {}).get("objects") or []) + extract_objects(d):
            if isinstance(o, str) and o.strip():
                obj_map.setdefault(o.strip().lower(), o.strip())
        objects = sorted(obj_map.values(), key=str.lower)
        url = (entry or {}).get("ticket_url") or (entry or {}).get("jira_url") or ticket_url(cfg["url_template"], tid, key_re)
        rel = d.relative_to(root / "tickets").as_posix()
        link = quote(readme.relative_to(root / "tickets").as_posix()) if readme else quote(rel) + "/"

        rows.append({
            "owner": owner, "id": tid, "title": title, "status": status, "date": date_val,
            "summary": summary, "tags": tags, "cross_refs": cross_refs, "objects": objects, "url": url,
            "link": link, "enriched": enriched, "stale": stale, "has_readme": bool(readme),
        })
    rows.sort(key=lambda r: ((r["date"] or "0000-00-00"), ticket_number(r["id"], key_re), r["id"], r["owner"]), reverse=True)
    return rows


def md_escape(s) -> str:
    return (str(s) if s is not None else "").replace("|", "\\|").replace("\n", " ").strip()


def render(rows: list[dict]) -> str:
    by_status: dict[str, int] = {}
    by_owner: dict[str, int] = {}
    for r in rows:
        by_status[r["status"]] = by_status.get(r["status"], 0) + 1
        by_owner[r["owner"]] = by_owner.get(r["owner"], 0) + 1
    extra_status = sorted(s for s in by_status if s not in STATUS_ORDER)
    status_line = " · ".join(f"{s} {by_status[s]}" for s in (STATUS_ORDER + extra_status) if by_status.get(s))
    owner_line = " · ".join(f"{o} {n}" for o, n in sorted(by_owner.items(), key=lambda kv: (-kv[1], kv[0])))
    un_enriched = sum(1 for r in rows if not r["enriched"])
    stale = sum(1 for r in rows if r["stale"])

    out = []
    out.append("<!-- GENERATED by bin/build_ticket_index.py from tickets/index_data.json — DO NOT EDIT BY HAND.")
    out.append("     Re-run `python3 bin/build_ticket_index.py` after adding or closing a ticket. -->")
    out.append("")
    out.append("# Ticket Index")
    out.append("")
    out.append(f"**{len(rows)} tickets**" + (f" · {status_line}" if status_line else ""))
    if by_owner:
        out.append("")
        out.append(f"By owner: {owner_line}")
    if un_enriched or stale:
        notes = []
        if un_enriched:
            notes.append(f"{un_enriched} not yet enriched (▱)")
        if stale:
            notes.append(f"{stale} summary may be stale (⚠)")
        out.append("")
        out.append("Coverage: " + " · ".join(notes) + ". Run /refresh index to update.")
    out.append("")
    out.append("> **For the agent:** this is the catalog of all prior ticket work in this repo. Before "
               "starting a ticket, grep here for earlier work on the same object / stakeholder / report — "
               "reuse it. `Refs` links related tickets. `⚠` = README changed since the summary was written; "
               "`▱` = summary auto-derived, not yet curated.")
    out.append("")
    out.append("| Ticket | Date | Status | Summary | Tags | Refs | Owner |")
    out.append("|---|---|---|---|---|---|---|")
    for r in rows:
        flag = (" ⚠" if r["stale"] else "") + (" ▱" if not r["enriched"] else "")
        link = f"[{r['id']}]({r['link']})"
        if r["url"]:
            link += f" [↗]({r['url']})"
        ticket_cell = f"{link}{flag}"
        date_cell = r["date"] or "—"
        title = md_escape(r["title"])
        summary = md_escape(r["summary"])
        summary_cell = f"**{title}** — {summary}" if title and title != r["id"] else summary
        tags_cell = " ".join(f"`{md_escape(t)}`" for t in r["tags"]) or "—"
        refs_cell = ", ".join(r["cross_refs"]) if r["cross_refs"] else "—"
        out.append(f"| {ticket_cell} | {date_cell} | {r['status']} | {summary_cell} | {tags_cell} | {refs_cell} | {r['owner']} |")
    out.append("")
    return "\n".join(out)


def render_objects(rows: list[dict], collapse_threshold: int = 150,
                   key_re: re.Pattern | None = None) -> str:
    """Reverse index: data object → tickets that touched it. Deterministic, byte-stable.
    Above collapse_threshold distinct objects, single-ticket objects move to a compact appendix so the
    shared-object table stays scannable — the full data still lives in index_data.json + the appendix."""
    obj: dict[str, dict] = {}  # case-insensitive key -> {"label": display form, "tickets": [rows]}
    owners_by_id: dict[str, set] = {}  # id -> owners; a shared id is labeled by its owner/id locator
    for r in rows:
        owners_by_id.setdefault(r["id"], set()).add(r["owner"])
        for o in r.get("objects", []):
            slot = obj.setdefault(o.lower(), {"label": o, "tickets": []})
            slot["tickets"].append(r)
    items = sorted(obj.items(), key=lambda kv: (-len(kv[1]["tickets"]), kv[0]))
    shared = [(k, s) for k, s in items if len(s["tickets"]) > 1]

    out = []
    out.append("<!-- GENERATED by bin/build_ticket_index.py from tickets/index_data.json + ticket SQL — DO NOT EDIT BY HAND.")
    out.append("     Re-run `python3 bin/build_ticket_index.py` after adding or closing a ticket. -->")
    out.append("")
    out.append("# Object Index")
    out.append("")
    out.append(f"**{len(obj)} data objects** referenced across the ticket archive "
               f"({len(shared)} shared by >1 ticket) — the reverse of `INDEX.md`.")
    out.append("")
    out.append("> **For the agent:** before changing a view/table, grep here for every ticket that read or wrote it.")
    out.append("")
    if not obj:
        out.append("_No object references found yet — objects come from ticket SQL + enrichment._")
        out.append("")
        return "\n".join(out)

    def cells_for(slot):
        ts = sorted(slot["tickets"], key=lambda r: (ref_key(r["id"], key_re), r["owner"]))
        def label(t):  # bare id while unambiguous; the owner/id locator once two owners share it
            return f"{t['owner']}/{t['id']}" if len(owners_by_id.get(t["id"], ())) > 1 else t["id"]
        return ts, ", ".join(f"[{label(t)}]({t['link']})" for t in ts)

    collapse = len(obj) > collapse_threshold
    out.append("| Object | Tickets |")
    out.append("|---|---|")
    for _, slot in (shared if collapse else items):
        ts, cells = cells_for(slot)
        out.append(f"| `{md_escape(slot['label'])}` | {cells} ({len(ts)}) |")
    out.append("")
    if collapse:
        singles = [(k, s) for k, s in items if len(s["tickets"]) == 1]
        out.append(f"### Single-ticket objects ({len(singles)})")
        out.append("")
        for _, slot in singles:
            ts, cells = cells_for(slot)
            out.append(f"- `{md_escape(slot['label'])}` — {cells}")
        out.append("")
    return "\n".join(out)


def object_filename(obj: str) -> str:
    """Filesystem-safe, deterministic note name for a data object (true name stays in the H1)."""
    return re.sub(r"[:\\/]", ".", obj) + ".md"


def node_filename(owner: str, tid: str) -> str:
    """Graph node file for one ticket: OWNER-QUALIFIED and flat, separators flattened exactly like
    object_filename(). Owner is part of ticket identity, so two owners with the same slug get two
    nodes (`alice.chargeback-lift.md`, `bob.chargeback-lift.md`) instead of one merged one. The
    locator's `/` never reaches a filename or a git ref — display form only."""
    return re.sub(r"[:\\/]", ".", f"{owner}.{tid}") + ".md"


def graph_stub(row: dict, owners_by_id: dict, pairs: set, canon: dict,
               key_re: re.Pattern | None = None) -> str:
    """One Obsidian graph node per (owner, id) — see node_filename().

    "Builds on" links resolve each cross-ref by the ticket locator: a qualified `owner/id` ref links
    that exact node; a bare ref links the CURRENT owner's ticket first, then the single other owner
    that has it; a bare ref two owners could claim is left as plain text with a stderr warning naming
    them — an ambiguous reference is an error to fix, never a guess. A ref that resolves to this node
    itself (a curated record echoing its own id) is dropped.
    """
    owner, tid = row["owner"], row["id"]
    objects = sorted({canon.get(o.lower(), o) for o in row["objects"]}, key=str.lower)
    refs = sorted(set(row["cross_refs"]), key=lambda i: _ref_sort_key(i, key_re))
    obj_cells = ", ".join(f"[`{o}`](../objects/{object_filename(o)})" for o in objects) or "(none)"
    out = [f"# {tid}: {md_escape(row['title'])}", "",
           f"`{owner}` · {row['status']} · {row['date'] or '—'}", "",
           f"- **Objects:** {obj_cells}"]
    cells = []
    for x in refs:
        ro, ri = split_ref(x)
        if ro is None:  # bare ref: this owner first, then the one other owner that has it
            if (owner, ri) in pairs:
                ro = owner
            else:
                elig = owners_by_id.get(ri, [])
                if len(elig) == 1:
                    ro = elig[0]
                elif len(elig) > 1:
                    print(f"build_ticket_index: {owner}/{tid}: cross-ref '{ri}' matches multiple "
                          f"owners ({', '.join(elig)}); linking none — qualify it as one of "
                          + ", ".join(f"{e}/{ri}" for e in elig), file=sys.stderr)
        if (ro, ri) == (owner, tid):
            continue  # a record's ref to its own ticket is not an edge
        if ro is not None and (ro, ri) in pairs:
            cells.append(f"[{x}]({node_filename(ro, ri)})")
        else:
            cells.append(x)  # dangling or ambiguous: plain text, never a broken/guessed link
    if cells:
        out.append("- **Builds on:** " + ", ".join(cells))
    if row["has_readme"]:
        out.append(f"- **Full ticket →** [README](../{row['link']})")
    if row.get("enriched") and row.get("summary") and row["summary"] != "—":
        out += ["", md_escape(row["summary"])]  # only echo curated summaries; un-enriched fallbacks are noisy
    out += ["", "<!-- generated graph node - regenerated by build_ticket_index.py; do not edit -->", ""]
    return "\n".join(out)


def graph_object_note(obj: str, tickets: list, owners_by_id: dict | None = None,
                      key_re: re.Pattern | None = None) -> str:
    """One node per data object; links the ticket stubs (../graph/<owner>.<id>.md).
    tickets = (owner, id, title, date). The link label is the bare id while it is unambiguous and
    the `owner/id` locator as soon as two owners share the id."""
    schema = obj.split(".")[0] if "." in obj else "object"
    out = [f"# {obj}", "", f"> `{schema}` layer. Touched by **{len(tickets)}** ticket(s).", ""]
    for towner, tid, title, date in sorted(
            tickets, key=lambda t: ((t[3] or "0000-00-00"), ref_key(t[1], key_re), t[0])):
        label = f"{towner}/{tid}" if len((owners_by_id or {}).get(tid, [])) > 1 else tid
        suffix = f" - {md_escape(title)}" if title and title != tid else ""
        out.append(f"- [{label}](../graph/{node_filename(towner, tid)}){suffix} ({date or '—'})")
    out += ["", "<!-- generated graph node - regenerated by build_ticket_index.py; do not edit -->", ""]
    return "\n".join(out)


def render_graph_layer(rows: list, root: Path, key_re: re.Pattern | None = None) -> dict:
    """Return {Path: content} for tickets/graph/*.md + tickets/objects/*.md. Deterministic.

    Nodes key on (owner, id) — the aggregation that used to key on the bare id collapsed two owners'
    same-named tickets into one node with merged owners and objects. Old bare-id node files are
    removed by the existing orphan cleanup on the next render.
    """
    gdir, odir = root / "tickets" / "graph", root / "tickets" / "objects"
    pairs = {(r["owner"], r["id"]) for r in rows}
    owners_by_id: dict = {}
    for r in rows:
        owners_by_id.setdefault(r["id"], []).append(r["owner"])
    for tid in owners_by_id:
        owners_by_id[tid].sort()
    # Case-fold objects globally (like render_objects) so a mixed-case ref makes ONE note, not two,
    # and so stub↔object filenames agree on a case-insensitive filesystem (macOS).
    objmap: dict = {}  # lower(obj) -> {"label": first-seen form, "tids": {(owner, id): tuple}}
    for r in rows:
        for o in r["objects"]:
            slot = objmap.setdefault(o.lower(), {"label": o, "tids": {}})
            slot["tids"].setdefault((r["owner"], r["id"]), (r["owner"], r["id"], r["title"], r["date"]))
    canon = {k: v["label"] for k, v in objmap.items()}  # lower(obj) -> canonical display label
    fresh: dict = {}
    seen_files: dict = {}  # lower(filename) -> (owner, id); dot-flattening is not injective
    for r in rows:
        fn = node_filename(r["owner"], r["id"])
        prior = seen_files.get(fn.lower())
        if prior is not None:  # e.g. owners `a.b` and `a:b` both flatten to `a.b.` — say so, latter wins
            print(f"build_ticket_index: graph node filename collision: {prior[0]}/{prior[1]} and "
                  f"{r['owner']}/{r['id']} both map to {fn}; using the latter", file=sys.stderr)
        seen_files[fn.lower()] = (r["owner"], r["id"])
        fresh[gdir / fn] = graph_stub(r, owners_by_id, pairs, canon, key_re)
    for slot in objmap.values():
        fresh[odir / object_filename(slot["label"])] = graph_object_note(
            slot["label"], list(slot["tids"].values()), owners_by_id, key_re)
    return fresh


def obsidian_color_groups() -> list:
    """The two ticketwright-managed color groups: ticket nodes (lime), object nodes (coral)."""
    return [
        {"query": OBSIDIAN_TICKET_QUERY, "color": {"a": 1, "rgb": OBSIDIAN_TICKET_RGB}},
        {"query": OBSIDIAN_OBJECT_QUERY, "color": {"a": 1, "rgb": OBSIDIAN_OBJECT_RGB}},
    ]


def default_graph_config() -> dict:
    """Full .obsidian/graph.json for a first-time create: our filter + color groups, plus tame
    defaults for the rest. Any later user tweak to a non-managed key is kept by merge_graph_config."""
    return {
        "collapse-filter": True,
        "search": OBSIDIAN_SEARCH,
        "showTags": False,
        "showAttachments": False,
        "hideUnresolved": False,
        "showOrphans": True,
        "collapse-color-groups": False,
        "colorGroups": obsidian_color_groups(),
        "collapse-display": True,
        "showArrow": False,
        "textFadeMultiplier": 0,
        "nodeSizeMultiplier": 1,
        "lineSizeMultiplier": 1,
        "collapse-forces": True,
        "centerStrength": 0.518713248970312,
        "repelStrength": 10,
        "linkStrength": 1,
        "linkDistance": 250,
        "scale": 1,
        "close": True,
    }


def merge_graph_config(existing: dict) -> dict:
    """Non-clobber merge into an existing graph.json: refresh only the search filter and our two
    color groups; preserve every other key (forces, zoom, display) and any user-added group.
    Idempotent — running twice on its own output is a no-op."""
    cfg = dict(existing)
    # search: apply ours only if empty or a value we authored; a user's custom filter stays.
    cur = str(cfg.get("search", "")).strip()
    if cur == "" or cur in OBSIDIAN_KNOWN_SEARCHES:
        cfg["search"] = OBSIDIAN_SEARCH
    # colorGroups: our two groups first (keep the user's copy if present — e.g. a recolor — else the
    # default), then every group the user added under a different query.
    groups = cfg.get("colorGroups")
    groups = groups if isinstance(groups, list) else []
    mine = {g.get("query"): g for g in groups if isinstance(g, dict) and g.get("query") in OBSIDIAN_MANAGED_QUERIES}
    others = [g for g in groups if not (isinstance(g, dict) and g.get("query") in OBSIDIAN_MANAGED_QUERIES)]
    cfg["colorGroups"] = [mine.get(g["query"], g) for g in obsidian_color_groups()] + others
    return cfg


def write_obsidian_graph(root: Path) -> bool:
    """Create or non-clobber-merge .obsidian/graph.json so the Graph view opens on the color-coded
    tickets↔objects web. Writes only when content changes. Returns True if it wrote."""
    path = root / ".obsidian" / "graph.json"
    if path.is_file():
        try:
            existing = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError):
            return False  # unparseable → it's the user's; never overwrite blind
        if not isinstance(existing, dict):
            return False
        cfg = merge_graph_config(existing)
    else:
        cfg = default_graph_config()
    new_text = json.dumps(cfg, indent=2)  # match Obsidian's 2-space, no trailing newline (less churn)
    if path.is_file() and path.read_text() == new_text:
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(new_text, encoding="utf-8")
    return True


def main() -> int:
    ap = argparse.ArgumentParser(description="Render tickets/INDEX.md + OBJECTS.md")
    ap.add_argument("--check", action="store_true", help="exit 1 if INDEX.md/OBJECTS.md — or the graph nodes, when the layer is on — are stale vs a fresh render")
    ap.add_argument("--stats", action="store_true", help="print coverage + health stats and exit 0")
    ap.add_argument("--recurring", action="store_true",
                    help="list objects touched by many tickets over a long span (productize candidates)")
    ap.add_argument("--min-tickets", dest="min_tickets", type=int, default=3,
                    help="with --recurring: minimum tickets for an object to be listed")
    ap.add_argument("--prune", action="store_true",
                    help="drop orphan curated records (in index_data.json but no folder on disk) from the store")
    args = ap.parse_args()

    root = repo_root()
    cfg = load_config(root)
    key_re = id_key_regex(cfg)   # the authority on which ids carry a tracker number
    rows = build_rows(root)
    tickets_dir = root / "tickets"
    index_path, objects_path = tickets_dir / "INDEX.md", tickets_dir / "OBJECTS.md"
    fresh = {index_path: render(rows), objects_path: render_objects(rows, key_re=key_re)}
    graph_dirs = [tickets_dir / "graph", tickets_dir / "objects"]  # always tracked, so disabling cleans up the old layer
    if cfg.get("graph_notes", True):
        fresh.update(render_graph_layer(rows, root, key_re))

    if args.prune:
        orph = find_orphans(root, rows)
        store_path = tickets_dir / "index_data.json"
        if not store_path.is_file():
            print("No index_data.json — nothing to prune.")
            return 0
        if not orph:
            print("No orphan records to prune.")
            return 0
        on_disk = {(r["owner"], r["id"]) for r in rows}
        data = json.loads(store_path.read_text())
        kept = [t for t in data.get("tickets", [])
                if isinstance(t, dict) and (t.get("owner"), t.get("id")) in on_disk]
        payload = json.dumps({"schema_version": data.get("schema_version", 1), "tickets": kept},
                             indent=2, ensure_ascii=False) + "\n"
        store_path.write_bytes(payload.encode("utf-8"))
        print(f"Pruned {len(orph)} orphan record(s): {', '.join(orph)}")
        print("Now re-render: python3 bin/build_ticket_index.py")
        return 0

    if args.recurring:
        agg: dict[str, dict] = {}  # ci key -> {label, tickets, dates}
        for r in rows:
            for o in {x for x in r.get("objects", [])}:  # dedup within a ticket
                slot = agg.setdefault(o.lower(), {"label": o, "tickets": 0, "dates": []})
                slot["tickets"] += 1
                if r["date"]:
                    slot["dates"].append(r["date"])

        def span_days(dates):
            try:
                ds = sorted(date.fromisoformat(d) for d in dates)
                return (ds[-1] - ds[0]).days if len(ds) > 1 else 0
            except ValueError:
                return 0
        rec = [s for s in agg.values() if s["tickets"] >= args.min_tickets]
        rec.sort(key=lambda s: (-s["tickets"], -span_days(s["dates"]), s["label"].lower()))
        print(f"Recurring objects (touched by ≥ {args.min_tickets} tickets) — candidates to productize:")
        if not rec:
            print("  (none)")
        for s in rec:
            span = f"{min(s['dates'])}→{max(s['dates'])} ({span_days(s['dates'])}d)" if s["dates"] else "—"
            print(f"  {s['tickets']:>3} tickets  {span:<28}  {s['label']}")
        return 0

    if args.stats:
        un = [f"{r['owner']}/{r['id']}" for r in rows if not r["enriched"]]
        st = [f"{r['owner']}/{r['id']}" for r in rows if r["stale"]]
        no_readme = [f"{r['owner']}/{r['id']}" for r in rows if not r["has_readme"]]
        orph = find_orphans(root, rows)
        obj_counts: dict[str, int] = {}
        for r in rows:
            for o in {x.lower() for x in r.get("objects", [])}:
                obj_counts[o] = obj_counts.get(o, 0) + 1
        n_obj = len(obj_counts)
        print(f"discovered: {len(rows)}  enriched: {len(rows) - len(un)}  un-enriched: {len(un)}  "
              f"stale: {len(st)}  objects: {n_obj}")
        # health metrics
        if rows:
            cov = (len(rows) - len(un)) / len(rows) * 100
            summ_lens = [len(r["summary"]) for r in rows if r.get("summary") and r["summary"] != "—"]
            med = int(statistics.median(summ_lens)) if summ_lens else 0
            under = sum(1 for r in rows if not r.get("objects") and not r.get("tags"))
            one_off = sum(1 for c in obj_counts.values() if c == 1)
            shared = sum(1 for c in obj_counts.values() if c > 1)
            stale_dates = [r["date"] for r in rows if r["stale"] and r["date"]]
            print(f"health: {cov:.0f}% enriched · median summary {med} chars · "
                  f"under-enriched (no tags+objects): {under} · objects {one_off} one-off / {shared} shared"
                  + (f" · oldest stale: {min(stale_dates)}" if stale_dates else ""))
        if un:
            print("un-enriched: " + ", ".join(un))
        if no_readme:
            print("no README anywhere: " + ", ".join(no_readme))
        if orph:
            print("orphan records (in index_data.json, no folder): " + ", ".join(orph))
        if st:
            print("stale: " + ", ".join(st))
        return 0

    if args.check:
        if not rows and not any(p.is_file() for p in fresh):
            print("No tickets and no index files yet — nothing to check.")
            return 0
        stale = [p.name for p, txt in fresh.items() if (p.read_text() if p.is_file() else None) != txt]
        fresh_keys_ci = {str(p).lower() for p in fresh}  # case-insensitive (macOS): a current file may differ only in case
        for gd in graph_dirs:  # orphan detection: generated files on disk no longer in the fresh set
            if gd.is_dir():
                stale += [str(p.relative_to(root)) for p in sorted(gd.glob("*.md")) if str(p).lower() not in fresh_keys_ci]
        if stale:
            print(f"stale: {', '.join(stale)} — run: python3 bin/build_ticket_index.py", file=sys.stderr)
            return 1
        # Name the graph layer when it was part of the comparison — /ship stages what this gates.
        print("tickets/INDEX.md + OBJECTS.md"
              + (" + the graph layer" if cfg.get("graph_notes", True) else "")
              + " are up to date.")
        return 0

    if not tickets_dir.is_dir():
        print("No tickets/ directory yet — nothing to index.", file=sys.stderr)
        return 0
    for p, txt in fresh.items():
        p.parent.mkdir(parents=True, exist_ok=True)  # graph/ + objects/ may not exist yet
        p.write_bytes(txt.encode("utf-8"))  # write_bytes => stable \n line endings everywhere
    fresh_keys_ci = {str(p).lower() for p in fresh}  # orphan cleanup (case-insensitive for macOS)
    for gd in graph_dirs:
        if gd.is_dir():
            for existing in gd.glob("*.md"):
                if str(existing).lower() not in fresh_keys_ci:
                    existing.unlink()
            if not any(gd.iterdir()):  # tidy the empty generated dir (e.g. after disabling graph_notes)
                gd.rmdir()
    # Auto-configure the Obsidian Graph view (create/merge; never clobbers manual tweaks). Not in
    # `fresh`/`--check`: Obsidian rewrites this file on every zoom/pan, so it isn't staleness-gated.
    if cfg.get("graph_notes", True) and cfg.get("graph_config", True):
        write_obsidian_graph(root)
    un = sum(1 for r in rows if not r["enriched"])
    n_obj = len({o.lower() for r in rows for o in r.get("objects", [])})
    print(f"Wrote INDEX.md ({len(rows)} tickets, {un} un-enriched) + OBJECTS.md ({n_obj} objects).", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
