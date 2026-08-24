#!/usr/bin/env python3
"""Adapt the kit's hooks to each non-Claude runtime's hook protocol (PROMPT 7 / U3).

  hook_shim.py --runtime <name> --hook <db_write_guard | source_material_guard |
               session_context | ticket_index_context | regenerate_ticket_index>
               [--root <path>]

One deterministic engine, many presenters: the Claude hook (.claude/hooks/db_write_guard.py)
presents bin/sql_scan.py's verdicts in Claude's PreToolUse protocol; this shim presents the same
verdicts in the other runtimes' protocols, selected by the `hook_protocol` key each
adapters/runtime/*.md declares — never by a runtime name in branch logic:

  codex-json   deny via {"hookSpecificOutput": {"permissionDecision": "deny", …}} (exit 0);
               Codex parses but does not support "ask", so gating DENIES — with the escape hatch.
  cursor-json  {"permission": "ask"} — Cursor has an ask tier; the emitted config sets
               failClosed: true (required, not tuning: Cursor hooks fail OPEN by default).
  agy-json     {"decision": "ask"} — or "force_ask" for policy `all` on a gated statement, the
               Antigravity primitive that ignores cached grants (a remembered "yes" should not
               cover the next destructive statement).
  exit-code    Devin's documented contract (0 continues, 2 blocks, any OTHER nonzero is logged
               and does NOT block — so this shim maps every internal failure to a DELIBERATE
               exit 2, never a stray nonzero). OpenCode reaches the same protocol through the
               emitted plugin wrapper, which throws on exit 2 ("throwing an error prevents the
               tool from executing").
  claude-json  refused: Claude Code runs the native hook; routing it through a shim could only
               change its failure mode.
  unknown      refused, with the reason (cline today — hooks unverified upstream).

THE COLLAPSE (3b): `db_write_requires_approval: high_risk` needs an ask tier, and codex-cli,
opencode and devin have none. On those runtimes a gated statement is DENIED-WITH-ESCAPE — never
collapsed toward allow (protection silently gone) and never allowed to block additive work
(training people to turn the guard off). The deny message names the one-shot re-approval, a
manual ask tier:

  * re-run the exact command prefixed `TICKETWRIGHT_APPROVE=once ` — per-command by construction
    and visible in the transcript. The shim reads the PREFIX ON THE COMMAND, deliberately never
    its own environment: an exported variable cannot carry once-semantics.
  * or create the one-shot token `.claude/config/approve.once` (next to stack.yaml) — consumed
    (deleted) before the allow, honored only while fresh (15 minutes) so a token left behind by
    an abandoned approval cannot silently wave through a later statement.

MALFORMED INPUT is a per-runtime decision, recorded in the rendered AGENTS.md enforcement table:
a guard that cannot read its input must never guess allow. Ask-tier runtimes escalate to ask;
deny-only runtimes deny with the escape message (the token still works — a deliberate recent
human action — while the command prefix is unreadable inside unreadable input, and the message
says so). Two silences are preserved from the Claude hook: no project stack.yaml (repo-gated;
the shim is installed per-project but a de-configured repo must not brick) and `policies: off`
(an explicit operator instruction, readable without classifying anything).

JURISDICTION: pre-tool hooks on some runtimes fire for every tool. A payload that parses and
names a tool that is clearly NOT a shell (no command anywhere, tool name not shell-like) passes
untouched — the guard's jurisdiction is shell commands. A payload naming a shell-like tool whose
command cannot be extracted is treated as unreadable input, per the rule above.

The session/index hooks are presentation-only adapters: they run the corresponding Claude hook
as a child process (its documented interface) and wrap its stdout in
{"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": …}} — the shape
Codex CLI and Devin document. They import NOTHING from the guard path (a broken scanner must
never take the banners down with it) and always exit 0: a banner is not a safety gate.

Stdlib only; takes --root; no Claude environment variable required. Guard exit codes: 0, or a
deliberate 2 — never any other value, on any runtime (proven by selftest section 43).
TICKETWRIGHT_SHIM_FAULT=raise is a selftest-only fault injector proving that mapping.
"""
from __future__ import annotations

import argparse
import io
import json
import os
import re
import shlex
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import kit_paths  # noqa: E402

APPROVE_PREFIX = "TICKETWRIGHT_APPROVE=once"
APPROVE_TOKEN_REL = "approve.once"          # lives next to stack.yaml: .claude/config/approve.once
APPROVE_TOKEN_MAX_AGE = 15 * 60             # seconds; a stale token DENIES and says so

GUARD = "db_write_guard"
SM_GUARD = "source_material_guard"
SHELL_GUARDS = "shell_guards"   # both of the above, in one invocation
SESSION_HOOKS = ("session_context", "ticket_index_context")
REGEN = "regenerate_ticket_index"

# Jurisdiction, mirrored from .claude/hooks/source_material_guard.py (that file is where the
# reasoning lives). `git add`/`git commit` reach the index; `cp -r`/`rsync` reach a docstore.
# Git's subcommand is found by PARSING, not by matching anywhere in the string. A broad
# alternation was tried and is wrong in both directions: `\bgit\b[^;&|]*?\b(add|stage|commit)\b`
# fires on `git log --grep=commit` and `git config --get user.commit` (read-only commands that a
# deny-only runtime would then BLOCK), while a flags-only alternation misses `git -C <path> add`
# because it cannot span a flag's value. So: split the line into command segments, then walk each
# segment's tokens skipping global flags and the values of the ones that take a value, and read
# the first bare token. That is the subcommand, and nothing else is.
SM_GIT_VALUE_FLAGS = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path",
                    "--config-env"}
SM_GIT_SUBCOMMANDS = {"add", "stage", "commit"}
SM_SEGMENT_SPLIT_RE = re.compile(r"(?:\|\||&&|[;|&\n])")


def sm_git_staging(command: str) -> bool:
    """True when any command segment invokes a git subcommand that writes to the index."""
    for segment in SM_SEGMENT_SPLIT_RE.split(command):
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
            if token in SM_GIT_VALUE_FLAGS:
                i += 2                    # the flag and its separate value
                continue
            if token.startswith("-"):
                i += 1                    # a flag, or --flag=value
                continue
            if token in SM_GIT_SUBCOMMANDS:
                return True
            break                         # the subcommand is something else
        continue
    return False
SM_COPY_RE = re.compile(r"\b(?:cp|rsync)\b")
SM_COPY_RECURSIVE_RE = re.compile(r"\b(?:cp\s+(?:-\S*[raR]\S*|--recursive|--archive)|rsync)\b")

_SHELLISH = ("bash", "shell", "terminal", "exec", "cmd", "run_command", "run_terminal_cmd",
             "execute_command")


# ---------------------------------------------------------------------------------------------
# payload spelunking — defensive by design: only Claude documents its exact hook payload, so the
# shim searches bounded, deterministic key paths instead of betting on one vendor's field name.

def find_string(obj, keys: tuple[str, ...], depth: int = 3) -> str | None:
    """Depth-first search for the first string value under any of `keys`, bounded and ordered."""
    if depth < 0 or not isinstance(obj, dict):
        return None
    for k in keys:
        v = obj.get(k)
        if isinstance(v, str) and v.strip():
            return v
    for v in obj.values():
        if isinstance(v, dict):
            hit = find_string(v, keys, depth - 1)
            if hit:
                return hit
    return None


def tool_identity(payload: dict) -> str | None:
    return find_string(payload, ("tool_name", "toolName", "tool"), depth=2)


def looks_shellish(tool: str) -> bool:
    t = tool.lower()
    return any(s in t for s in _SHELLISH)


# ---------------------------------------------------------------------------------------------
# protocol presenters — each returns an exit code and prints its runtime's schema.

def present_pass() -> int:
    return 0  # no opinion: the runtime's own permission flow proceeds


def present_gate(protocol: str, message: str, policy: str) -> int:
    if protocol == "codex-json":
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": message,
        }}))
        return 0
    if protocol == "cursor-json":
        print(json.dumps({"permission": "ask", "reason": message}))
        return 0
    if protocol == "agy-json":
        decision = "force_ask" if policy == "all" else "ask"
        print(json.dumps({"decision": decision, "reason": message}))
        return 0
    # exit-code (devin; opencode via the plugin wrapper): the message goes to both streams —
    # which one a runtime surfaces is its own business — and the exit code carries the decision.
    print(message)
    print(message, file=sys.stderr)
    return 2


def ask_capable(protocol: str) -> bool:
    return protocol in ("cursor-json", "agy-json")


# ---------------------------------------------------------------------------------------------
# the one-shot escape (deny-only runtimes' manual ask tier)

def escape_text(stack_dir: Path | None, prefix_readable: bool) -> str:
    token = (stack_dir / APPROVE_TOKEN_REL) if stack_dir else Path(".claude/config") / APPROVE_TOKEN_REL
    prefix_half = (f"re-run the exact command prefixed `{APPROVE_PREFIX} `, or "
                   if prefix_readable else
                   f"(the `{APPROVE_PREFIX}` command prefix cannot be honored while the input is "
                   f"unreadable) ")
    return (f"To approve once: {prefix_half}create the one-shot token `{token}` "
            f"and retry (consumed on use; expires after 15 minutes).")


def escape_granted(command: str | None, stack: Path | None) -> str | None:
    """The one-shot approval, if present. Returns a description of what granted it, else None."""
    if command is not None and command.lstrip().startswith(APPROVE_PREFIX + " "):
        return f"command carries the `{APPROVE_PREFIX}` prefix (visible in the transcript)"
    if stack is not None:
        token = stack.parent / APPROVE_TOKEN_REL
        try:
            age = time.time() - token.stat().st_mtime
        except OSError:
            return None
        if age > APPROVE_TOKEN_MAX_AGE:
            return None  # stale: an abandoned approval must not cover a later statement
        try:
            token.unlink()  # consume BEFORE allowing — a token spends exactly once
        except OSError:
            return None    # cannot consume it -> cannot honor it
        return f"one-shot token `{token}` consumed"
    return None


# ---------------------------------------------------------------------------------------------
# hooks

def run_guard(protocol: str, root_arg: str | None) -> int:
    """The DB-write guard, presented in `protocol`. Everything here is inside main()'s
    map-to-deliberate-exit-2 boundary, so an internal failure can never be a stray nonzero."""
    # Lazily import the guard's dependencies HERE, not at module level: a broken scanner or
    # policy helper must never take the session/index shims down with it (gate-1 finding).
    hooks_dir = Path(__file__).resolve().parent.parent / ".claude" / "hooks"
    sys.path.insert(0, str(hooks_dir))
    import _stack  # noqa: E402  — the ONE policy reader, in-process, fail-safe to MODE_ALL

    raw = sys.stdin.read()
    try:
        payload = json.loads(raw)
        if not isinstance(payload, dict):
            raise ValueError("payload is not an object")
        malformed = False
    except ValueError:
        payload, malformed = {}, True

    cwd = (find_string(payload, ("cwd",), depth=1) or root_arg or os.getcwd())
    stack = _stack.find_stack(cwd)
    if stack is None:
        return present_pass()          # repo-gated: a de-configured repo must not brick
    policy = _stack.db_write_mode(stack)
    if policy == _stack.MODE_OFF:
        return present_pass()          # explicit operator instruction, readable without a scanner

    if os.environ.get("TICKETWRIGHT_SHIM_FAULT") == "raise":
        raise RuntimeError("selftest fault injector")

    if malformed:
        if not ask_capable(protocol) and escape_granted(None, stack):
            # The token is the deny-only runtimes' manual ask tier; on an ask-capable runtime
            # the ask itself is the escalation, so the token is neither needed nor consumed.
            print("ticketwright hook_shim: one-shot token consumed — passing an UNREADABLE "
                  "hook input through on explicit human approval.", file=sys.stderr)
            return present_pass()
        msg = ("db_write_requires_approval is enforced here by ticketwright's hook shim, and the "
               "hook input could not be read — a guard that cannot read its input never guesses "
               "allow. Check the hook wiring (see the enforcement table in AGENTS.md). "
               + escape_text(stack.parent, prefix_readable=False))
        return present_gate(protocol, msg, policy)

    tool = tool_identity(payload)
    command = find_string(payload, ("command",), depth=3)
    if command is None:
        if tool is not None and not looks_shellish(tool):
            return present_pass()      # not a shell call: outside the guard's jurisdiction
        # A shell-like tool with no extractable command, or no tool identity at all: unreadable.
        if not ask_capable(protocol) and escape_granted(None, stack):
            print("ticketwright hook_shim: one-shot token consumed — passing an unreadable "
                  "shell payload through on explicit human approval.", file=sys.stderr)
            return present_pass()
        msg = ("db_write_requires_approval is enforced here by ticketwright's hook shim, and no "
               "shell command could be extracted from the hook payload — a guard that cannot "
               "read its input never guesses allow. Check the hook wiring (see the enforcement "
               "table in AGENTS.md). " + escape_text(stack.parent, prefix_readable=False))
        return present_gate(protocol, msg, policy)

    import sql_scan  # noqa: E402 — lazy, guard-only (module-level would couple the banners to it)
    decision = sql_scan.assess(command, cwd, stack, policy)
    kind = decision["kind"]
    if kind in ("silent", "none"):
        return present_pass()
    if kind == "allow_fastpath":
        # The shim only ever ADDS gating on a foreign runtime — it never emits an allow that
        # could outrank that runtime's own stricter static rules.
        return present_pass()

    # kind is "gate" or "wrong_target": on an ask-capable runtime, ask; on a deny-only runtime,
    # DENY-WITH-ESCAPE (the high_risk collapse, 3b — additive statements never reach here under
    # high_risk because the scanner already distinguishes them).
    if ask_capable(protocol):
        return present_gate(protocol, decision["detail"], policy)
    granted = escape_granted(command, stack)
    if granted:
        print(f"ticketwright hook_shim: {granted} — approved once: {decision['detail']}",
              file=sys.stderr)
        return present_pass()
    msg = (decision["detail"] + " This runtime has no ask tier, so the statement is DENIED "
           "instead (deny-with-escape). " + escape_text(stack.parent, prefix_readable=True))
    return present_gate(protocol, msg, policy)


def run_shell_guards(protocol: str, root_arg: str | None) -> int:
    """Both PreToolUse shell guards, in ONE invocation, from ONE read of stdin.

    Why this exists: a runtime's hooks config takes an ARRAY of entries, and whether every entry
    in that array is executed — or only the first — is undocumented for the runtimes the kit
    emits for. Emitting two entries would make each WIRED cell depend on that unverified
    assumption, which is precisely the overclaim the ENFORCEMENT/WIRED/GUIDANCE vocabulary exists
    to prevent. One entry that runs both guards removes the assumption instead of documenting it.

    The DB guard runs first (it gates the more immediately destructive action). If it EMITS a
    decision, that decision is the answer and the second guard does not run — a single hook
    invocation returns a single verdict, and the human resolves one thing at a time. A DB guard
    that merely notes a one-shot approval on stderr has emitted nothing, so the source-material
    guard still runs: approving a destructive statement is not approval to ship a transcript.
    """
    raw = sys.stdin.read()

    def with_stdin(fn):
        buf = io.StringIO()
        stdin, stdout = sys.stdin, sys.stdout
        sys.stdin, sys.stdout = io.StringIO(raw), buf
        try:
            rc = fn(protocol, root_arg)
        finally:
            sys.stdin, sys.stdout = stdin, stdout
        return rc, buf.getvalue()

    rc, out = with_stdin(run_guard)
    if out.strip() or rc != 0:
        sys.stdout.write(out)
        return rc
    rc, out = with_stdin(run_source_material_guard)
    sys.stdout.write(out)
    return rc


def run_source_material_guard(protocol: str, root_arg: str | None) -> int:
    """The source-material guard, presented in `protocol`.

    Same shape as run_guard: the classification is bin/scan_source_materials.py's, this only
    presents it. The Claude presenter is .claude/hooks/source_material_guard.py — read its
    docstring for the jurisdiction and the git-vs-copy asymmetry, which are decided there and
    mirrored here rather than re-derived.
    """
    hooks_dir = Path(__file__).resolve().parent.parent / ".claude" / "hooks"
    sys.path.insert(0, str(hooks_dir))
    import _stack  # noqa: E402  — the ONE policy reader, in-process, fail-safe to `on`
    import scan_source_materials as scan  # noqa: E402

    raw = sys.stdin.read()
    try:
        payload = json.loads(raw)
        if not isinstance(payload, dict):
            raise ValueError("payload is not an object")
    except ValueError:
        payload = {}

    command = (find_string(payload, ("command", "cmd", "script"), depth=3) or "").strip()
    if not command:
        return present_pass()

    staging = sm_git_staging(command)
    copying = bool(SM_COPY_RE.search(command)) and bool(SM_COPY_RECURSIVE_RE.search(command))
    if not (staging or copying):
        return present_pass()          # outside this guard's jurisdiction entirely

    cwd = (find_string(payload, ("cwd",), depth=1) or root_arg or os.getcwd())
    stack = _stack.find_stack(cwd)
    if stack is None:
        return present_pass()          # repo-gated
    if _stack.source_material_mode(stack) == _stack.SM_OFF:
        return present_pass()          # explicit operator instruction

    repo = stack.parent.parent.parent
    records = scan.scan(repo)
    flagged = scan.flagged(records)
    partial = scan.incomplete(records)
    if partial and not flagged:
        return present_gate(protocol, (
            f"ticketwright source_material_guard: the source-material scan did NOT cover the whole "
            f"tree ({partial[0]['reason']}), so it cannot certify that no raw transcript is "
            f"present. Gating rather than assuming clean."), "high_risk")
    if not flagged:
        return present_pass()

    if copying:
        why = ("A folder-wide docstore backup copies everything in the ticket directory, and "
               "`.gitignore` does not apply to `cp -r`. Remove the file from the folder, or "
               "approve this copy explicitly.")
    else:
        # Mirrors .claude/hooks/source_material_guard.py: every raw_suspect is asked about. The
        # guard does not predict git's ignore decision from the kit's SHIPPED template — an
        # install predating those patterns would stage a transcript in silence.
        why = ("Trim it to decisions and action items and rename it to the curated form "
               "`YYYY-MM-DD-<slug>-meeting.md`, move it under `source_materials/private/`, or "
               "approve this staging explicitly.")

    listing = "; ".join(f"{Path(r['file']).name} ({r['reason']})" for r in flagged[:4])
    if len(flagged) > 4:
        listing += f"; and {len(flagged) - 4} more"
    msg = (f"ticketwright source_material_guard: raw transcript material may be about to leave "
           f"the repo — {listing}. {why} (The classifier matches filenames and document shape, "
           f"never meaning — a gate against the bulk artifact, not a confidentiality review.)")

    if ask_capable(protocol):
        return present_gate(protocol, msg, "high_risk")
    # No ask tier: DENY, and say so. The remedy here is a file change the person makes once,
    # not a re-run, so there is deliberately no one-shot escape token as the DB guard has.
    return present_gate(protocol, msg + " This runtime has no ask tier, so the command is "
                                        "DENIED instead; make the change above and re-run.",
                        "high_risk")


def run_session(hook: str, root_arg: str | None) -> int:
    """SessionStart banners: run the Claude hook as a child, wrap its stdout in the
    hookSpecificOutput.additionalContext shape Codex CLI and Devin document. Always exit 0."""
    try:
        sys.stdin.read()  # a runtime may pipe an event payload; the banners don't need it
    except Exception:  # noqa: BLE001
        pass
    try:
        project, _ = kit_paths.resolve_project(root_arg)
        kit, _ = kit_paths.resolve_kit(project)
        if not kit:
            return 0
        child = Path(kit) / ".claude" / "hooks" / f"{hook}.py"
        env = dict(os.environ)
        env["CLAUDE_PROJECT_DIR"] = str(project)  # the hook's documented interface
        proc = subprocess.run(
            [sys.executable, str(child)],
            input=json.dumps({"hook_event_name": "SessionStart"}),
            capture_output=True, text=True, env=env, cwd=str(project), timeout=30,
        )
        text = proc.stdout.strip()
        if text:
            print(json.dumps({"hookSpecificOutput": {
                "hookEventName": "SessionStart",
                "additionalContext": text,
            }}))
    except Exception:  # noqa: BLE001 — a banner is not a safety gate; never block anything
        pass
    return 0


def run_regen(root_arg: str | None) -> int:
    """PostToolUse index regeneration: defensively extract the written file's path, forward it to
    the Claude hook in its own payload shape, with cwd preserved and CLAUDE_PROJECT_DIR set
    (gate-1 finding: the child resolves its root from exactly those two values). Always exit 0."""
    try:
        try:
            payload = json.loads(sys.stdin.read())
            if not isinstance(payload, dict):
                payload = {}
        except ValueError:
            payload = {}
        fp = find_string(payload, ("file_path", "filePath", "path"), depth=3)
        if not fp:
            return 0  # nothing written that we can see; freshness falls back to the --check gate
        cwd = find_string(payload, ("cwd",), depth=1) or root_arg or os.getcwd()
        project, _ = kit_paths.resolve_project(root_arg or cwd)
        kit, _ = kit_paths.resolve_kit(project)
        if not kit:
            return 0
        child = Path(kit) / ".claude" / "hooks" / "regenerate_ticket_index.py"
        env = dict(os.environ)
        env["CLAUDE_PROJECT_DIR"] = str(project)
        subprocess.run(
            [sys.executable, str(child)],
            input=json.dumps({"tool_name": "Write", "tool_input": {"file_path": fp},
                              "cwd": str(cwd)}),
            capture_output=True, text=True, env=env, cwd=str(project), timeout=60,
        )
    except Exception:  # noqa: BLE001 — index freshness degrades to the --check staleness gate
        pass
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(
        prog="hook_shim.py",
        description="Adapt a kit hook's stdin/stdout to a runtime's hook protocol.")
    ap.add_argument("--runtime", required=True)
    ap.add_argument("--hook", required=True,
                    choices=[GUARD, SM_GUARD, SHELL_GUARDS, *SESSION_HOOKS, REGEN])
    ap.add_argument("--root", help="project repo (default: the payload's cwd, then $PWD)")
    args = ap.parse_args(argv)

    kit, _ = kit_paths.resolve_kit(None)
    if not kit:
        print("hook_shim: cannot locate the ticketwright kit.", file=sys.stderr)
        return 2
    adapters = kit_paths.runtime_adapters(kit)
    entry = adapters.get(args.runtime)
    if not entry:
        print(f"hook_shim: unknown runtime '{args.runtime}' (see adapters/runtime/).",
              file=sys.stderr)
        return 2
    _, fm = entry
    protocol = fm.get("hook_protocol", "unknown")
    if protocol == "claude-json":
        print("hook_shim: refused — Claude Code runs the native hooks in .claude/hooks/; "
              "routing them through a shim could only change their failure mode.",
              file=sys.stderr)
        return 2
    if protocol not in ("codex-json", "cursor-json", "agy-json", "exit-code"):
        print(f"hook_shim: refused — {fm.get('tool', args.runtime)} declares "
              f"hook_protocol: {protocol}; there is no documented hook protocol to speak "
              f"(see adapters/runtime/ and the enforcement table in AGENTS.md).",
              file=sys.stderr)
        return 2

    if args.hook in SESSION_HOOKS:
        return run_session(args.hook, args.root)
    if args.hook == REGEN:
        return run_regen(args.root)
    if args.hook in (SM_GUARD, SHELL_GUARDS):
        try:
            runner = run_shell_guards if args.hook == SHELL_GUARDS else run_source_material_guard
            return runner(protocol, args.root)
        except Exception as e:  # noqa: BLE001 — same discipline as the DB guard below
            msg = (f"ticketwright's source-material guard hit an internal error "
                   f"({e.__class__.__name__}: {e}) and refuses to guess allow. Fix the kit "
                   f"install (bin/scan_source_materials.py + .claude/hooks/), or set "
                   f"`policies.source_material_guard: off` to disable it explicitly.")
            try:
                if ask_capable(protocol):
                    return present_gate(protocol, msg, "high_risk")
                print(msg, file=sys.stderr)
                print(msg)
                return 2
            except Exception:  # noqa: BLE001 — even the presenter failed; the contract holds
                return 2

    # The guard. Failure discipline (evidence-of-done): the ONLY exits are 0 and a deliberate 2 —
    # on Devin any other nonzero is logged and does NOT block, i.e. a crash would fail open.
    try:
        return run_guard(protocol, args.root)
    except Exception as e:  # noqa: BLE001 — map EVERY internal failure to a deliberate decision
        msg = (f"db_write_requires_approval is enforced here by ticketwright's hook shim, which "
               f"hit an internal error ({e.__class__.__name__}: {e}) and refuses to guess allow. "
               f"Fix the kit install (bin/ + .claude/hooks/), or set the policy to `off` to "
               f"disable the guard explicitly. " + escape_text(None, prefix_readable=False))
        try:
            if ask_capable(protocol):
                return present_gate(protocol, msg, "high_risk")
            print(msg, file=sys.stderr)
            print(msg)
            return 2
        except Exception:  # noqa: BLE001 — even the presenter failed; the contract still holds
            return 2


if __name__ == "__main__":
    raise SystemExit(main())
