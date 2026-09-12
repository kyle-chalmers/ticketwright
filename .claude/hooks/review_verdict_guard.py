#!/usr/bin/env python3
"""PreToolUse hook — the review-before-ship gate, at the command layer.

`/ship` asks before delivering a ticket that has no APPROVE on file. That gate lived only in the
skill's prose, so it fired only when a human typed `/ship`. Two real tickets shipped unreviewed by
`git push` + `gh pr create` — the skill never ran, and nothing said anything. A skill instruction is
GUIDANCE by the kit's own definition; this file is the ENFORCEMENT half, exactly as
db_write_guard.py presents bin/sql_scan.py and source_material_guard.py presents
bin/scan_source_materials.py. THE CLASSIFIER LIVES IN bin/review_verdict.py; this is the
Claude-protocol presenter.

JURISDICTION — outbound vcs actions, parsed by subcommand, never by substring:

  git push                       the branch leaves the machine
  gh pr create | gh pr merge     GitHub PR opened or merged
  glab mr create | glab mr merge GitLab
  az repos pr create             Azure DevOps

`git commit` is deliberately NOT here: committing during a build is routine, and a
REQUEST-CHANGES verdict during the fix loop is normal. The record leaves the machine at push/PR
time, and that is where the question belongs.

WHICH TICKET — the command's path arguments, its cwd, and the checked-out branch (the kit names a
ticket's branch `<id>`, or `<owner>-<id>` when the id was taken), resolved without spawning git.
A ticket with nothing in `final_deliverables/` has nothing to review yet and is skipped, so a
work-in-progress push of an empty scaffold costs no prompt.

WHAT IT ASKS — when a located ticket has deliverables and its verdict is anything but APPROVE:
none, SKIPPED (an unreviewed ship already recorded — never approval), REQUEST-CHANGES, or an
unreadable file. It only ever ADDS a confirmation; it never denies.

POLICY — `hard_halt_before_external_posts` (the same policy that gates /ship's Phase B: a push or
PR is the record leaving the machine). `false` is an explicit operator instruction and silences
the guard; a missing or unparseable value resolves to `true` — unparseable config never widens
what leaves the repo unprompted.

WHAT IT CANNOT DO — stated plainly (tiebreaker 6). Its jurisdiction is Bash: a push from a git
client, an IDE button, or a browser never reaches it. Within Bash it tokenizes the command the way
the shell does (quotes respected; `&&`, `;`, `|`, `(`, `)` split segments; a leading `command`,
`exec`, `time`, `nohup` or `{` is stepped over), so `(cd <ticket> && git push)` is seen and
`git commit -m "a && git push"` is not — but a command wrapped in `bash -c '…'`, `sudo`, `env`
with flags, an alias, or a script file is opaque to it and passes. It reads the record, not the
work: an APPROVE typed by hand is an APPROVE here.

Repo-gated: with no project `stack.yaml`, no output at all. Stdlib only. Always exits 0.
"""
from __future__ import annotations

import json
import shlex
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from _stack import find_stack, hard_halt_mode, HH_OFF  # noqa: E402

try:
    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "bin"))
    import review_verdict as _rv
    _RV_IMPORT_ERROR: Exception | None = None
except Exception as _e:  # noqa: BLE001 — any import failure maps to gating MORE, below
    _rv, _RV_IMPORT_ERROR = None, _e

_PUNCT = "();<>|&"
_WRAPPERS = {"command", "exec", "time", "nohup", "{", "}"}
_GIT_VALUE_FLAGS = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path",
                    "--config-env"}
# binary -> (value-taking global flags, the bare-token sequences that count as outbound)
_OUTBOUND = {
    "git": (_GIT_VALUE_FLAGS, {("push",)}),
    "gh": ({"-R", "--repo"}, {("pr", "create"), ("pr", "merge")}),
    "glab": ({"-R", "--repo"}, {("mr", "create"), ("mr", "merge")}),
    "az": ({"-o", "--output", "--subscription", "--query"}, {("repos", "pr", "create")}),
}


def _segments(command: str) -> list[list[str]]:
    """Shell-tokenize, then split into command segments on operators and parentheses.

    `shlex` with punctuation_chars honors quotes BEFORE it sees an operator, so `-m "a && git
    push"` stays one word and never becomes a segment (a plain regex split fired on exactly that),
    while `(cd x && git push)` yields `(`, `cd x`, `&&`, `git push`, `)` — the subshell shape an
    agent uses to push from a ticket folder, which a regex split anchored on tokens[0] missed.
    Unbalanced quotes fall back to whitespace splitting: this guard only ever adds a prompt, so
    erring toward seeing a command costs a confirmation, never a silent pass.
    """
    try:
        lex = shlex.shlex(command, posix=True, punctuation_chars=_PUNCT)
        lex.whitespace_split = True
        tokens = list(lex)
    except ValueError:
        tokens = command.replace("\n", " ; ").split()
    segments: list[list[str]] = []
    cur: list[str] = []
    for tok in tokens:
        if tok and all(c in _PUNCT for c in tok):
            if cur:
                segments.append(cur)
            cur = []
            continue
        cur.append(tok)
    if cur:
        segments.append(cur)
    return segments


def _bare_tokens(tokens: list[str], value_flags: set[str], limit: int = 3) -> list[str]:
    out: list[str] = []
    i = 1
    while i < len(tokens) and len(out) < limit:
        tok = tokens[i]
        if tok in value_flags:
            i += 2
            continue
        if tok.startswith("-"):
            i += 1
            continue
        out.append(tok)
        i += 1
    return out


def outbound_action(command: str) -> str | None:
    """The outbound vcs action a command performs ('git push', 'gh pr create', …), or None."""
    for tokens in _segments(command):
        while tokens and (tokens[0] in _WRAPPERS or ("=" in tokens[0] and not tokens[0].startswith("-"))):
            tokens = tokens[1:]           # wrappers and leading VAR=value assignments
        if not tokens:
            continue
        binary = Path(tokens[0]).name.strip("'\"")
        spec = _OUTBOUND.get(binary)
        if not spec:
            continue
        value_flags, sequences = spec
        bare = _bare_tokens(tokens, value_flags)
        for seq in sequences:
            if tuple(bare[:len(seq)]) == seq:
                return " ".join((binary,) + seq)
    return None


def _command_paths(command: str, cwd: Path) -> list[Path]:
    try:
        tokens = shlex.split(command)
    except ValueError:
        return []
    out: list[Path] = []
    for tok in tokens[1:]:
        if tok.startswith("-") or "=" in tok:
            continue
        cand = Path(tok)
        if not cand.is_absolute():
            cand = cwd / cand
        try:
            if cand.exists():
                out.append(cand.resolve())
        except OSError:
            continue
    return out


def assess(command: str, cwd_raw: str, repo: Path) -> str | None:
    """The gate's judgment as a message, or None for silence. Pure: no I/O beyond reading files.

    Shared with bin/hook_shim.py, which presents the same message in other runtimes' protocols.
    Raises only if the classifier is missing — callers turn that into a fail-safe ask.
    """
    if _rv is None:
        raise RuntimeError(f"bin/review_verdict.py could not be loaded ({_RV_IMPORT_ERROR})")
    action = outbound_action(command)
    if not action:
        return None
    cwd = Path(cwd_raw) if cwd_raw else repo
    tickets = _rv.locate(repo, _command_paths(command, cwd), cwd, _rv.current_branch(repo))
    problems = []
    for t in tickets:
        rec = _rv.classify(t)
        if rec["deliverables"] == 0 or rec["status"] == _rv.STATUS_APPROVE:
            continue
        problems.append(f"`{rec['locator']}` — {_rv.describe(rec)}; final_deliverables/ holds "
                        f"{rec['deliverables']} file(s)")
    if not problems:
        return None
    return (f"review_verdict_guard: `{action}` is about to deliver work with no APPROVE on file — "
            + "; ".join(problems) +
            ". `/build` runs `/review` for you; `/ship` records an unreviewed ship as SKIPPED with your "
            "instruction on the record. Run `/review <owner>/<id>`, or approve this "
            f"`{action}` explicitly. (Jurisdiction: Bash — a push from another tool never reaches "
            "this guard; it reads the record, not the work.)")


def emit(decision: str | None = None, reason: str = "", system_message: str = "") -> None:
    out: dict[str, object] = {}
    if decision:
        out["hookSpecificOutput"] = {
            "hookEventName": "PreToolUse",
            "permissionDecision": decision,
            "permissionDecisionReason": reason,
        }
    if system_message:
        out["systemMessage"] = system_message
    if out:
        print(json.dumps(out))


def _ask_or_note(payload: dict, message: str) -> int:
    if payload.get("permission_mode") == "bypassPermissions":
        emit(system_message=f"{message} Approval not requested: the session is in "
                            f"bypassPermissions mode.")
        return 0
    emit("ask", message)
    return 0


def run() -> int:
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return 0
    if payload.get("tool_name") != "Bash":
        return 0
    command = ((payload.get("tool_input") or {}).get("command", "") or "").strip()
    if not command or outbound_action(command) is None:
        return 0  # outside this guard's jurisdiction entirely
    cwd_raw = payload.get("cwd", "") or ""
    stack = find_stack(cwd_raw)
    if stack is None:
        return 0  # not a configured ticketwright repo
    if hard_halt_mode(stack) == HH_OFF:
        return 0  # explicit operator instruction
    repo = stack.parent.parent.parent
    try:
        message = assess(command, cwd_raw, repo)
    except Exception as e:  # noqa: BLE001 — a classifier that cannot run gates MORE, visibly
        return _ask_or_note(payload, (
            f"review_verdict_guard: the classifier (bin/review_verdict.py) could not run "
            f"({e.__class__.__name__}: {e}). The review verdict cannot be read, so this outbound "
            f"command is gated — more, never less. Restore the kit's bin/ directory."))
    if message is None:
        return 0
    return _ask_or_note(payload, message)


def main() -> int:
    try:
        return run()
    except Exception:  # noqa: BLE001 — a guard must never block a session
        return 0


if __name__ == "__main__":
    sys.exit(main())
