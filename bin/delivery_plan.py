#!/usr/bin/env python3
"""delivery_plan.py — audience/classification routing for the `chat` and `docstore` tool slots.

WHY THIS FILE EXISTS. A `.sql` file names its own warehouse target in a header comment, and that
works precisely because the SQL file IS the executable artifact. A chat message and a docstore
backup have no such file, so their declaration lives in a persisted DELIVERY PLAN —
`delivery-plan.yaml` at the ticket root, committed with the ticket. The schema is published in
adapters/README.md § "The delivery plan"; this CLI is what reads and routes on it.

THE ONE RULE: AUDIENCE AND CLASSIFICATION ARE DECLARATIONS, NEVER INFERENCES. Nothing here reads
prose, a channel name, a folder name or a label to decide who a message is for. When a slot holds
`targets:` and the plan declares nothing, routing HALTS (exit 9) naming the file and the configured
values. It never falls through to `default:`, and never to the first-listed target — that target may
be the external one, which is exactly how client data leaks.

Selection itself is `bin/effective_config.py`'s `select_unit()` — the same binary that merges the
three config tiers, never a second resolver — and `bin/_yamlite.py` stays the only YAML reader.

  delivery_plan.py --stack <f> --audit                        # config audit; verify_stack.sh fails on `error` rows
  delivery_plan.py --plan <f> --seam chat --json              # route from the declaration
  delivery_plan.py --plan <f> --seam chat --override <name>   # the explicit `--chat <target>` override
  delivery_plan.py --plan <f> --seam chat --check-draft <f>   # does the drafted text carry the routed list?
  delivery_plan.py --plan <f> --seam docstore --file <path>   # route ONE deliverable
  delivery_plan.py --plan <f> --seam docstore --record-delivered <path> --url <url>
  …any routing call also takes --expect-target <name> and       # preview==execution, mechanically:
     --expect-fingerprint <hex>                                  # the fingerprint pins the RESOLUTION

`--override` is CHAT ONLY: PROMPT 8 authorizes exactly one escape hatch, `--chat <target>`. A
docstore override would be a way to put a file in a store the ticket does not name, so a deliverable
that belongs elsewhere DECLARES it (a `deliverables:` row with its own `classification:`), which
stays with the ticket instead of living in one person's shell history.

`--expect-target` / `--expect-fingerprint` are what make an approved plan binding. /ship prints a
resolved plan (each routed line carries its `resolution_fingerprint`), a human authorizes THAT
resolution, and every later step passes both back: `--expect-target` catches a changed target name,
and the fingerprint catches everything a name check cannot — a stack.yaml edit that keeps `client`
but re-points its channel, its recipients, or its declared scope. Either mismatch refuses with the
routed fields nulled.

EXIT CODES: 0 ok · 2 usage · 3 plan file missing · 4 plan/config malformed (including a destination
or recipient carrying shell metacharacters — the tier-3 injection refusal, inherited from
effective_config, never re-derived) · 7 slot not configured (the one case a caller may degrade, the
way /ship already skips an absent chat/docstore) · 8 the declared value matches no configured
target, or an unknown `--override` · 9 the plan exists but declares nothing for this slot.
0/2/3/4/7/8 carry the same meanings as the resolver's published family; **9 is a delivery-plan
EXTENSION**, not part of that family — no declaration is a state only a persisted plan can be in.

A DECLARATION IS DEMANDED ONLY WHEN THE SLOT HOLDS `targets:`. A single mapping routes to itself
with `target: null` and needs no plan file at all, so a repo that never adopts targets ships exactly
as it does today. That scoping is the difference between a stricter rule and a regression.

ON EVERY NON-ZERO EXIT, `target` AND `destination` ARE NULL. A caller cannot pick a usable
destination out of a failed routing, whether or not it checks the exit code.

Stdlib only. Read-only except `--record-delivered`, which appends one row to the named plan file.
No Claude environment variable is required anywhere: `--root` (or `--plan`'s own location) is the
only context this needs.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import posixpath
import re
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

import effective_config as ec  # noqa: E402
from _yamlite import YamliteError, parse_file  # noqa: E402

SCHEMA_VERSION = 1
PLAN_NAME = "delivery-plan.yaml"

EXIT_OK, EXIT_USAGE, EXIT_NO_PLAN, EXIT_MALFORMED = 0, 2, 3, 4
EXIT_NO_SEAM, EXIT_NO_TARGET, EXIT_NO_DECLARATION = 7, 8, 9

# The routing key per slot: chat routes on WHO the message is for, docstore on WHAT the file is.
ROUTING_KEY = {"chat": "audience", "docstore": "classification"}
# Which adapter frontmatter key spells this slot's destination key. Adapters name their own key
# (Slack says `default_channel`, Teams says `channel`) — the `dev_key:` precedent, extended rather
# than duplicated, so no skill ever has to know which tool it is talking to.
DESTINATION_FRONTMATTER = {"chat": "channel_key", "docstore": "destination_key"}
SHARING_SCOPES = ("team", "org", "external")

# An adapter-supplied key NAME is executable input, not documentation (the wave-A lesson: a markdown
# file reads as inert in code review). It is validated before it is ever used as a lookup, and an
# invalid one HALTS rather than falling back to a guessed key — guessing between `channel` and
# `default_channel` would send to whichever the config happened to hold.
KEY_NAME_RE = re.compile(r"^[a-z][a-z0-9_]*$")


# ── helpers ────────────────────────────────────────────────────────────────────────────────────
def _err(code: str, message: str, configured: list[str] | None = None) -> dict:
    return {"code": code, "message": message, "configured": configured or []}


def _is_multi(seam: Any) -> bool:
    return isinstance(seam, dict) and isinstance(seam.get("targets"), dict)


def _unsafe(value: Any) -> bool:
    """The tier-3 injection refusal, applied to a routed value. Inherited, never re-derived."""
    return bool(value is not None and set(str(value)) & ec.SHELL_METACHARS)


def _str_list(value: Any) -> list[str] | None:
    if not isinstance(value, list) or not value:
        return None
    out = []
    for item in value:
        if not isinstance(item, (str, int, float)) or not str(item).strip():
            return None
        out.append(str(item).strip())
    return out


def destination_key(seam_name: str, adapter_rel: str | None, root: Path) -> tuple[str | None, str | None]:
    """(key, error). The adapter spells its own destination key; a bad one is a halt, not a guess."""
    fm_key = DESTINATION_FRONTMATTER[seam_name]
    key = ec.adapter_key(adapter_rel, root, fm_key)
    if not key:
        return None, (f"adapter `{adapter_rel or '?'}` declares no `{fm_key}:` frontmatter — a "
                      f"multi-target {seam_name} slot cannot know which key holds this tool's "
                      f"destination")
    if not KEY_NAME_RE.match(key):
        return None, (f"adapter `{adapter_rel}` declares `{fm_key}: {key}`, which is not a plain "
                      f"config key name — refusing to use it as a lookup")
    return key, None


def read_plan(path: Path) -> tuple[dict | None, dict | None]:
    """(plan, error). A missing file and a malformed one are different failures on purpose."""
    if not path.is_file():
        return None, _err("no_plan", f"no delivery plan at {path} — the declaration lives in "
                                     f"`{PLAN_NAME}` at the ticket root (adapters/README.md "
                                     f"§ The delivery plan)")
    try:
        data = parse_file(path)
    except YamliteError as exc:
        return None, _err("malformed", f"{path}: {exc}")
    if data is None:
        data = {}
    if not isinstance(data, dict):
        return None, _err("malformed", f"{path}: a delivery plan must be a mapping")
    # The published plan schema is versioned; a plan written against a different one may spell its
    # routing keys differently, and reading it with today's rules would route on a guess. An ABSENT
    # version is accepted (hand-written plans predate the template); a MISMATCH is malformed.
    version = data.get("schema_version")
    if version is not None and str(version).strip() != str(SCHEMA_VERSION):
        return None, _err("malformed", f"{path}: schema_version {version} is not supported "
                                       f"(this kit reads schema_version {SCHEMA_VERSION})")
    dl_err = _validate_deliverables(data, path)
    if dl_err:
        return None, dl_err
    return data, None


def _validate_deliverables(plan: dict, path: Path) -> dict | None:
    """The `deliverables:` block is ROUTING INPUT, so a malformed row is exit 4, never a shrug.

    The first version of this check accepted any row and used its `classification:` only when it
    was a non-empty string — which meant `classification: null`, `[]`, `""`, a misspelled key, or
    the chat key `audience:` written by mix-up all SILENTLY fell through to the plan-level value.
    A row someone wrote to keep one file internal would then ship that file to the client store
    with exit 0. A person who wrote a row gets that row honored or gets an error naming it —
    never a quiet fallthrough to a broader declaration.
    """
    if "deliverables" not in plan:
        return None
    block = plan.get("deliverables")
    if not isinstance(block, list):
        return _err("malformed", f"{path}: `deliverables:` must be a list of rows "
                                 f"(`- file: …` + optional `classification: …`), got "
                                 f"{type(block).__name__ if block is not None else 'null'}")
    seen_files: dict[str, int] = {}
    for i, row in enumerate(block, 1):
        where = f"{path}: deliverables row {i}"
        if not isinstance(row, dict):
            return _err("malformed", f"{where}: not a mapping")
        fname = row.get("file")
        if not isinstance(fname, str) or not fname.strip():
            return _err("malformed", f"{where}: `file:` must be a non-empty string")
        norm = _norm_rel(fname)
        if norm in seen_files:
            # Two rows for one file is ambiguity, and ambiguity never picks: first-match-wins would
            # let a later row someone added sit in the plan looking authoritative while the earlier
            # one silently routes.
            return _err("malformed", f"{where} ({fname}): duplicates row {seen_files[norm]} — two "
                                     f"rows name the same file (after path normalization), and "
                                     f"routing refuses to choose between them")
        seen_files[norm] = i
        for key in row:
            if key in ("file", "classification"):
                continue
            if key == "audience":
                return _err("malformed", f"{where} ({fname}): `audience:` routes CHAT and lives at "
                                         f"the plan's top level — a deliverables row routes "
                                         f"docstore; did you mean `classification:`?")
            return _err("malformed", f"{where} ({fname}): unknown key `{key}:` — a row carries "
                                     f"`file:` and optionally `classification:`, and an unknown "
                                     f"key here is a typo until proven otherwise")
        if "classification" in row:
            cls = row.get("classification")
            if not isinstance(cls, str) or not cls.strip():
                return _err("malformed", f"{where} ({fname}): `classification:` is present but is "
                                         f"not a non-empty string — a row that MEANS to split this "
                                         f"file out must say where it goes; refusing to fall "
                                         f"through to the plan-level classification")
    return None


def _norm_rel(path_str: str) -> str:
    """Normalize a deliverable path for matching: `./a/b`, `a//b` and `a/b` are one file.

    Matching is on the normalized RELATIVE path only — an exact-string match here would let a
    `./`-prefixed row silently miss its `--file` and degrade to the plan-level classification,
    which is the same fallthrough as P1 wearing a path prefix.
    """
    return posixpath.normpath(path_str.strip().replace("\\", "/")).lstrip("/")


def declared_value(plan: dict, seam_name: str, file_rel: str | None = None) -> str | None:
    """The DECLARED routing value for this slot, or None. Read verbatim — never normalized.

    A near-miss (`External`, `internal `) must fail the match and halt, exactly like a typo'd
    warehouse target name. Fuzzy-matching an audience is how a message reaches the wrong room.

    DOCSTORE IS PER DELIVERABLE. One ticket can hold a client-facing summary and an internal
    working file, so a `deliverables:` row may declare its own `classification:` for one file:

        deliverables:
          - file: final_deliverables/summary.pdf
            classification: client_delivery

    A row's own declaration wins for that file; the plan-level `classification:` is the declaration
    covering every other deliverable. Both are declarations a person wrote — neither is a fallback
    to a *target*, which is the thing that must never happen.
    """
    key = ROUTING_KEY[seam_name]
    if seam_name == "docstore" and file_rel:
        want = _norm_rel(file_rel)
        for row in plan.get("deliverables") or []:
            # Shapes are enforced by _validate_deliverables at load time; by here every row is a
            # mapping whose `file` is a non-empty string and whose `classification`, when present,
            # is one too — so a matching row either carries its own routing value or has none.
            if isinstance(row, dict) and _norm_rel(str(row.get("file") or "")) == want:
                own = row.get(key)
                if isinstance(own, str) and own.strip():
                    return own
    raw = plan.get(key)
    return raw if isinstance(raw, str) and raw.strip() else None


# ── the audit (enforcement runs from bin/verify_stack.sh) ──────────────────────────────────────
def audit(res: "ec.Resolution") -> list[tuple[str, str]]:
    """Config findings for multi-target chat/docstore slots: [(error|warn, message), …].

    EVERY RULE HERE BINDS ONLY WHEN `targets:` IS PRESENT. A single-mapping chat slot that omits
    `always_include` keeps validating — the shipped example configs are the regression test, and a
    new required key that breaks them would be a regression, not a stricter rule.
    """
    out: list[tuple[str, str]] = []
    for seam_name in ("chat", "docstore"):
        seam = res.seams.get(seam_name)
        if not _is_multi(seam):
            continue
        rkey = ROUTING_KEY[seam_name]
        targets = seam["targets"]

        # A routing key at slot level would be INHERITED by every target that omits its own — and a
        # routing key is the one value that must never be inherited: two targets answering to the
        # same audience makes selection ambiguous, and silently so.
        if rkey in seam:
            out.append(("error", f"{seam_name}: `{rkey}:` is declared at slot level under "
                                 f"`targets:` — each target must declare its own {rkey}, never "
                                 f"inherit one"))
        if seam_name == "chat" and "always_include" in seam:
            out.append(("warn", "chat: slot-level `always_include:` has no effect under `targets:` "
                                "(a list is never inherited) — declare it on each target"))

        seen_route: dict[str, str] = {}
        seen_dest: dict[tuple[str, str], str] = {}
        for tname, target in targets.items():
            label = f"{seam_name}[{tname}]"
            if not isinstance(target, dict):
                out.append(("error", f"{label}: not a mapping of config keys"))
                continue
            unit, sel_err = ec.select_unit(res.seams, seam_name, tname)
            if sel_err or unit is None:
                out.append(("error", f"{label}: {(sel_err or {}).get('message', 'unresolvable')}"))
                continue
            vals = unit["values"]

            # 1) the routing key, declared on the target ITSELF (`target.get`, not `vals.get`).
            declared = target.get(rkey)
            if not isinstance(declared, str) or not declared.strip():
                out.append(("error", f"{label}: no `{rkey}:` declared on this target — routing "
                                     f"reads a declaration and never infers one, so an "
                                     f"undeclared target is unreachable"))
            else:
                declared = declared.strip()
                if declared in seen_route:
                    out.append(("error", f"{label}: {rkey} `{declared}` is already declared by "
                                         f"{seam_name}[{seen_route[declared]}] — a duplicate makes "
                                         f"routing ambiguous"))
                else:
                    seen_route[declared] = tname

            # 2) the destination, via the key the adapter spells for itself, DECLARED ON THE TARGET.
            #    Slot-level `default_channel` / `default_mode` keep inheriting per the standard rule
            #    — but an inherited value must never be what a routed message goes to, or two
            #    audiences quietly share one room. So inheritance stays true of the resolved values
            #    while a routable target is required to name its own destination.
            dkey, dkey_err = destination_key(seam_name, vals.get("adapter"), res.root)
            dest = None
            if dkey_err:
                out.append(("error", f"{label}: {dkey_err}"))
            else:
                dest = target.get(dkey)
                # docstore composes `base_path` from a tier-3 mount; the TEAM-owned key is the
                # destination identity, so the audit stays machine-independent.
                if dest is not None and not isinstance(dest, str):
                    # `channel: []`, a mapping, an int, a bool — none of these is a place a message
                    # can go, and passing the raw value downstream as a "destination" is how junk
                    # config becomes a delivery attempt.
                    out.append(("error", f"{label}: `{dkey}` must be a non-empty string, got "
                                         f"{type(dest).__name__}"))
                elif dest is None or not dest.strip():
                    inherited = vals.get(dkey)
                    out.append(("error", f"{label}: no `{dkey}:` on this target"
                                         + (f" — the slot-level `{dkey}: {inherited}` is inherited "
                                            f"as a value but is not a routable destination; declare "
                                            f"this target's own" if inherited not in (None, "")
                                            else " — this target has no destination")))
                elif _unsafe(dest):
                    out.append(("error", f"{label}: `{dkey}` value carries shell metacharacters — "
                                         f"refusing to route to it"))
                else:
                    ident = (str(vals.get("tool") or "?"), str(dest))
                    if ident in seen_dest:
                        out.append(("error", f"{label}: routes to the same destination as "
                                             f"{seam_name}[{seen_dest[ident]}] (`{dest}`) — two "
                                             f"targets landing in one place is a separation that "
                                             f"does not exist"))
                    else:
                        seen_dest[ident] = tname

            if seam_name == "chat":
                # 3) always_include: ENFORCED, non-empty, and the target's OWN. This replaces a
                #    prose convention with a check; a prose requirement replacing an unenforced
                #    prose convention would change nothing.
                if "always_include" not in target:
                    out.append(("error", f"{label}: no `always_include:` — every chat target "
                                         f"declares its own stakeholder list (the never-solo-DM "
                                         f"rule); it is never inherited from another target"))
                else:
                    names = _str_list(target.get("always_include"))
                    if names is None:
                        out.append(("error", f"{label}: `always_include` must be a non-empty list "
                                             f"of names — an empty list is worse than an absent "
                                             f"key, because it reads as a considered choice"))
                    else:
                        bad = [n for n in names if _unsafe(n)]
                        if bad:
                            out.append(("error", f"{label}: recipient(s) carry shell "
                                                 f"metacharacters: {', '.join(bad)}"))
                # 3b) the sender, when this adapter declares one (`sender_key:` — the email
                #     adapters name `identity`, the shared mailbox mail goes out AS). Route time
                #     enforces the same rule; the audit just names it earlier. Inheritable on
                #     purpose (vals, not target): one shared identity serving two audiences is
                #     normal, unlike a shared destination.
                skey = ec.adapter_key(vals.get("adapter"), res.root, "sender_key")
                if skey is not None and not KEY_NAME_RE.match(skey):
                    out.append(("error", f"{label}: its adapter declares `sender_key: {skey}`, "
                                         f"which is not a plain config key name — refusing to "
                                         f"use it as a lookup"))
                elif skey:
                    sender = vals.get(skey)
                    if not isinstance(sender, str) or not sender.strip():
                        out.append(("error", f"{label}: its adapter declares `sender_key: {skey}` "
                                             f"but no `{skey}:` is set — mail must not go out as "
                                             f"whoever the transport happens to be authenticated "
                                             f"as"))
                    elif _unsafe(sender):
                        out.append(("error", f"{label}: the `{skey}` value carries shell "
                                             f"metacharacters — refusing to emit it as a sender"))
                # 3c) `bcc:` is a key the kit deliberately maps to NOTHING — a hidden recipient
                #     would make the delivered audience differ from what every reader sees, which
                #     is why the email adapters document a no-bcc position. But a key someone
                #     WROTE must not be ignored in silence: it reads as a considered choice that
                #     was never honored (the slot-level always_include principle). A warn, never
                #     an error — narrowing-only, and shipped configs keep validating.
                if "bcc" in target:
                    out.append(("warn", f"{label}: `bcc:` has no effect — the kit deliberately "
                                        f"maps no hidden recipients (the no-bcc position in the "
                                        f"email adapters); recipients belong in `always_include`, "
                                        f"where each is visible, validated, and printed on the "
                                        f"approval line"))
            else:
                # 4) docstore: the declared scope of the destination. The kit never inspects a real
                #    sharing ACL, so this value is what the /ship approval line shows a human — an
                #    undeclared scope makes that line unanswerable.
                scope = target.get("sharing_scope")
                if not isinstance(scope, str) or not scope.strip():
                    out.append(("error", f"{label}: no `sharing_scope:` — declare one of "
                                         f"{', '.join(SHARING_SCOPES)} (declared, never verified: "
                                         f"the kit checks the mount, never the folder's ACL)"))
                elif scope.strip() not in SHARING_SCOPES:
                    out.append(("error", f"{label}: sharing_scope `{scope}` is not one of "
                                         f"{', '.join(SHARING_SCOPES)}"))
                elif scope.strip() == "external" and tname == seam.get("default"):
                    # `default:` is STRUCTURAL — verify_stack.sh requires it and pre-multi-target
                    # readers display it; routing never reads it. But a reader that predates
                    # routing shows the default, so pointing it at the externally-shared store is
                    # the riskiest arrangement available. Warn, don't fail: it is a legal config.
                    out.append(("warn", f"{label}: the slot `default:` names the target whose "
                                        f"sharing_scope is `external` — routing never uses "
                                        f"`default:`, but every pre-routing reader displays it"))
    return out


# ── routing ────────────────────────────────────────────────────────────────────────────────────
def _blank(seam_name: str, declared: str | None) -> dict:
    """The shape every caller gets, with no target and no destination in it."""
    return {"schema": SCHEMA_VERSION, "seam": seam_name,
            "declared_key": ROUTING_KEY.get(seam_name), "declared": declared,
            "target": None, "selected_by": None, "label": None, "tool": None, "adapter": None,
            "destination": None, "destination_key": None, "recipients": None,
            "include_self": None, "mode": None, "sender": None, "sender_key": None,
            "sharing_scope": None,
            "configured": [], "unsafe": [], "warnings": [], "error": None,
            "resolution_fingerprint": None}


def route(res: "ec.Resolution", seam_name: str, declared: str | None,
          override: str | None = None, self_name: str | None = None) -> tuple[dict, dict | None]:
    """Route one slot from its DECLARED value. Returns (result, error).

    Precedence, and there is no fourth step: an explicit `--override` (the `--chat <target>` flag),
    else the plan's declaration matched EXACTLY against each target's own routing key. There is
    deliberately no "else the default" — for chat and docstore, `selected_by: default` is not
    audience resolution.
    """
    out = _blank(seam_name, declared)
    seam = res.seams.get(seam_name)
    if not isinstance(seam, dict):
        err = _err("no_such_seam", f"`{seam_name}` is not configured in this stack",
                   sorted(k for k, v in res.seams.items() if isinstance(v, dict)))
        out["error"] = err
        return out, err

    if not _is_multi(seam):
        # A single mapping routes to itself. The declaration is recorded but selects nothing, and
        # an explicit override has nothing to select — the same hard edge select_unit draws.
        if override is not None:
            err = _err("no_such_target", f"`{seam_name}` is a single mapping — no targets are "
                                         f"configured, so `{override}` cannot be selected")
            out["error"] = err
            return out, err
        unit, sel_err = ec.select_unit(res.seams, seam_name, None)
        if sel_err or unit is None:
            out["error"] = sel_err
            return out, sel_err
        return _fill(out, res, seam_name, unit, "single", self_name)

    targets = seam["targets"]
    names = sorted(t for t, v in targets.items() if isinstance(v, dict))
    rkey = ROUTING_KEY[seam_name]
    out["configured"] = [
        f"{t} ({rkey}: {targets[t].get(rkey)})" if isinstance(targets[t].get(rkey), str) else t
        for t in names
    ]

    if override is not None:
        unit, sel_err = ec.select_unit(res.seams, seam_name, override)
        if sel_err or unit is None:
            sel_err = sel_err or _err("no_such_target", f"`{override}` is unresolvable", names)
            sel_err.setdefault("configured", names)
            out["error"] = sel_err
            return out, sel_err
        filled, ferr = _fill(out, res, seam_name, unit, "override", self_name, targets.get(unit["target"]))
        if not ferr:
            # An override IS an explicit human choice, so it routes — but it leaves no record with
            # the ticket, and an unrecorded routing decision is not a finished phase. Say so rather
            # than let the plan file's silence read as agreement. When it CONTRADICTS a declaration,
            # say that louder: the approval line must show the human they are overriding the ticket.
            warn = filled.get("warnings") or []
            if declared is None:
                warn.append(f"routed by --override `{override}`; the delivery plan declares no "
                            f"`{rkey}:`, so this routing is not recorded with the ticket")
            elif declared != (targets.get(unit["target"]) or {}).get(rkey):
                warn.append(f"--override `{override}` CONTRADICTS the ticket's declared {rkey} "
                            f"`{declared}` — delivering somewhere the ticket does not record")
            filled["warnings"] = warn
        return filled, ferr

    if declared is None:
        err = _err("no_declaration",
                   f"`{seam_name}` has named targets but the delivery plan declares no `{rkey}:` — "
                   f"declare one in {PLAN_NAME} and re-run. Routing halts here on purpose: it is "
                   f"never inferred from prose, a channel name or a label, and never falls back to "
                   f"a listed target",
                   out["configured"])
        out["error"] = err
        return out, err

    matches = [t for t in names
               if isinstance(targets[t].get(rkey), str) and targets[t][rkey].strip() == declared]
    if len(matches) != 1:
        err = _err("no_such_target",
                   (f"no configured {seam_name} target declares {rkey} `{declared}`"
                    if not matches else
                    f"{rkey} `{declared}` is declared by more than one {seam_name} target "
                    f"({', '.join(matches)}) — fix the config; routing never picks one"),
                   out["configured"])
        out["error"] = err
        return out, err

    unit, sel_err = ec.select_unit(res.seams, seam_name, matches[0])
    if sel_err or unit is None:
        out["error"] = sel_err
        return out, sel_err
    return _fill(out, res, seam_name, unit, "declared", self_name, targets.get(unit["target"]))


def _fill(out: dict, res: "ec.Resolution", seam_name: str, unit: dict,
          selected_by: str, self_name: str | None, own: dict | None = None) -> tuple[dict, dict | None]:
    """`own` is the target's OWN mapping when this is a named target, else None.

    The rules the audit enforces are re-checked HERE, at the point of use, on purpose. The audit
    runs when someone runs `verify_stack.sh`; routing runs when a message is about to be sent. If
    the only enforcement were the audit, an unverified config would still deliver — with an
    inherited channel, or with no stakeholder list at all — and "they should have run verify" is not
    a safety property.
    """
    vals = unit["values"]
    out.update({"target": unit["target"], "selected_by": selected_by, "label": unit["label"],
                "tool": vals.get("tool"), "adapter": vals.get("adapter")})

    dkey, dkey_err = destination_key(seam_name, vals.get("adapter"), res.root)
    if dkey_err:
        # A single-mapping slot predates this frontmatter, and demanding it there would break every
        # shipped config. Only a ROUTED target must name its destination key mechanically.
        if selected_by == "single":
            dkey = None
        else:
            err = _err("malformed", dkey_err)
            return _fail(out, err)
    if dkey is None and selected_by == "single":
        out["warnings"] = out.get("warnings") or []
        out["warnings"].append(f"adapter `{vals.get('adapter')}` declares no "
                               f"`{DESTINATION_FRONTMATTER[seam_name]}:`, so this slot's destination "
                               f"cannot be resolved mechanically — add it to the adapter")
    # A NAMED target reads its OWN destination; an inherited one is a value, never a routing
    # destination (two audiences sharing one inherited channel is a separation that does not exist).
    dest = (own.get(dkey) if own is not None else vals.get(dkey)) if dkey else None
    if dest is not None and (not isinstance(dest, str) or not dest.strip()):
        # `channel: []`, a mapping, an int, `""` — not places a message can go. A named target
        # carrying one REFUSES (junk in the leak-relevant path is a halt); a single mapping
        # degrades to "no destination", which is what its plan line already renders honestly.
        if own is not None:
            err = _err("malformed", f"{unit['label']}: `{dkey}` must be a non-empty string, got "
                                    f"{type(dest).__name__} — refusing to emit it as a destination")
            return _fail(out, err)
        dest = None
    if dest is None and own is not None:
        err = _err("malformed", f"{unit['label']}: declares no `{dkey}:` of its own — a routed "
                                f"target never delivers to an inherited destination")
        return _fail(out, err)
    base_path = vals.get("base_path")
    if seam_name == "docstore" and isinstance(base_path, str) and base_path.strip():
        # Show the RESOLVED destination once the machine half is known — the mounted path for
        # gdrive/sharepoint (`{mount_root}/{drive_folder}`), the prefixed remote for rclone
        # (`{remote}:{remote_path}`). Both are composed by effective_config._compose_paths, and
        # routing the composed value is what puts the tier-3 half inside `resolution_fingerprint`
        # and inside the `_unsafe` check below: re-pointing a personal alias after an approval then
        # refuses instead of silently redirecting a delivery.
        # Scoped to `docstore` on purpose, NOT "any seam with a base_path": chat shares this code
        # path, and a stray `base_path` there must never be able to override a channel.
        # Only a non-empty STRING may replace the already-type-checked destination key; a
        # junk-typed base_path keeps the checked value rather than smuggling an unchecked one past
        # the gate. (_unsafe below still runs on whichever value ends up here.)
        dest = base_path
    if _unsafe(dest):
        out["unsafe"] = [dkey or "destination"]
        err = _err("malformed", f"{unit['label']}: the `{dkey}` value carries shell "
                                f"metacharacters — refusing to emit it as a destination")
        return _fail(out, err)
    out["destination"], out["destination_key"] = dest, dkey

    if seam_name == "chat":
        names = _str_list(vals.get("always_include")) or []
        if own is not None and not _str_list(own.get("always_include")):
            # The never-solo-DM list is a precondition of sending, not a lint. A routed target
            # without one does not deliver — refusing here is what makes the rule bind even on a
            # config nobody verified.
            err = _err("malformed", f"{unit['label']}: declares no non-empty `always_include:` — "
                                    f"refusing to route a message with no stakeholder list")
            return _fail(out, err)
        if self_name and str(vals.get("include_self")).lower() in ("true", "1"):
            if self_name not in names:
                names = names + [self_name]
        bad = [n for n in names if _unsafe(n)]
        if bad:
            out["unsafe"] = bad
            err = _err("malformed", f"{unit['label']}: recipient(s) carry shell metacharacters: "
                                    f"{', '.join(bad)}")
            return _fail(out, err)
        out["recipients"] = names
        out["include_self"] = bool(str(vals.get("include_self")).lower() in ("true", "1"))
        out["mode"] = str(vals.get("default_mode") or "draft")
        # The SENDER, when this adapter declares one (`sender_key:` frontmatter — the email
        # adapters name `identity`, the shared mailbox mail goes out AS). For a medium where the
        # sender is a first-class header, WHO a message is from is part of what the human
        # authorizes, so it is surfaced on the plan line and pinned by the fingerprint below — a
        # post-approval config edit swapping one shared mailbox for another must refuse, exactly
        # like a moved channel. Read from the RESOLVED values (vals, not own) on purpose: one
        # shared identity serving two audiences is normal, unlike a shared destination.
        skey = ec.adapter_key(vals.get("adapter"), res.root, "sender_key")
        if skey is not None and not KEY_NAME_RE.match(skey):
            err = _err("malformed", f"{unit['label']}: its adapter declares `sender_key: {skey}`, "
                                    f"which is not a plain config key name — refusing to use it "
                                    f"as a lookup")
            return _fail(out, err)
        if skey:
            sender = vals.get(skey)
            if not isinstance(sender, str) or not sender.strip():
                if own is not None:
                    # A routed target with no declared sender would go out as whoever the
                    # transport happens to be authenticated as — a silent wrong-sender, refused
                    # the same way a missing destination is.
                    err = _err("malformed", f"{unit['label']}: its adapter declares `sender_key: "
                                            f"{skey}` but no `{skey}:` value resolves — refusing "
                                            f"to route a message whose sending identity is "
                                            f"undeclared")
                    return _fail(out, err)
                out["warnings"] = out.get("warnings") or []
                out["warnings"].append(f"adapter declares `sender_key: {skey}` but `{skey}:` is "
                                       f"unset — the sender cannot be shown on the plan line; "
                                       f"add it to the seam config")
            elif _unsafe(sender):
                out["unsafe"] = [skey]
                err = _err("malformed", f"{unit['label']}: the `{skey}` value carries shell "
                                        f"metacharacters — refusing to emit it as a sender")
                return _fail(out, err)
            else:
                out["sender"], out["sender_key"] = sender.strip(), skey
    else:
        scope = vals.get("sharing_scope")
        if own is not None:
            # Route-time parity with the audit: the scope is what the /ship approval line shows a
            # human, so a routed target without one (or with one outside the vocabulary) does not
            # deliver — even on a config nobody ran verify_stack.sh against.
            own_scope = own.get("sharing_scope")
            if not isinstance(own_scope, str) or own_scope.strip() not in SHARING_SCOPES:
                err = _err("malformed", f"{unit['label']}: declares no valid `sharing_scope:` of "
                                        f"its own (one of {', '.join(SHARING_SCOPES)}) — refusing "
                                        f"to route a deliverable to a store whose declared scope "
                                        f"a human cannot authorize")
                return _fail(out, err)
        out["sharing_scope"] = str(scope).strip() if isinstance(scope, str) and scope.strip() else None
    out["resolution_fingerprint"] = _fingerprint(out)
    return out, None


def _fingerprint(out: dict) -> str:
    """A short digest of WHAT WAS RESOLVED — target, tool, destination, recipients, sender, scope, mode.

    `--expect-target` pins only the target's NAME, and a name is not a resolution: editing
    stack.yaml between the approval and the delivery can keep the name while silently changing the
    channel, the recipient list, or the declared scope. The approval gate therefore shows this
    fingerprint, and `--expect-fingerprint` refuses when ANY routed fact moved. Computed over the
    emitted values (so the same flags — `--self` included — must be passed back, which /ship does).
    The basis includes the adapter and the destination key too: a swapped adapter file with the
    same visible destination is still a different executor of the delivery.
    """
    basis = {k: out.get(k) for k in ("seam", "target", "tool", "adapter", "destination",
                                     "destination_key", "recipients", "include_self",
                                     "sender", "sender_key", "sharing_scope", "mode")}
    return hashlib.sha256(json.dumps(basis, sort_keys=True, default=str)
                          .encode("utf-8")).hexdigest()[:12]


def _fail(out: dict, err: dict) -> tuple[dict, dict]:
    """Blank the routed fields. No caller can read a destination out of a failed routing."""
    out.update({"target": None, "selected_by": None, "label": None, "destination": None,
                "destination_key": None, "recipients": None, "sender": None, "sender_key": None,
                "sharing_scope": None, "resolution_fingerprint": None, "error": err})
    return out, err


# ── the draft rail ─────────────────────────────────────────────────────────────────────────────
def missing_recipients(text: str, recipients: list[str]) -> list[str]:
    """Which routed recipients the drafted body does NOT name.

    A presence grep for the token `always_include` proves nothing about a message. This reads the
    DRAFT ITSELF and reports the names it fails to carry. A recipient matches when its name appears
    in the body (case-insensitively, `@` ignored) — the adapters already require the routed list to
    be named in the message. What this CANNOT see is what the chat API finally delivers.
    """
    hay = text.lower()
    return [r for r in recipients if r.lstrip("@").lower() not in hay]


# ── recording a delivery ───────────────────────────────────────────────────────────────────────
def record_delivered(plan_path: Path, rel_file: str, target: str | None, url: str) -> str | None:
    """Append one `delivered:` row. Returns an error message, or None on success.

    The row records the docstore target the file ACTUALLY went to, so `link_for` is called against
    the same store as `backup`. The write is verified by re-parsing: `delivered:` must be the last
    block in the plan for an append to land inside it, so a plan that does not satisfy that is
    reverted and reported rather than silently mangled.
    """
    for label, value in (("file", rel_file), ("url", url), ("target", target or "")):
        if "\n" in value or "\r" in value or '"' in value:
            return f"refusing to record a {label} containing a newline or a double quote"
    plan, err = read_plan(plan_path)
    if err:
        return err["message"]
    original = plan_path.read_text(encoding="utf-8")
    body = original if original.endswith("\n") else original + "\n"
    row = (f'  - file: "{rel_file}"\n'
           f'    docstore_target: {target if target else "null"}\n'
           f'    url: "{url}"\n')
    addition = row if isinstance(plan.get("delivered"), list) else "delivered:\n" + row
    plan_path.write_text(body + addition, encoding="utf-8")
    check, cerr = read_plan(plan_path)
    rows = (check or {}).get("delivered")
    if cerr or not isinstance(rows, list) or not rows or not isinstance(rows[-1], dict) \
            or rows[-1].get("file") != rel_file or str(rows[-1].get("docstore_target") or "") != (target or ""):
        plan_path.write_text(original, encoding="utf-8")
        return (f"could not append a delivered row to {plan_path} — `delivered:` must be the last "
                f"block in the plan; nothing was written")
    return None


# ── CLI ────────────────────────────────────────────────────────────────────────────────────────
def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        prog="delivery_plan.py",
        description="Route the chat/docstore tool slots from a ticket's declared delivery plan.",
        epilog="Exit codes: 0 ok, 2 usage, 3 plan missing, 4 malformed, 7 slot not configured, "
               "8 declared value matches no target, 9 nothing declared for this slot.")
    ap.add_argument("--root", default=None, help="repo root (default: $CLAUDE_PROJECT_DIR, else cwd)")
    ap.add_argument("--stack", default=None, help="explicit tier-1 stack.yaml path")
    ap.add_argument("--plan", default=None, help=f"path to a ticket's {PLAN_NAME}")
    ap.add_argument("--ticket", default=None, help=f"a ticket directory holding {PLAN_NAME}")
    ap.add_argument("--seam", default=None, choices=sorted(ROUTING_KEY),
                    help="which tool slot to route (chat | docstore)")
    ap.add_argument("--override", default=None, metavar="TARGET",
                    help="CHAT ONLY: route to this target explicitly (the `--chat <target>` "
                         "override); an unknown name is a hard error, never a fallback")
    ap.add_argument("--expect-target", default=None, metavar="TARGET",
                    help="refuse unless routing still resolves to this target NAME — the "
                         "human-readable half of the approval pin")
    ap.add_argument("--expect-fingerprint", default=None, metavar="HEX",
                    help="refuse unless the resolution_fingerprint still matches — pins the WHOLE "
                         "resolution (target, tool, destination, recipients, sender, scope, mode), so a "
                         "stack.yaml or plan edit between approval and delivery halts instead of "
                         "silently changing where or to whom this delivers")
    ap.add_argument("--file", dest="file_rel", default=None, metavar="PATH",
                    help="with --seam docstore: the deliverable being routed, so a per-file "
                         "`classification:` in the plan's `deliverables:` applies")
    ap.add_argument("--self", dest="self_name", default=None, metavar="NAME",
                    help="the shipper, added to the recipients when the target sets include_self")
    ap.add_argument("--audit", action="store_true",
                    help="audit multi-target chat/docstore config; one `level<US>message` row each")
    ap.add_argument("--check-draft", default=None, metavar="FILE",
                    help="verify a drafted message names every routed recipient")
    ap.add_argument("--record-delivered", default=None, metavar="PATH",
                    help="append a delivered row naming the docstore target actually used")
    ap.add_argument("--url", default=None, help="with --record-delivered: the shareable URL")
    ap.add_argument("--json", action="store_true", help="emit the routed plan as JSON (the default)")
    ap.add_argument("--quiet", action="store_true", help="suppress the human-readable error line")
    args = ap.parse_args(argv)

    root = args.root or os.environ.get("CLAUDE_PROJECT_DIR")
    if not root:
        if args.stack:
            root = str(Path(args.stack).resolve().parent.parent.parent)
        elif args.plan or args.ticket:
            # A ticket lives at <root>/tickets/<owner>/<id>, so walk up to the repo that holds it.
            start = Path(args.plan).resolve().parent if args.plan else Path(args.ticket).resolve()
            root = str(next((p for p in [start, *start.parents]
                             if (p / ".claude" / "config" / "stack.yaml").is_file()), Path.cwd()))
        else:
            root = os.getcwd()
    res = ec.resolve(root, None, args.stack)

    if args.audit:
        if args.seam or args.plan or args.ticket or args.check_draft or args.record_delivered:
            ap.error("--audit is its own mode — combine it only with --root/--stack/--quiet")
        rc = EXIT_OK
        for level, message in audit(res):
            print(f"{level}{message}")
            if level == "error":
                rc = EXIT_MALFORMED
        return rc

    if not args.seam:
        ap.error("--seam chat|docstore is required (or use --audit)")
    if args.override is not None and not args.override.strip():
        ap.error("--override needs a non-empty target name")
    if args.override is not None and args.seam != "chat":
        # PROMPT 8 authorizes exactly one override, `--chat <target>`. A docstore override would be
        # a way to put a file in a store the ticket's classification does not name — the disclosure
        # this whole flow exists to prevent. Where a file genuinely belongs elsewhere, declare it:
        # a `deliverables:` row carries its own classification, and that stays with the ticket.
        ap.error("--override is chat-only; declare a docstore target per deliverable in the plan "
                 "(`deliverables:` → `classification:`) instead of overriding it")
    if args.expect_target is not None and not args.expect_target.strip():
        ap.error("--expect-target needs a non-empty target name")
    if args.expect_fingerprint is not None and not args.expect_fingerprint.strip():
        ap.error("--expect-fingerprint needs a value (the plan line prints it)")
    if args.file_rel is not None and args.seam != "docstore":
        # Silently ignoring a flag is its own small dishonesty: --file selects a per-deliverable
        # classification, which only docstore has.
        ap.error("--file applies to --seam docstore (per-deliverable classification)")
    if args.record_delivered is not None and not args.url:
        ap.error("--record-delivered needs --url")
    if args.check_draft and args.record_delivered:
        ap.error("--check-draft and --record-delivered are separate modes")

    plan_path = Path(args.plan) if args.plan else (
        Path(args.ticket) / PLAN_NAME if args.ticket else Path(root) / PLAN_NAME)
    plan, perr = read_plan(plan_path)

    # A slot that is not configured at all is reported BEFORE the plan is demanded: a repo with no
    # chat slot must not be told to write a delivery plan it has no use for.
    seam = res.seams.get(args.seam)
    if not isinstance(seam, dict):
        out = _blank(args.seam, None)
        out["error"] = _err("no_such_seam", f"`{args.seam}` is not configured in this stack",
                            sorted(k for k, v in res.seams.items() if isinstance(v, dict)))
        return _emit(out, EXIT_NO_SEAM, args.quiet)

    # The plan is DEMANDED only by a multi-target slot (routing has nothing else to read) and by
    # --record-delivered (there is no file to append to). A single-mapping slot keeps working with
    # no plan at all, which is what stops this from breaking every repo that never adopts targets.
    # An ABSENT plan is the only excusable state, though: a plan that EXISTS but is malformed is a
    # broken committed record and reports exit 4 on every slot shape — "single mapping" excuses a
    # missing declaration, not a file nobody can read.
    if perr and (perr["code"] != "no_plan" or _is_multi(seam) or args.record_delivered):
        out = _blank(args.seam, None)
        out["error"] = perr
        return _emit(out, EXIT_NO_PLAN if perr["code"] == "no_plan" else EXIT_MALFORMED, args.quiet)
    # --record-delivered routes the FILE being recorded, so a per-deliverable classification is
    # what selects the store that file's link is minted from.
    file_rel = args.file_rel or args.record_delivered
    declared = declared_value(plan or {}, args.seam, file_rel)

    out, err = route(res, args.seam, declared, args.override, args.self_name)
    # `single` is the sentinel /ship already renders for a single mapping's null target (#38's
    # convention), so passing that plan line back must MATCH rather than look like a changed target.
    actual_target = out.get("target") or "single"
    if not err and args.expect_target is not None and actual_target != args.expect_target:
        # The approval gate authorized a specific target. If re-resolving now yields a different
        # one, the plan changed between the preview and this step — that is the exact drift a
        # human-authorized plan is supposed to make impossible, so it stops here.
        err = _err("target_changed",
                   f"routing now resolves to `{actual_target}`, not the approved "
                   f"`{args.expect_target}` — the delivery plan changed after it was approved; "
                   f"re-print the plan and get it authorized again")
        out, err = _fail(out, err)
    if (not err and args.expect_fingerprint is not None
            and out.get("resolution_fingerprint") != args.expect_fingerprint.strip()):
        # The name may match while the resolution moved — a stack.yaml edit can keep `client` and
        # re-point its channel or its recipients. The fingerprint is what the human approved.
        err = _err("target_changed",
                   f"the resolution changed after approval (fingerprint "
                   f"{out.get('resolution_fingerprint')}, approved {args.expect_fingerprint.strip()})"
                   f" — the destination, recipients, sender, scope or mode moved even though the target "
                   f"name may not have; re-print the plan and get it authorized again")
        out, err = _fail(out, err)
    if err:
        code = {"no_such_seam": EXIT_NO_SEAM, "no_declaration": EXIT_NO_DECLARATION,
                "malformed": EXIT_MALFORMED, "target_changed": EXIT_NO_TARGET,
                "no_plan": EXIT_NO_PLAN}.get(err.get("code"), EXIT_NO_TARGET)
        return _emit(out, code, args.quiet)

    if args.check_draft:
        draft = Path(args.check_draft)
        if not draft.is_file():
            out["error"] = _err("no_plan", f"no draft at {draft}")
            return _emit(out, EXIT_NO_PLAN, args.quiet)
        missing = missing_recipients(draft.read_text(encoding="utf-8"), out["recipients"] or [])
        out["missing_recipients"] = missing
        if missing:
            out["error"] = _err("draft_missing_recipients",
                                f"the drafted message does not name: {', '.join(missing)} — "
                                f"{out['label']} always includes {', '.join(out['recipients'])}")
            return _emit(out, EXIT_MALFORMED, args.quiet)

    if args.record_delivered:
        rerr = record_delivered(plan_path, args.record_delivered, out["target"], args.url)
        if rerr:
            out["error"] = _err("malformed", rerr)
            return _emit(out, EXIT_MALFORMED, args.quiet)
        out["recorded"] = {"file": args.record_delivered, "docstore_target": out["target"],
                           "url": args.url}

    return _emit(out, EXIT_OK, args.quiet)


def _emit(out: dict, code: int, quiet: bool) -> int:
    print(json.dumps(out, indent=2, default=str))
    if code != EXIT_OK and not quiet:
        err = out.get("error") or {}
        hint = ("  configured: " + ", ".join(err.get("configured") or out.get("configured") or [])
                if (err.get("configured") or out.get("configured")) else "")
        print(f"delivery_plan: {err.get('code', 'error')}: {err.get('message', '')}{hint}",
              file=sys.stderr)
    return code


if __name__ == "__main__":
    sys.exit(main())
