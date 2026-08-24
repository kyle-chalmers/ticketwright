#!/usr/bin/env python3
"""PreToolUse hook — mechanical enforcement of the source-material privacy policy.

A ticket's `source_materials/` holds inputs a person dropped in, and the one that motivated this
guard is the meeting transcript: the most PII- and confidentiality-dense artifact the kit touches.
The policy is CURATED EXCERPTS ARE COMMITTED; RAW FULL TRANSCRIPTS ARE NOT, BY DEFAULT — and
before this hook, nothing enforced it. A skill instruction to inspect files is GUIDANCE by the
kit's own definition ("a named file or workflow carries it and honoring it is on the agent"), and
two paths bypassed the skills entirely:

  git add -f / git commit   run directly, with no skill involved
  cp -r <ticket dir> <dest> the docstore `backup` verb — ALSO reached from the productized-skill
                            template, which backs up and commits without ever calling /ship
  rclone copy <ticket dir>  the same verb on an UNMOUNTED docstore, where the destination is a
                            cloud remote rather than a path, so no `cp` appears at all

Both are Bash, so one PreToolUse/Bash presenter covers both, at the COMMAND layer rather than the
workflow layer. That is the whole reason this file exists instead of another paragraph in a skill.

THE CLASSIFIER LIVES IN bin/scan_source_materials.py (one deterministic implementation, shared
with the non-Claude runtime shims); this file is the Claude-protocol presenter, exactly as
db_write_guard.py presents bin/sql_scan.py.

The policy is a two-value enum in `.claude/config/stack.yaml`:

    policies:
      source_material_guard: on     # on | off

`on` is the default and a missing, malformed, or unrecognized value resolves to `on` — unparseable
config must never quietly widen what leaves the repo unprompted. `off` is an explicit operator
instruction and silences the guard.

WHAT IT ASKS ABOUT, and why the two paths differ:

  git add / git commit   EVERY raw_suspect is asked about, whatever its name. The guard does not
                         try to predict git's ignore decision: it would have to read the repo's
                         real `.gitignore` rather than the kit's shipped template, and an existing
                         install predating those patterns would then stage a transcript silently.
                         The shipped patterns and this guard are belt and braces, not a division
                         of labour — the patterns keep self-declaring names out of the index by
                         default, and the guard covers the ones no pattern can see.
  cp -r / rsync /        `.gitignore` has NO bearing on a copy, so ignore state is irrelevant
  rclone copy
                         here and every raw_suspect under the copied path is asked about. A
                         transcript moved into `source_materials/private/` is safe from git and
                         still rides a folder-wide docstore backup — remedies are not
                         interchangeable, and the prompt text says so.

WHAT IT CANNOT DO — stated plainly rather than implying parity (AGENTS.md tiebreaker 6). Its
jurisdiction is Bash. A file written through a non-Bash tool, copied in a file manager, or
uploaded by a browser is outside it. And the classifier matches filenames and document shape,
never MEANING: a curated summary quoting confidential material verbatim passes. This gate is
about the bulk artifact, not a confidentiality review.

Repo-gated: with no project `stack.yaml`, no output at all. There is deliberately no fallback to
the kit's own shipped config — that fallback is how a globally enabled plugin starts firing in
unrelated repos.

Input  (stdin): PreToolUse JSON { tool_name, tool_input:{command}, cwd, permission_mode }
Output (stdout): a permissionDecision and/or systemMessage; otherwise nothing.
Stdlib only. Always exits 0 — a nonzero PreToolUse exit *blocks* the call, so every path,
including unexpected exceptions, returns 0. A guard only ever ADDS a confirmation; it never denies.
"""
from __future__ import annotations

import json
import re
import shlex
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from _stack import find_stack, source_material_mode, SM_OFF  # noqa: E402

# The classifier sits in the kit's bin/, a sibling of this hook's .claude/hooks/ in every install
# shape (repo, plugin cache, `ticketwright init` vendor, wheel _kit). Handled explicitly in run().
try:
    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "bin"))
    import scan_source_materials as _scan
    _SCAN_IMPORT_ERROR: Exception | None = None
except Exception as _e:  # noqa: BLE001 — any import failure maps to gating MORE, below
    _scan, _SCAN_IMPORT_ERROR = None, _e

# Git's subcommand is found by PARSING, not by matching anywhere in the string. A broad
# alternation was tried and is wrong in both directions: `\bgit\b[^;&|]*?\b(add|stage|commit)\b`
# fires on `git log --grep=commit` and `git config --get user.commit` (read-only commands that a
# deny-only runtime would then BLOCK), while a flags-only alternation misses `git -C <path> add`
# because it cannot span a flag's value. So: split the line into command segments, then walk each
# segment's tokens skipping global flags and the values of the ones that take a value, and read
# the first bare token. That is the subcommand, and nothing else is.
_GIT_VALUE_FLAGS = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path",
                    "--config-env"}
_GIT_STAGING_SUBCOMMANDS = {"add", "stage", "commit"}
_SEGMENT_SPLIT_RE = re.compile(r"(?:\|\||&&|[;|&\n])")


def _git_staging_segments(command: str) -> bool:
    """True when any command segment invokes a git subcommand that writes to the index."""
    for segment in _SEGMENT_SPLIT_RE.split(command):
        try:
            tokens = shlex.split(segment)
        except ValueError:
            tokens = segment.split()
        while tokens and ("=" in tokens[0] and not tokens[0].startswith("-")):
            tokens = tokens[1:]          # leading VAR=value assignments
        if not tokens or Path(tokens[0]).name != "git":
            continue
        i = 1
        while i < len(tokens):
            token = tokens[i]
            if token in _GIT_VALUE_FLAGS:
                i += 2                    # the flag and its separate value
                continue
            if token.startswith("-"):
                i += 1                    # a flag, or --flag=value
                continue
            if token in _GIT_STAGING_SUBCOMMANDS:
                return True
            break                         # the subcommand is something else
        continue
    return False
# `cp -r` / `rsync` / `rclone` reach a docstore. The mounted docstore adapters back up with
# `cp -r`, but a docstore does not have to be a filesystem: the `rclone` adapter uploads straight
# to a cloud remote with no mount in the path, so matching only `cp`/`rsync` would let the
# unmounted backup verb carry raw transcripts out of the repo without ever meeting this guard —
# the same escape the productized-skill template opened for `cp -r`. rclone's directory verbs are
# recursive by definition (they transfer a directory's CONTENTS), so they need no `-r` to qualify.
_COPY_RE = re.compile(r"\b(?:cp|rsync|rclone)\b")
# rclone accepts global flags BEFORE the subcommand (`rclone -vv copy …`,
# `rclone --config x.conf copy …`), and is often invoked by absolute path. Requiring the subcommand
# to sit immediately after the binary name let every one of those forms copy a ticket directory
# without meeting this guard — a gate with a documented syntax bypass is not a gate.
# A trailing `['"]?` covers a quoted binary name (`'rclone' copy …`, `"cp" -r …`) — quoting the
# command is a one-character bypass of an unquoted match, and this guard only ever ADDS a prompt,
# so erring toward matching costs nothing.
_COPY_RECURSIVE_RE = re.compile(
    r"\b(?:cp['\"]?\s+(?:-\S*[raR]\S*|--recursive|--archive)|rsync"
    r"|rclone['\"]?(?:\s+-{1,2}[^\s]*(?:[= ][^\s-][^\s]*)?)*\s+(?:copy|copyto|sync|move|moveto))\b")
_FORCE_RE = re.compile(r"(?:^|\s)(?:-[a-zA-Z]*f[a-zA-Z]*|--force)(?:\s|$)")


def _tokenized_copy(command: str) -> bool:
    """True when the command TOKENIZES to a recursive copy, whatever the quoting.

    The regexes above read the raw string, so `rclone "copy" x r:p`, `rclone 'copy' …` and
    `rclone c\\opy …` all execute a recursive copy while matching nothing — shell quoting is a
    one-character bypass of a pattern match. shlex resolves quotes and escapes the way the shell
    does, so this covers those forms without a regex arms race. Best-effort by design: an
    unparseable command falls back to the regexes rather than raising.
    """
    try:
        tokens = shlex.split(command)
    except ValueError:
        return False
    rclone_verbs = {"copy", "copyto", "sync", "move", "moveto"}
    for i, tok in enumerate(tokens):
        base = tok.rsplit("/", 1)[-1]
        rest = [t for t in tokens[i + 1:] if not t.startswith("-")]
        if base == "rclone":
            if rest and rest[0] in rclone_verbs:
                return True
        elif base in ("cp", "rsync"):
            flags = [t for t in tokens[i + 1:] if t.startswith("-")]
            if base == "rsync":
                return True
            if any(f in ("--recursive", "--archive") or
                   (f.startswith("-") and not f.startswith("--")
                    and any(c in f for c in "raR")) for f in flags):
                return True
    return False


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


def _command_paths(command: str, cwd: Path) -> list[Path]:
    """Resolved non-flag path arguments. Best-effort — unparseable commands yield []."""
    try:
        tokens = shlex.split(command)
    except ValueError:
        return []
    out: list[Path] = []
    for token in tokens[1:]:
        if token.startswith("-"):
            continue
        if token in ("git", "cp", "rsync", "rclone", "copy", "copyto", "sync", "move", "moveto",
                     "add", "stage", "commit", "&&", "||", ";"):
            continue
        # An env assignment (`FOO=bar`) or a commit message is not a path; the exists() check
        # below drops both without needing to recognize them.
        candidate = Path(token)
        if not candidate.is_absolute():
            candidate = cwd / candidate
        try:
            if candidate.exists():
                out.append(candidate.resolve())
        except OSError:
            continue
    return out


def _under(child: Path, parents: list[Path]) -> bool:
    for parent in parents:
        try:
            child.relative_to(parent)
            return True
        except ValueError:
            continue
    return False


def run() -> int:
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return 0  # not invoked as a hook / no payload

    if payload.get("tool_name") != "Bash":
        return 0
    command = ((payload.get("tool_input") or {}).get("command", "") or "").strip()
    if not command:
        return 0

    staging = _git_staging_segments(command)
    copying = (bool(_COPY_RE.search(command)) and bool(_COPY_RECURSIVE_RE.search(command))) \
        or _tokenized_copy(command)
    if not (staging or copying):
        return 0  # outside this guard's jurisdiction entirely

    cwd_raw = payload.get("cwd", "") or ""
    stack = find_stack(cwd_raw)
    if stack is None:
        return 0  # not a configured ticketwright repo — stay out of the way entirely

    if source_material_mode(stack) == SM_OFF:
        return 0  # explicit operator instruction, readable without the classifier

    repo = stack.parent.parent.parent  # <repo>/.claude/config/stack.yaml

    if _scan is None:
        # FAIL-SAFE, not fail-open: without the classifier nothing can be assessed, so a command
        # in this guard's jurisdiction is gated and the malfunction is NAMED rather than swallowed.
        return _ask_or_note(payload, (
            f"source_material_guard: the classifier (bin/scan_source_materials.py) could not be "
            f"loaded ({_SCAN_IMPORT_ERROR}). Source material cannot be assessed, so this "
            f"staging/copy command is gated — more, never less. Restore the kit's bin/ directory."
        ))

    try:
        records = _scan.scan(repo)
        flagged = _scan.flagged(records)
    except Exception as e:  # noqa: BLE001 — a classifier that misbehaves must gate, not fall through
        return _ask_or_note(payload, (
            f"source_material_guard: the classifier failed while assessing source material "
            f"({e.__class__.__name__}: {e}). This staging/copy command is gated until the kit "
            f"is repaired."
        ))

    # An INCOMPLETE scan does not certify anything. Treat it exactly like a finding: the tree was
    # not fully looked at, so "no raw_suspect found" is not a statement anyone should act on.
    partial = _scan.incomplete(records)
    if partial and not flagged:
        return _ask_or_note(payload, (
            f"source_material_guard: the source-material scan did NOT cover the whole tree "
            f"({partial[0]['reason']}), so it cannot certify that no raw transcript is present. "
            f"Gating rather than assuming clean. Narrow the command to one ticket, or check the "
            f"folder by hand."))

    if not flagged:
        return 0

    cwd = Path(cwd_raw) if cwd_raw else repo
    if copying:
        # .gitignore has NO bearing on any copy verb (cp -r, rsync, rclone copy), so ignore
        # state is irrelevant: every raw_suspect under a copied path counts. When the paths cannot be parsed, fall back to the whole
        # repo — gating more, visibly, rather than guessing that nothing is in scope.
        # Narrow by the copied path ONLY when a parsed path actually lands inside this repo.
        # Otherwise fall back to every flagged file — gating more, visibly. Without that fallback
        # a command whose source token did not parse (an unexpanded `~`, a variable, a glob) but
        # whose DESTINATION exists would yield a non-empty, unrelated `paths`, filter every
        # finding out, and pass in silence.
        paths = [p for p in _command_paths(command, cwd) if _under(p, [repo.resolve()])]
        relevant = [r for r in flagged if not paths or _under(Path(r["file"]).resolve(), paths)]
        verb, why = "backed up", (
            "A folder-wide docstore backup copies everything in the ticket directory, and "
            "`.gitignore` does not apply to a docstore copy (`cp -r`, `rsync` or "
            "`rclone copy`) — so moving a file under "
            "`source_materials/private/` protects git and does NOT protect this copy. Remove the "
            "file from the folder, or approve this copy explicitly."
        )
    else:
        # EVERY raw_suspect counts here, whatever its filename. An earlier version assumed a
        # `*transcript*` file was already gitignored and so needed asking about only under `-f`.
        # That assumption is a FAIL-OPEN: it reads the kit's SHIPPED template, not the repo's
        # actual `.gitignore`. An existing install predating those patterns, or a user who edited
        # their own ignore file, would stage the transcript with no prompt at all. Consulting git
        # for real would mean a subprocess inside a 10s hook budget whose failure modes all land
        # in "never block a session" — so the guard asks instead. One extra confirmation on an
        # already-ignored file is the correct price for never missing one that is not.
        relevant = list(flagged)
        verb, why = "committed", (
            "Rename it to the curated form `YYYY-MM-DD-<slug>-meeting.md` after trimming it to "
            "the decisions and action items, move it under `source_materials/private/`, or "
            "approve this staging explicitly."
        )

    if not relevant:
        return 0

    listing = "; ".join(f"{Path(r['file']).name} ({r['reason']})" for r in relevant[:4])
    if len(relevant) > 4:
        listing += f"; and {len(relevant) - 4} more"
    return _ask_or_note(payload, (
        f"source_material_guard: raw transcript material may be about to be {verb} — {listing}. "
        f"{why} (The classifier matches filenames and document shape, never meaning — it is a "
        f"gate against the bulk artifact, not a confidentiality review.)"
    ))


def _ask_or_note(payload: dict, message: str) -> int:
    """Ask, unless the operator turned prompting off for the session — then say so visibly."""
    if payload.get("permission_mode") == "bypassPermissions":
        emit(system_message=f"{message} Approval not requested: the session is in "
                            f"bypassPermissions mode.")
        return 0
    emit("ask", message)
    return 0


def main() -> int:
    try:
        return run()
    except Exception:  # noqa: BLE001 — a guard must never block a session
        return 0


if __name__ == "__main__":
    sys.exit(main())
