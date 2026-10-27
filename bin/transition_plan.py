#!/usr/bin/env python3
"""transition_plan.py: which status /ship moves a ticket to, read from the tracker's own moves.

WHY THIS FILE EXISTS. /ship used to "transition the ticket toward `project.terminal_status` if that
applies", with the status name typed from memory. Workflows differ per project: one delivery planned
a move to `In Review` on a board that has no such status, and the transition failed at the very last
step (`No allowed transitions found for given status`). The tracker knows which moves this ticket
can make right now, and `tracker.list_transitions` returns them in one shape for every tool
(adapters/README.md § tracker). This CLI is the deterministic half: given that list and the wanted
status, it names the exact target, or says plainly that none reaches it so the caller ASKS.

THE ONE RULE: A TARGET IS MATCHED, NEVER GUESSED. The wanted status (`--want`, else the merged
config's `project.terminal_status`, default `Done`) must equal a move's `to` (case and spacing aside;
the tracker's own spelling is what is returned). No match is exit 8 with the moves listed. A single
move in the `done` category is returned as a `suggestion` for the question, never as the target.

  transition_plan.py --transitions moves.json [--want Done] [--id TEST-14]
  … | transition_plan.py --transitions -

Input is the `list_transitions` return: {"current", "transitions": [{"to", "via", "category"}],
"free_form"}, or {"status": "unavailable" | "unsupported", "reason": "..."} when the adapter could
not list them.

EXIT CODES (the resolver family): 0 a target is known (`move`, `already_there`, `free_form`) ·
2 usage · 4 the input is malformed · 7 the moves could not be read (`unavailable`, `unsupported`:
the target is the configured status, NOT checked) · 8 no move reaches the wanted status, or more than
one does (`no_route`, `ambiguous`). On 4 and 8, `target` and `via` are null.

Stdlib only. Read-only. Makes no tracker call: the adapter's verb did that.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

EXIT_OK, EXIT_USAGE, EXIT_MALFORMED, EXIT_UNREAD, EXIT_NO_ROUTE = 0, 2, 4, 7, 8
CATEGORIES = ("todo", "in_progress", "done")
DEFAULT_TERMINAL = "Done"


def _norm(s: str) -> str:
    return " ".join(s.split()).casefold()


def _configured_terminal(root: str | None, stack: str | None) -> str:
    """`project.terminal_status` from the MERGED config, else `Done`. A config the resolver cannot read
    falls back to the default rather than failing: the status is then still checked against the
    tracker's moves, which is the check that matters."""
    try:
        import effective_config as ec
        res = ec.resolve(root or os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd(), None, stack)
        val = (res.project or {}).get("terminal_status")
        if isinstance(val, str) and val.strip():
            return val.strip()
    except Exception:  # noqa: BLE001 - fail open to the documented default
        pass
    return DEFAULT_TERMINAL


def _validate(data) -> tuple[dict | None, str | None]:
    if not isinstance(data, dict):
        return None, "the input must be a JSON object"
    if data.get("status") in ("unavailable", "unsupported"):
        return data, None
    moves = data.get("transitions")
    if not isinstance(moves, list):
        return None, "`transitions` must be a list"
    for i, m in enumerate(moves):
        if not isinstance(m, dict) or not isinstance(m.get("to"), str) or not m["to"].strip():
            return None, f"transitions[{i}] needs a non-empty `to` (the status the move lands in)"
        cat = m.get("category")
        if cat is not None and cat not in CATEGORIES:
            return None, f"transitions[{i}].category must be one of {', '.join(CATEGORIES)} or null"
    cur = data.get("current")
    if cur is not None and not isinstance(cur, str):
        return None, "`current` must be a status name or null"
    return data, None


def plan(data: dict, want: str, tid: str | None = None,
         from_config: bool = True) -> tuple[dict, int]:
    who = f"`{tid}`" if tid else "this ticket"
    Who = f"`{tid}`" if tid else "This ticket"
    out = {"result": None, "want": want, "current": data.get("current"), "target": None,
           "via": None, "category": None, "available": [], "suggestion": None, "checked": True,
           "message": None}

    if data.get("status") in ("unavailable", "unsupported"):
        reason = str(data.get("reason") or "no reason given")
        out.update({"result": data["status"], "target": want, "checked": False,
                    "message": f"I could not read which statuses {who} can move to, so `{want}` is "
                               f"the configured final status, not checked against the tracker. "
                               f"Details: list_transitions returned {data['status']}: {reason}."})
        return out, EXIT_UNREAD

    moves = data["transitions"]
    out["available"] = [m["to"].strip() for m in moves]
    cur = data.get("current")
    if isinstance(cur, str) and _norm(cur) == _norm(want):
        out.update({"result": "already_there", "target": cur.strip(),
                    "message": f"{Who} is already in `{cur.strip()}`, so there is nothing to move."})
        return out, EXIT_OK

    if data.get("free_form"):
        out.update({"result": "free_form", "target": want, "via": want,
                    "message": f"This tracker takes any status word, so {who} moves to `{want}`."})
        return out, EXIT_OK

    hits = [m for m in moves if _norm(m["to"]) == _norm(want)]
    if len(hits) == 1:
        m = hits[0]
        out.update({"result": "move", "target": m["to"].strip(), "via": m.get("via"),
                    "category": m.get("category"),
                    "message": f"{Who} can move to `{m['to'].strip()}`."})
        return out, EXIT_OK

    if len(hits) > 1:
        out.update({"result": "ambiguous",
                    "message": f"More than one move takes {who} to `{want}`, so I need you to pick "
                               f"one. Details: transitions "
                               f"{', '.join(str(m.get('via')) for m in hits)} all land in `{want}`."})
        return out, EXIT_NO_ROUTE

    done = [m for m in moves if m.get("category") == "done"]
    if len(done) == 1:
        out["suggestion"] = done[0]["to"].strip()
    where = f" from `{cur.strip()}`" if isinstance(cur, str) and cur.strip() else ""
    offered = ", ".join(f"`{s}`" for s in out["available"]) or "none"
    out.update({"result": "no_route",
                "message": f"{Who} cannot move to `{want}`{where}. It can move to: {offered}. "
                           f"Which one should it go to? Details: "
                           + (f"`{want}` is `project.terminal_status`; set it to your workflow's "
                              f"final status to stop this question." if from_config else
                              f"`{want}` was asked for with --want.")})
    return out, EXIT_NO_ROUTE


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        prog="transition_plan.py",
        description="Pick the status /ship moves a ticket to, from the tracker's own list of moves.",
        epilog="Exit codes: 0 target known, 2 usage, 4 malformed input, 7 moves not readable "
               "(target unchecked), 8 no single move reaches the wanted status.")
    ap.add_argument("--transitions", required=True, metavar="FILE",
                    help="the list_transitions return as JSON (`-` reads stdin)")
    ap.add_argument("--want", default=None, metavar="STATUS",
                    help="the status to reach (default: the merged project.terminal_status, else Done)")
    ap.add_argument("--id", dest="tid", default=None, help="the ticket id, for the message text")
    ap.add_argument("--root", default=None, help="repo root for the config read")
    ap.add_argument("--stack", default=None, help="explicit tier-1 stack.yaml path")
    args = ap.parse_args(argv)

    if args.want is not None and not args.want.strip():
        ap.error("--want needs a status name")
    try:
        raw = sys.stdin.read() if args.transitions == "-" else Path(args.transitions).read_text()
        data = json.loads(raw)
    except FileNotFoundError:
        ap.error(f"no file at {args.transitions}")
    except json.JSONDecodeError as exc:
        data, err = None, f"the input is not JSON ({exc})"
    else:
        data, err = _validate(data)
    want = args.want.strip() if args.want else _configured_terminal(args.root, args.stack)
    if err:
        out = {"result": "malformed", "want": want, "target": None, "via": None,
               "message": f"The list of moves from the tracker could not be read. Details: {err}."}
        print(json.dumps(out, indent=2))
        print(f"transition_plan: {out['message']}", file=sys.stderr)
        return EXIT_MALFORMED
    out, code = plan(data, want, args.tid, from_config=args.want is None)
    print(json.dumps(out, indent=2))
    if code not in (EXIT_OK,):
        print(f"transition_plan: {out['message']}", file=sys.stderr)
    return code


if __name__ == "__main__":
    sys.exit(main())
