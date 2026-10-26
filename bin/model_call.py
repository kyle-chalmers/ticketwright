#!/usr/bin/env python3
"""The one place a Ticketwright script runs a headless model.

Every script that spawns a model (enrich_ticket.py writes the curated index summary) shares this
module, so that WHICH command runs, how it is built, and how it is run cannot drift apart between
them. This file lives in bin/, the layer the architecture calls harness-neutral, so nothing here is
specific to one vendor's CLI.

  resolve_model_cmd(override)  -> (template, runtime_frontmatter)
  build_model_argv(template, model, prompt) -> (argv, prompt_on_stdin)
  run_model(argv, prompt, prompt_on_stdin, timeout=240) -> stdout text

Which model command runs is resolved in this order:

  1. the caller's `--model-cmd '<template>'`
  2. the detected runtime's `model_cmd:` frontmatter in `adapters/runtime/<name>.md`
  3. the built-in `claude -p` default

Step 3 is deliberately NOT gated on detection: a wrong runtime guess must never be the reason a model
call stops working. A runtime that IS detected and declares an empty `model_cmd` has no headless
command; that comes back as a template of None, and each caller says what to do instead.

The frontmatter dict is returned whole (flat key -> string, as kit_paths.read_frontmatter reads it),
so a caller can read the keys it cares about: `model_sandbox` (is the command restricted),
`model_default` (the model to use when none is named) and `model_fast` (a cheaper model for a
one-line job, declared only by a runtime whose template has a `{model}` slot).
"""
from __future__ import annotations

import os
import shlex
import subprocess
import sys
from pathlib import Path

# The historical command, kept as the floor so a runtime this module cannot identify behaves exactly
# as it always has.
DEFAULT_MODEL_CMD = "claude -p --model {model} {prompt}"
DEFAULT_MODEL = "sonnet"
# A model command is built as ARGV and never handed to a shell. The prompt can carry up to 24KB of a
# ticket README, which on most installs was fetched from a tracker, i.e. text someone outside this
# repo wrote. Interpolating that into a shell string would make a README with backticks or $(...) into
# executable code during an unattended /ship. These characters are refused in a template so nobody
# can reintroduce that by writing an adapter that looks shell-shaped.
SHELL_METACHARS = set(";|&<>$`\n")
# Only these may be argv[0] of a model command resolved FROM AN ADAPTER. Adapters live inside the repo
# on a vendored install, so without this an adapters/runtime/x.md added by a pull request runs any
# command during /ship (verified reproducible before this existed). --model-cmd is deliberately
# exempt: that is a human typing at their own terminal, not repo content.
ALLOWED_MODEL_BINARIES = frozenset({"claude", "codex", "agy", "devin", "opencode", "gemini"})


class ModelCallError(RuntimeError):
    """The model process could not be run, timed out, or exited non-zero.

    The message starts with the tool name and carries no caller context, so a caller can put its own
    prefix in front of it (a ticket id, say) and print it as is.
    """


def _runtime_model_cmd(caller: str) -> tuple[str | None, dict, str] | None:
    """(model_cmd, frontmatter, source) from the detected runtime's adapter, or None if there is none.

    None means the kit or the runtime's adapter could not be found, and the caller falls back to the
    built-in default. A runtime that is found but has no usable command returns a model_cmd of None
    WITH its frontmatter, so the caller can still read the keys that explain why.

    Imported lazily and defensively ON PURPOSE. This module is copied on its own into fixture repos
    and into vendored installs where kit_paths.py and adapters/ may not sit beside it, and a
    top-level import would turn that into a crash. Any miss returns None so the caller falls back to
    the historical default rather than failing.

    TRUST MODEL: read this before loosening anything. `ticketwright init` copies adapters/ INTO the
    target repo, so on a vendored install the project root IS a valid kit and adapters/runtime/*.md is
    project-controlled. "Resolve from the kit only" therefore does NOT isolate this from repo content,
    and an earlier version of this docstring wrongly claimed it did.

    What actually contains the risk is ALLOWED_MODEL_BINARIES. A markdown file reads as inert in code
    review, so a `model_cmd:` line is a uniquely easy place to hide an executable payload: a reviewer
    skims a .md diff far less carefully than a .py one. The allowlist means the worst a crafted adapter
    can do is pick a different MODEL CLI, not run `curl` or `rm`.
    """
    try:
        # Look beside this script first, then under an explicit $TICKETWRIGHT_KIT. Otherwise the
        # override is inert exactly when it matters, i.e. when this module was copied somewhere on its
        # own and the kit lives elsewhere.
        for cand in (Path(__file__).resolve().parent,
                     Path(os.environ.get("TICKETWRIGHT_KIT", "/nonexistent")).expanduser() / "bin"):
            if (cand / "kit_paths.py").is_file():
                sys.path.insert(0, str(cand))
                break
        import kit_paths
        kit, _ = kit_paths.resolve_kit()
        if not kit:
            return None
        runtime, _ = kit_paths.detect_runtime(kit)
        entry = kit_paths.runtime_adapters(kit).get(runtime)
        if not entry:
            return None
        fm = dict(entry[1])
        source = f"adapters/runtime/{runtime}.md"
        cmd = fm.get("model_cmd", "")
        if not cmd.strip():
            return None, fm, source
        try:
            argv0 = shlex.split(cmd)[0]
        except (ValueError, IndexError):
            argv0 = ""
        if Path(argv0).name not in ALLOWED_MODEL_BINARIES:
            print(f"{caller}: refusing model_cmd from adapters/runtime/{runtime}.md: "
                  f"'{argv0}' is not a known model CLI. Adapters ship inside the repo on a "
                  f"vendored install, so this allowlist is what stops a markdown file from "
                  f"running an arbitrary command. Use --model-cmd if you meant to run it.",
                  file=sys.stderr)
            return None, fm, f"{source} (refused)"
        return cmd, fm, source
    except Exception:
        return None


def resolve_model(override: str | None, caller: str = "model_call") -> tuple[str | None, dict, str]:
    """(template, runtime_frontmatter, source) for the model command to run.

    `source` names where the template came from: `--model-cmd`, `adapters/runtime/<name>.md` (with
    ` (refused)` when the allowlist turned its command away), or `built-in default`. A script prints
    it so a person can see which command is about to run. `caller` only prefixes the one refusal
    message this can print.

    The template is None when the runtime is known and has no headless command (or its command was
    refused). The frontmatter is {} for an override, because no runtime was consulted, and holds just
    the default model for the built-in default.
    """
    if override:
        return override, {}, "--model-cmd"
    found = _runtime_model_cmd(caller)
    if found is None:
        return DEFAULT_MODEL_CMD, {"model_default": DEFAULT_MODEL}, "built-in default"
    return found


def resolve_model_cmd(override: str | None, caller: str = "model_call") -> tuple[str | None, dict]:
    """(template, runtime_frontmatter): resolve_model without the source label.

    The order is the caller's `override` (a `--model-cmd`), then the detected runtime's adapter, then
    the built-in default. See the module docstring and resolve_model.
    """
    template, fm, _ = resolve_model(override, caller)
    return template, fm


def build_model_argv(template: str, model: str | None, prompt: str) -> tuple[list[str], bool]:
    """Turn a command template into argv. Returns (argv, prompt_goes_on_stdin).

    Substitution is per-element and literal: never str.format, because adapter frontmatter may
    legitimately contain other braces, and never a re-split after substituting, because that is how
    a prompt's own spaces would become argument boundaries.

    `{model}` resolves to the model the caller passes (a --model, else the adapter's model_default).
    With none, the element is dropped along with an immediately preceding flag, so `--model {model}`
    disappears cleanly and the tool applies its own default.
    """
    if model and model.startswith("-"):
        raise ValueError(f"model name may not start with '-' (got {model!r}), it would read as a flag")
    bad = SHELL_METACHARS & set(template)
    if bad:
        raise ValueError(
            "model command may not contain shell metacharacters (%s): it is run as argv, not via a "
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
        raise ValueError("model command is empty after substitution, nothing to run")
    return out, "{prompt}" not in template


def run_model(argv: list[str], prompt: str, prompt_on_stdin: bool, timeout: float = 240) -> str:
    """Run the model command and return its stdout, untouched. Never through a shell.

    `prompt` is written to the process's stdin only when `prompt_on_stdin` is true (the template had
    no `{prompt}` token); otherwise it is already inside `argv` and stdin is left as the caller's.
    Raises ModelCallError when the process cannot be started, runs past `timeout`, or exits non-zero.
    """
    tool = argv[0] if argv else "?"
    try:
        out = subprocess.run(
            argv,
            input=prompt if prompt_on_stdin else None,
            capture_output=True, text=True, timeout=timeout,
        )
    except (FileNotFoundError, OSError, subprocess.TimeoutExpired) as e:
        raise ModelCallError(f"{tool} failed ({e}).") from e
    if out.returncode != 0:
        raise ModelCallError(f"{tool} exited {out.returncode}: {out.stderr.strip()[:200]}")
    return out.stdout
