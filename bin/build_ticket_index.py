#!/usr/bin/env python3
"""Render tickets/INDEX.md (the ticket catalog) + tickets/OBJECTS.md (object → tickets reverse index).

Deterministic and LLM-free: safe to run in CI / a pre-commit hook, byte-identical for the
same on-disk state (no timestamps). Good one-line summaries aren't something regex can
write, so the LLM-authored fields (summary / status / best-date / tags) live in
`tickets/index_data.json` — produced by the build-ticket-index skill / enrich step and
refreshed per ticket at close. This script only *renders* that data and keeps the catalog
complete: every ticket folder on disk gets a row, enriched or not.

A "ticket" is any immediate sub-folder of `tickets/<owner>/` whose name contains a tracker
key — the prefixes come from `.claude/config/stack.yaml` (`key_prefixes`, else `key_prefix`;
default: any `LETTERS-digits`). Emoji-prefixed names like "☑️ ENG-12_thing" work too. Folders
with no tracker key (adhoc-*, scratch-*, ℹ️ …) are reference/scratch work and are skipped.

Usage:
  build_ticket_index.py            # (re)write tickets/INDEX.md
  build_ticket_index.py --check    # exit 1 if INDEX.md is stale vs a fresh render (gate)
  build_ticket_index.py --stats    # print coverage: enriched / un-enriched / stale; exit 0

Stdlib only.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
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


def repo_root() -> Path:
    if os.environ.get("CLAUDE_PROJECT_DIR"):
        return Path(os.environ["CLAUDE_PROJECT_DIR"]).resolve()
    return Path(__file__).resolve().parent.parent  # bin/ -> repo root


def load_config(root: Path) -> dict:
    """Read the few fields the index needs from stack.yaml (stdlib regex; no YAML dep)."""
    cfg = {"prefixes": [], "url_template": None}
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
    return cfg


def key_regex(prefixes: list[str]) -> re.Pattern:
    if prefixes:
        return re.compile(rf"(?:{'|'.join(re.escape(p) for p in prefixes)})-\d+")
    return re.compile(r"[A-Z][A-Z0-9]+-\d+")  # generic fallback when stack.yaml is absent


def title_prefix_regex(prefixes: list[str]) -> re.Pattern:
    alt = "|".join(re.escape(p) for p in prefixes) if prefixes else r"[A-Z][A-Z0-9]+"
    return re.compile(rf"^(?:{alt})-\d+\S*\s*[:\-–—]\s*")


def ticket_url(template: str | None, tid: str) -> str | None:
    # {id} = full key (e.g. ENG-12); {number} = trailing integer (e.g. 12), for trackers whose
    # native id is a bare number (Azure Boards, GitHub Issues) even when folders use a prefix.
    if not template:
        return None
    return template.replace("{id}", tid).replace("{number}", str(ticket_number(tid)))


def ticket_number(tid: str) -> int:
    m = re.search(r"-(\d+)", tid)
    return int(m.group(1)) if m else 0


def ref_key(tid: str):
    """Total order for tracker keys (number then full id, so ENG-12 vs OPS-12 are stable)."""
    return (ticket_number(tid), tid)


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


def discover(root: Path, key_re: re.Pattern | None = None) -> list[dict]:
    """Every tracker-keyed ticket folder, one level under tickets/<owner>/. Cheap (no file reads)."""
    if key_re is None:
        key_re = key_regex(load_config(root)["prefixes"])
    out: dict[tuple[str, str], dict] = {}
    tickets = root / "tickets"
    if not tickets.is_dir():
        return []
    for owner_dir in sorted(p for p in tickets.iterdir() if p.is_dir()):
        owner = owner_dir.name
        for d in sorted(p for p in owner_dir.iterdir() if p.is_dir()):
            m = key_re.search(d.name)
            if not m:
                continue
            tid = m.group(0)
            readme = d / "README.md"
            emoji = next((v for k, v in EMOJI_STATUS.items() if d.name.startswith(k)), None)
            out[(owner, tid)] = {
                "owner": owner, "id": tid, "dir": d,
                "readme": readme if readme.is_file() else None, "emoji_status": emoji,
            }
    return list(out.values())


def parse_readme(path: Path, self_id: str, key_re: re.Pattern, title_re: re.Pattern) -> dict:
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

    refs = sorted({r for r in key_re.findall(text) if r != self_id}, key=ref_key)
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


def build_rows(root: Path) -> list[dict]:
    cfg = load_config(root)
    key_re = key_regex(cfg["prefixes"])
    title_re = title_prefix_regex(cfg["prefixes"])
    data = load_data(root)
    rows = []
    for t in discover(root, key_re):
        owner, tid, d, readme = t["owner"], t["id"], t["dir"], t["readme"]
        entry = data.get((owner, tid))
        parsed = parse_readme(readme, tid, key_re, title_re) if readme else {"title": None, "date": None, "summary": None, "cross_refs": []}
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
        url = (entry or {}).get("ticket_url") or (entry or {}).get("jira_url") or ticket_url(cfg["url_template"], tid)
        rel = d.relative_to(root / "tickets").as_posix()
        link = quote(rel) + "/" + ("README.md" if readme else "")

        rows.append({
            "owner": owner, "id": tid, "title": title, "status": status, "date": date_val,
            "summary": summary, "tags": tags, "cross_refs": cross_refs, "objects": objects, "url": url,
            "link": link, "enriched": enriched, "stale": stale, "has_readme": bool(readme),
        })
    rows.sort(key=lambda r: ((r["date"] or "0000-00-00"), ticket_number(r["id"]), r["id"], r["owner"]), reverse=True)
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
        out.append("Coverage: " + " · ".join(notes) + ". Run the build-ticket-index skill to refresh.")
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


def render_objects(rows: list[dict]) -> str:
    """Reverse index: data object → tickets that touched it. Deterministic, byte-stable."""
    obj: dict[str, dict] = {}  # case-insensitive key -> {"label": display form, "tickets": [rows]}
    for r in rows:
        for o in r.get("objects", []):
            slot = obj.setdefault(o.lower(), {"label": o, "tickets": []})
            slot["tickets"].append(r)
    out = []
    out.append("<!-- GENERATED by bin/build_ticket_index.py from tickets/index_data.json + ticket SQL — DO NOT EDIT BY HAND.")
    out.append("     Re-run `python3 bin/build_ticket_index.py` after adding or closing a ticket. -->")
    out.append("")
    out.append("# Object Index")
    out.append("")
    out.append(f"**{len(obj)} data objects** referenced across the ticket archive — the reverse of `INDEX.md`.")
    out.append("")
    out.append("> **For the agent:** before changing a view/table, grep here for every ticket that read or wrote it.")
    out.append("")
    if not obj:
        out.append("_No object references found yet — objects come from ticket SQL + enrichment._")
        out.append("")
        return "\n".join(out)
    out.append("| Object | Tickets |")
    out.append("|---|---|")
    for _, slot in sorted(obj.items(), key=lambda kv: (-len(kv[1]["tickets"]), kv[0])):
        ts = sorted(slot["tickets"], key=lambda r: (ref_key(r["id"]), r["owner"]))
        cells = ", ".join(f"[{t['id']}]({t['link']})" for t in ts)
        out.append(f"| `{md_escape(slot['label'])}` | {cells} ({len(ts)}) |")
    out.append("")
    return "\n".join(out)


def main() -> int:
    ap = argparse.ArgumentParser(description="Render tickets/INDEX.md + OBJECTS.md")
    ap.add_argument("--check", action="store_true", help="exit 1 if INDEX.md/OBJECTS.md are stale vs a fresh render")
    ap.add_argument("--stats", action="store_true", help="print coverage stats and exit 0")
    args = ap.parse_args()

    root = repo_root()
    rows = build_rows(root)
    tickets_dir = root / "tickets"
    index_path, objects_path = tickets_dir / "INDEX.md", tickets_dir / "OBJECTS.md"
    fresh = {index_path: render(rows), objects_path: render_objects(rows)}

    if args.stats:
        un = [f"{r['owner']}/{r['id']}" for r in rows if not r["enriched"]]
        st = [f"{r['owner']}/{r['id']}" for r in rows if r["stale"]]
        n_obj = len({o.lower() for r in rows for o in r.get("objects", [])})
        print(f"discovered: {len(rows)}  enriched: {len(rows) - len(un)}  un-enriched: {len(un)}  "
              f"stale: {len(st)}  objects: {n_obj}")
        if un:
            print("un-enriched: " + ", ".join(un))
        if st:
            print("stale: " + ", ".join(st))
        return 0

    if args.check:
        if not rows and not any(p.is_file() for p in fresh):
            print("No tickets and no index files yet — nothing to check.")
            return 0
        stale = [p.name for p, txt in fresh.items() if (p.read_text() if p.is_file() else None) != txt]
        if stale:
            print(f"stale: {', '.join(stale)} — run: python3 bin/build_ticket_index.py", file=sys.stderr)
            return 1
        print("tickets/INDEX.md + OBJECTS.md are up to date.")
        return 0

    if not tickets_dir.is_dir():
        print("No tickets/ directory yet — nothing to index.", file=sys.stderr)
        return 0
    for p, txt in fresh.items():
        p.write_bytes(txt.encode("utf-8"))  # write_bytes => stable \n line endings everywhere
    un = sum(1 for r in rows if not r["enriched"])
    n_obj = len({o.lower() for r in rows for o in r.get("objects", [])})
    print(f"Wrote INDEX.md ({len(rows)} tickets, {un} un-enriched) + OBJECTS.md ({n_obj} objects).", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
