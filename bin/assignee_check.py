#!/usr/bin/env python3
"""assignee_check.py: whether /ticket offers to assign the ticket to the person running it.

WHY THIS FILE EXISTS. /ticket read the tracker's assignee and never wrote it, so a teammate who
picked up an unassigned ticket, or one still sitting on whoever triaged it, left the tracker saying
nobody (or somebody else) was working it. The offer to fix that is a question, never a silent write,
and whether to ask at all is a comparison the model should not approximate: this CLI makes it from
`fetch_ticket`'s assignee and the person's own config, the same way for every tracker.

THE ONE RULE: WHO THE PERSON IS IN THE TRACKER IS ENUMERATED, NEVER GUESSED. The account to assign is
`tracker_handle` from the person's merged `people/<id>.yaml` (`bin/effective_config.py`). When that
key is unset, the caller may pass the account signed in to the tracker (`--signed-in`), and the
result says it came from there, because a signed-in account can belong to someone else (a shared
demo login). With neither, there is nothing to assign and nothing is offered. Matching the current
assignee is exact after trimming and case-folding: its id, login or email against `tracker_handle`
(or the signed-in account when that is what would be assigned), and its email against the person's
`identities`. Display names are never matched: two people can share one.

  assignee_check.py --assignee fetched.json --id TEST-14 [--signed-in <account id>] [--handle-id <id>]
                    [--mode replace|add]
  … | assignee_check.py --assignee -

Input is the assignee part of the `fetch_ticket` return, normalized by the caller:
  {"assignees": [{"id": "...", "login": "...", "email": "...", "name": "..."}]}
Every field of an entry is optional (an entry needs at least one); an empty list is unassigned.
`--handle-id` is `tracker_handle` looked up to the form the tracker's fetch returns, when the two
differ (a Jira email looked up to its accountId, since Atlassian usually hides emails): it also counts
as the person's and is what gets assigned. `--signed-in` is a real account id read from the tracker,
never a placeholder such as `me`, which no fetched assignee could ever match.
`--mode` is the adapter's `assign_ticket` mode (`replace` when the tracker holds one assignee,
`add` when it holds several), so the question says what happens to whoever is on it now.

Output (JSON on stdout): {"status": "mine" | "unassigned" | "someone_else" | "no_person",
"offer": bool, "assign_to": str | null, "assign_to_source": "tracker_handle" | "signed_in" | null,
"current": [names], "mode", "question": str | null, "note": str | null}. The question and note are
written for the person, in plain words. `offer` is true only for `unassigned` or `someone_else`
with an account to assign, and never for a person with no `people/<id>.yaml`.

EXIT CODES: 0 the input was read (whether or not to offer is in `offer`) · 2 usage · 4 malformed.

Stdlib only. Read-only. Makes no tracker call: the adapter's `fetch_ticket` did that, and its
`assign_ticket` makes the write, after the person's yes.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

EXIT_OK, EXIT_USAGE, EXIT_MALFORMED = 0, 2, 4
FIELDS = ("id", "login", "email", "name")
MODES = ("replace", "add")


def _norm(s) -> str:
    return " ".join(str(s).split()).casefold() if isinstance(s, str) else ""


def _person(root: str | None, person: str | None, stack: str | None) -> tuple[str | None, dict]:
    """The resolved person id and their merged tier-2 config; (None, {}) when it cannot be read.

    A person with no `people/<id>.yaml` in either home is no person here: nothing says which tracker
    account is theirs, and the signed-in account could be anyone's.
    """
    try:
        import effective_config as ec
        res = ec.resolve(root or os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd(), person, stack)
        if not res.person or res.person not in (res.people or []):
            return None, {}
        return res.person, dict(res.person_config or {})
    except Exception:  # noqa: BLE001 - no person means no offer, which is the safe answer
        return None, {}


def _validate(data) -> tuple[list | None, str | None]:
    if not isinstance(data, dict) or not isinstance(data.get("assignees"), list):
        return None, "the input must be a JSON object with an `assignees` list"
    out = []
    for i, a in enumerate(data["assignees"]):
        if not isinstance(a, dict):
            return None, f"assignees[{i}] must be an object"
        clean = {k: a[k].strip() for k in FIELDS if isinstance(a.get(k), str) and a[k].strip()}
        if not clean:
            return None, f"assignees[{i}] needs at least one of {', '.join(FIELDS)}"
        out.append(clean)
    return out, None


def _label(a: dict) -> str:
    return a.get("name") or a.get("login") or a.get("email") or a.get("id")


def check(assignees: list, person: str | None, person_config: dict, signed_in: str | None,
          mode: str, tid: str | None = None, handle_id: str | None = None) -> dict:
    who = f"`{tid}`" if tid else "This ticket"
    current = [_label(a) for a in assignees]
    out = {"status": None, "offer": False, "assign_to": None, "assign_to_source": None,
           "current": current, "mode": mode, "question": None, "note": None}
    if not person:
        out.update({"status": "no_person",
                    "note": "I can't tell who you are here, so I won't offer to assign the ticket. "
                            "Details: whoami did not resolve a person."})
        return out

    handle = person_config.get("tracker_handle")
    handle = handle.strip() if isinstance(handle, str) and handle.strip() else None
    hid = handle_id.strip() if isinstance(handle_id, str) and handle_id.strip() else None
    if handle:
        out.update({"assign_to": hid or handle, "assign_to_source": "tracker_handle"})
    elif isinstance(signed_in, str) and signed_in.strip():
        out.update({"assign_to": signed_in.strip(), "assign_to_source": "signed_in",
                    "note": f"Your people file has no tracker account, so this uses the account "
                            f"signed in to the tracker (`{signed_in.strip()}`). Details: set "
                            f"tracker_handle in people/{person}.yaml to choose it yourself."})

    mine_ids = {_norm(v) for v in (out["assign_to"], handle if out["assign_to"] else None) if v}
    emails = {_norm(i) for i in (person_config.get("identities") or []) if isinstance(i, str) and "@" in i}
    for a in assignees:
        if any(_norm(a.get(k)) in mine_ids for k in ("id", "login", "email")) \
                or (a.get("email") and _norm(a["email"]) in emails):
            out["status"] = "mine"
            return out

    out["status"] = "someone_else" if assignees else "unassigned"
    if not out["assign_to"]:
        out["note"] = ("I can't tell which tracker account is yours, so I won't offer to assign the "
                       f"ticket. Details: set tracker_handle in people/{person}.yaml.")
        return out

    out["offer"] = True
    you = f"you (`{out['assign_to']}`)"
    if not assignees:
        out["question"] = f"{who} has no assignee. Assign it to {you}?"
    elif mode == "add":
        names = ", ".join(current)
        out["question"] = f"{who} is assigned to {names}. Add {you} as well? {names} stays on it."
    else:
        names = ", ".join(current)
        out["question"] = (f"{who} is assigned to {names}. Assign it to {you} instead? "
                           f"That takes {names} off it.")
    return out


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Whether /ticket offers to assign the ticket to you.")
    ap.add_argument("--assignee", required=True, help="the normalized fetch_ticket assignee JSON, or - for stdin")
    ap.add_argument("--signed-in", default=None, help="the tracker's signed-in account id (never a placeholder like me), used only when tracker_handle is unset")
    ap.add_argument("--handle-id", default=None, help="tracker_handle looked up to the tracker's own id by the adapter (an email to an accountId), when the two forms differ")
    ap.add_argument("--mode", default="replace", choices=MODES, help="the adapter's assign_ticket mode")
    ap.add_argument("--id", default=None, help="the ticket id, for the question text")
    ap.add_argument("--person", default=None, help="person id (default: resolved)")
    ap.add_argument("--root", default=None, help="repo root (default: $CLAUDE_PROJECT_DIR, else cwd)")
    ap.add_argument("--stack", default=None, help="explicit tier-1 stack.yaml path")
    try:
        args = ap.parse_args(argv)
    except SystemExit:
        return EXIT_USAGE
    try:
        raw = sys.stdin.read() if args.assignee == "-" else Path(args.assignee).read_text(encoding="utf-8")
        data = json.loads(raw)
    except (OSError, ValueError) as e:
        print(f"I could not read the ticket's assignee. Details: {e}", file=sys.stderr)
        return EXIT_MALFORMED
    assignees, err = _validate(data)
    if err:
        print(f"I could not read the ticket's assignee. Details: {err}", file=sys.stderr)
        return EXIT_MALFORMED
    person, pconf = _person(args.root, args.person, args.stack)
    print(json.dumps(check(assignees, person, pconf, args.signed_in, args.mode, args.id, args.handle_id), indent=2))
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
