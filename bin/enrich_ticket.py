#!/usr/bin/env python3
"""Refresh the curated index summary for one or more tickets — run at ticket close.

The deterministic renderer + PostToolUse hook keep `tickets/INDEX.md` *complete* (a new
ticket appears immediately as a `▱` row). This script does the LLM half: it reads a
ticket's README, has a model write the one-line summary / status / date / tags / cross-refs,
upserts that into `tickets/index_data.json`, and re-renders — turning `▱` into a curated row.

It runs a model headlessly, and WHICH model command it runs is resolved per runtime rather than
hardcoded — this script lives in bin/, the layer the architecture calls harness-neutral, so a hard
`claude -p` dependency here was a lie about that boundary. Resolution order:

  1. `--model-cmd '<template>'`
  2. the detected runtime's `model_cmd:` frontmatter in `adapters/runtime/<name>.md`
  3. the built-in `claude -p` default

Step 3 is deliberately NOT gated on detection: a wrong runtime guess must never be the reason
enrichment stops working. A runtime that IS detected and declares an empty `model_cmd` has no
headless command, and that is reported with the agent-neutral recipe rather than guessed around.

id/owner are always taken from disk, never from the model. The agent-neutral path — and the one the
docs lead with — is the refresh skill (index mode), where the host agent writes the record itself and
pipes it to `ingest_index_records.py --from-json -`. This script is the accelerated convenience.

Usage:
  enrich_ticket.py ENG-123 [ENG-124 ...]         # enrich specific ticket(s)
  enrich_ticket.py alice/ENG-123                 # owner-qualified locator, when an id is shared
  enrich_ticket.py --branch                      # enrich the ticket named in the current git branch
  enrich_ticket.py ENG-123 --model opus          # override the model
  enrich_ticket.py ENG-123 --model-cmd 'x {prompt}'   # override the whole model command

Owner is part of ticket identity: a bare id that exists under more than one `tickets/<owner>/`
folder is a HARD STOP (exit 3) naming every owner — pass the `owner/id` locator to pick one.
Enriching every matching folder was the old behavior and is exactly the guess this forbids.

Then commit tickets/INDEX.md + tickets/OBJECTS.md + tickets/index_data.json with the ticket, plus
tickets/graph/ + tickets/objects/ when project.graph_notes is on (the default) — the re-render
touches the graph layer too, and --check gates it.
"""
from __future__ import annotations

import argparse
import json
import shlex
import subprocess
import sys
from pathlib import Path

from build_ticket_index import discover, repo_root, load_config, key_regex

# The historical command, kept as the floor so a runtime this script cannot identify behaves exactly
# as it always has.
DEFAULT_MODEL_CMD = "claude -p --model {model} {prompt}"
DEFAULT_MODEL = "sonnet"
# A model command is built as ARGV and never handed to a shell. The prompt carries up to 24KB of a
# ticket README, which on most installs was fetched from a tracker — i.e. text someone outside this
# repo wrote. Interpolating that into a shell string would make a README with backticks or $(…) into
# executable code during an unattended /ship. These characters are refused in a template so nobody
# can reintroduce that by writing an adapter that looks shell-shaped.
SHELL_METACHARS = set(";|&<>$`\n")
# Only these may be argv[0] of a model command resolved FROM AN ADAPTER. Adapters live inside the repo
# on a vendored install, so without this an adapters/runtime/x.md added by a pull request runs any
# command during /ship — verified reproducible before this existed. --model-cmd is deliberately exempt:
# that is a human typing at their own terminal, not repo content.
ALLOWED_MODEL_BINARIES = frozenset({"claude", "codex", "agy", "devin", "opencode", "gemini"})

INGEST_RECIPE = """No headless model command is available for this runtime.

Use the agent-neutral path instead — the host agent writes the record and pipes it in:

  echo '{{"records":[{{"id":"<ID>","owner":"<OWNER>","status":"...","summary":"...","tags":[]}}]}}' \\
    | python3 "{bindir}/ingest_index_records.py" --from-json -
  python3 "{bindir}/build_ticket_index.py"

Or pass a command explicitly:  --model-cmd '<tool> --flag {{prompt}}'
See adapters/runtime/*.md for what each runtime documents."""


def _kit_runtime_model_cmd() -> tuple[str | None, str | None, str]:
    """(model_cmd, model_default, source) from the detected runtime's adapter.

    Imported lazily and defensively ON PURPOSE. This script is copied on its own into fixture repos
    and into vendored installs where kit_paths.py and adapters/ may not sit beside it, and a
    top-level import would turn that into a crash. A miss returns (None, None, ...) so the caller
    falls back to the historical default rather than failing.

    TRUST MODEL — read this before loosening anything. `ticketwright init` copies adapters/ INTO the
    target repo, so on a vendored install the project root IS a valid kit and adapters/runtime/*.md is
    project-controlled. "Resolve from the kit only" therefore does NOT isolate this from repo content,
    and an earlier version of this docstring wrongly claimed it did.

    What actually contains the risk is ALLOWED_MODEL_BINARIES. A markdown file reads as inert in code
    review, so a `model_cmd:` line is a uniquely easy place to hide an executable payload — a reviewer
    skims a .md diff far less carefully than a .py one. The allowlist means the worst a crafted adapter
    can do is pick a different MODEL CLI, not run `curl` or `rm`.
    """
    try:
        # Look beside this script first, then under an explicit $TICKETWRIGHT_KIT — otherwise the
        # override is inert exactly when it matters, i.e. when this script was copied somewhere on its
        # own and the kit lives elsewhere.
        import os
        for cand in (Path(__file__).resolve().parent,
                     Path(os.environ.get("TICKETWRIGHT_KIT", "/nonexistent")).expanduser() / "bin"):
            if (cand / "kit_paths.py").is_file():
                sys.path.insert(0, str(cand))
                break
        import kit_paths
        kit, _ = kit_paths.resolve_kit()
        if not kit:
            return None, None, "no kit"
        runtime, _ = kit_paths.detect_runtime(kit)
        entry = kit_paths.runtime_adapters(kit).get(runtime)
        if not entry:
            return None, None, f"runtime {runtime} has no adapter"
        fm = entry[1]
        cmd = fm.get("model_cmd", "")
        if cmd.strip():
            try:
                argv0 = shlex.split(cmd)[0]
            except (ValueError, IndexError):
                argv0 = ""
            if Path(argv0).name not in ALLOWED_MODEL_BINARIES:
                print(f"enrich_ticket: refusing model_cmd from adapters/runtime/{runtime}.md — "
                      f"'{argv0}' is not a known model CLI. Adapters ship inside the repo on a "
                      f"vendored install, so this allowlist is what stops a markdown file from "
                      f"running an arbitrary command. Use --model-cmd if you meant to run it.",
                      file=sys.stderr)
                return "", None, f"adapters/runtime/{runtime}.md (refused)"
        return cmd, fm.get("model_default") or None, f"adapters/runtime/{runtime}.md"
    except Exception:
        return None, None, "kit_paths unavailable"


def build_model_argv(template: str, model: str | None, prompt: str) -> tuple[list[str], bool]:
    """Turn a command template into argv. Returns (argv, prompt_goes_on_stdin).

    Substitution is per-element and literal — never str.format, because adapter frontmatter may
    legitimately contain other braces, and never a re-split after substituting, because that is how
    a prompt's own spaces would become argument boundaries.

    `{model}` resolves to --model, else the adapter's model_default. With neither, the element is
    dropped along with an immediately preceding flag, so `--model {model}` disappears cleanly and the
    tool applies its own default.
    """
    if model and model.startswith("-"):
        raise ValueError(f"model name may not start with '-' (got {model!r}) — it would read as a flag")
    bad = SHELL_METACHARS & set(template)
    if bad:
        raise ValueError(
            "model command may not contain shell metacharacters (%s) — it is run as argv, not via a "
            "shell. Rewrite it as a plain command with {prompt}/{model} tokens."
            % "".join(sorted(bad)))
    parts = shlex.split(template)
    out: list[str] = []
    for part in parts:
        if part == "{model}":
            if model:
                out.append(model)
            elif out and out[-1].startswith("-"):
                out.pop()          # drop the orphaned flag too
            continue
        if "{model}" in part:
            if not model:
                continue
            part = part.replace("{model}", model)
        if part == "{prompt}":
            out.append(prompt)
            continue
        if "{prompt}" in part:
            part = part.replace("{prompt}", prompt)
        out.append(part)
    if not out:
        raise ValueError("model command is empty after substitution — nothing to run")
    return out, "{prompt}" not in template

PROMPT = """You are writing one catalog record for a single ticket in this repo. The ticket's \
README is below.

Output ONLY a single minified JSON object (no prose, no code fence) with these keys:
- "status": one of "Completed","Deployed","In Review","In Progress","Blocked","Unknown" \
(Deployed if it shipped a data object/view/table/job; Completed if a deliverable was handed off; \
In Review if awaiting PR/stakeholder; In Progress if planned not delivered; Blocked if blocked).
- "date": best delivered/completed date as "YYYY-MM-DD", or null. Prefer an explicit \
Completed/Deployed/Filed date, else the most recent Update/Follow-up date. Never invent one.
- "summary": ONE line, <=180 chars, leading with what was delivered + key number(s)/outcome. \
Concrete, no "This ticket...".
- "tags": 1-4 short kebab-case topic tags describing the work (reuse common ones across tickets).
- "cross_refs": array of other ticket IDs referenced in the body (dedup, exclude this ticket).
- "objects": array of fully-qualified data objects the ticket read or wrote (e.g. "SCHEMA.VIEW", \
"db.schema.table"); [] if none / not a data ticket.
- "title": the H1 text with any leading "<KEY>-NNN:" stripped.

README for {tid}:
---
{readme}
---
Output the JSON object now."""


def extract_json(text: str) -> dict:
    i, j = text.find("{"), text.rfind("}")
    if i == -1 or j == -1 or j < i:
        raise ValueError("no JSON object found in model output")
    return json.loads(text[i:j + 1])


def enrich_one(loc: dict, template: str, model: str | None) -> dict | None:
    tid, owner, readme = loc["id"], loc["owner"], loc["readme"]
    if not readme:
        print(f"  {owner}/{tid}: no README — skipped (stays deterministic/▱).", file=sys.stderr)
        return None
    body = readme.read_text(errors="replace")[:24000]
    prompt = PROMPT.format(tid=tid, readme=body)
    argv, prompt_on_stdin = build_model_argv(template, model, prompt)
    tool = argv[0] if argv else "?"
    try:
        out = subprocess.run(
            argv,
            input=prompt if prompt_on_stdin else None,
            capture_output=True, text=True, timeout=240,
        )
    except (FileNotFoundError, OSError, subprocess.TimeoutExpired) as e:
        print(f"  {owner}/{tid}: {tool} failed ({e}).", file=sys.stderr)
        return None
    if out.returncode != 0:
        print(f"  {owner}/{tid}: {tool} exited {out.returncode}: {out.stderr.strip()[:200]}", file=sys.stderr)
        return None
    try:
        rec = extract_json(out.stdout)
    except (ValueError, json.JSONDecodeError) as e:
        print(f"  {owner}/{tid}: could not parse model output ({e}).", file=sys.stderr)
        return None
    # id/owner are authoritative from disk — never trust the model for these.
    rec["id"], rec["owner"] = tid, owner
    print(f"  {owner}/{tid}: {rec.get('status','?')} · {rec.get('date') or '—'} · {rec.get('summary','')[:80]}")
    return rec


def main() -> int:
    ap = argparse.ArgumentParser(description="Refresh curated index summaries for ticket(s)")
    ap.add_argument("ids", nargs="*", help="ticket ids, e.g. ENG-123")
    ap.add_argument("--branch", action="store_true", help="use the ticket id in the current git branch")
    ap.add_argument("--model", default=None,
                    help="model for the summary (default: whatever the runtime adapter declares)")
    ap.add_argument("--model-cmd", default=None,
                    help="the headless model command, e.g. 'mytool -p {prompt}'; wins over the runtime adapter")
    args = ap.parse_args()

    root = repo_root()
    locs_by_owner_id = {(t["owner"], t["id"]): t for t in discover(root)}

    ids = list(args.ids)
    if args.branch:
        # `symbolic-ref` rather than `rev-parse --abbrev-ref`: on a branch with no commits yet
        # rev-parse returns the literal string "HEAD", so a freshly created ticket branch could
        # never resolve. symbolic-ref reports the real name, and stays empty on a detached HEAD.
        br = ""
        for cmd in (["git", "symbolic-ref", "--short", "-q", "HEAD"],
                    ["git", "rev-parse", "--abbrev-ref", "HEAD"]):
            try:
                got = subprocess.run(cmd, capture_output=True, text=True, cwd=root).stdout.strip()
            except OSError:
                got = ""
            if got and got != "HEAD":
                br = got
                break
        cfg = load_config(root)
        cands = [c for c in (br, br.rsplit("/", 1)[-1]) if c]
        loc = None
        if cfg["id_mode"] == "slug":
            # A slug has no distinguishing shape, so match by identity against the ids actually on
            # disk instead of by pattern. Try the whole branch name and its last path segment, so
            # both `signup-funnel-lift` and `claude/signup-funnel-lift` resolve.
            known = {i for (_, i) in locs_by_owner_id}
            loc = next((c for c in cands if c in known), None)
        else:
            # A branch that IS a key resolves as that key; otherwise fall through to the collision
            # shape below before the loose in-string search, so `bob-ENG-12` names bob's ticket
            # rather than an ambiguous bare ENG-12.
            kre = key_regex(cfg["prefixes"])
            loc = next((c for c in cands if kre.fullmatch(c)), None)
        if loc is None:
            # Branch names stay bare `<id>`; a branch created against a taken name is `<owner>-<id>`.
            # That shape is not injective (owners and slugs both allow `-`), so it must resolve to
            # exactly one on-disk pair — several matches is a hard stop, never a pick.
            pair_hits = sorted((o, i) for (o, i) in locs_by_owner_id
                               if any(c == f"{o}-{i}" for c in cands))
            if len(pair_hits) == 1:
                loc = f"{pair_hits[0][0]}/{pair_hits[0][1]}"
            elif len(pair_hits) > 1:
                sys.exit(f"enrich_ticket: branch '{br}' matches multiple tickets "
                         f"({', '.join(f'{o}/{i}' for o, i in pair_hits)}); pass owner/id explicitly.")
        if loc is None and cfg["id_mode"] != "slug":
            m = key_regex(cfg["prefixes"]).search(br)
            if m:
                loc = m.group(0)
        if loc is not None:
            ids.append(loc)
    if not ids:
        sys.exit("No ticket ids given. Pass a ticket id (or folder name) or --branch.")

    targets = []
    for tid in ids:
        if "/" in tid:  # the owner/id locator — exact
            owner, bare = tid.split("/", 1)
            loc = locs_by_owner_id.get((owner, bare))
            if not loc:
                print(f"  {tid}: no ticket folder found — skipped.", file=sys.stderr)
                continue
            targets.append(loc)
            continue
        matches = [loc for (_, i), loc in locs_by_owner_id.items() if i == tid]
        if not matches:
            print(f"  {tid}: no ticket folder found — skipped.", file=sys.stderr)
            continue
        if len(matches) > 1:
            # Owner is part of ticket identity — enriching every owner's folder was a guess.
            owners = ", ".join(sorted(loc["owner"] for loc in matches))
            spellings = ", ".join(sorted(f"{loc['owner']}/{tid}" for loc in matches))
            print(f"enrich_ticket: {tid} exists under multiple owners ({owners}); "
                  f"say which one: {spellings}. Nothing was enriched.", file=sys.stderr)
            return 3
        targets.append(matches[0])

    # Sibling helpers live beside THIS script (the kit's bin/), not in the user's project. Resolving
    # them off repo_root() breaks on a plugin/pip install, where the kit and the project dir diverge.
    bindir = Path(__file__).resolve().parent

    # Resolved here — AFTER the "no ticket ids" guard above, so an unresolvable id still reports as an
    # id problem rather than as a model-command problem.
    if args.model_cmd:
        template, model_default, src = args.model_cmd, None, "--model-cmd"
    else:
        template, model_default, src = _kit_runtime_model_cmd()
        if template is None:                       # runtime unidentifiable → historical behavior
            template, model_default, src = DEFAULT_MODEL_CMD, DEFAULT_MODEL, "built-in default"
        elif not template.strip():                 # runtime known, documents no headless command
            print(INGEST_RECIPE.format(bindir=bindir), file=sys.stderr)
            return 4
    model = args.model or model_default

    try:
        preview, _ = build_model_argv(template, model, "<prompt>")
    except ValueError as e:
        print(f"enrich_ticket: {e}", file=sys.stderr)
        return 2
    print(f"Enriching {len(targets)} ticket(s) via {' '.join(preview[:4])} … [{src}]", file=sys.stderr)
    records = [r for r in (enrich_one(loc, template, model) for loc in targets) if r]
    if not records:
        print("Nothing enriched.", file=sys.stderr)
        return 1

    ingest = bindir / "ingest_index_records.py"
    render = bindir / "build_ticket_index.py"
    subprocess.run([sys.executable, str(ingest), "--from-json", "-"],
                   input=json.dumps({"records": records}), text=True, check=True)
    subprocess.run([sys.executable, str(render)], check=True)
    print("Done. Commit tickets/INDEX.md + tickets/OBJECTS.md + tickets/index_data.json with the "
          "ticket — plus tickets/graph/ + tickets/objects/ if the graph layer is on.", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
