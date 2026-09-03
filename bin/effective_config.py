#!/usr/bin/env python3
"""effective_config.py — the single authority on "what is my config", merging all three tiers.

`/setup` writes `.claude/config/stack.yaml` by detecting the machine of whoever runs it — but that
file is COMMITTED and SHARED, so machine-local identifiers leak into a team artifact. Fixing the
leak alone just moves those values somewhere equally wrong, so the model and the leak are fixed
together.

THE THREE TIERS (later wins):
  1 TEAM, committed      `.claude/config/stack.yaml`
      which warehouse/catalog/schema, policies, ticket conventions.
  2 PERSON, portable     `${XDG_CONFIG_HOME:-$HOME/.config}/ticketwright/people/<id>.yaml`  (defaults)
                    then `people/<id>.yaml` (in-repo, committed) — which OVERRIDES the cross-repo
                    copy KEY BY KEY, not whole-file. Two homes with a stated winner, not two homes.
  3 PERSON, machine      `.claude/config/connections.local.yaml`  (gitignored)
      named connection/profile, local mount root, and the structural `person:` key.

THE SCOPE RULE, ENFORCED IN CODE. Tier 3 selects CREDENTIALS AND LOCAL PATHS. It may never change
LOGICAL DATA SELECTION — catalog, schema, database, warehouse_id, target, transport. Two teammates
must never silently read different data. Which keys are personal is declared PER ADAPTER via
`user_keys:` frontmatter, never hardcoded in a skill.

The merge is an ALLOWLIST over PATHS, not over bare key names:
  - `seams.<seam>.targets.<existing-target>.<key>`  where <key> is in that target's adapter
    `user_keys:`. `targets` must stay a legal path SEGMENT — the shipped multi-warehouse example
    puts Databricks' machine-local `profile` at exactly this path — while never being a settable
    value: creating, deleting or renaming a target is a prohibited override.
  - `seams.<seam>.<key>` on a SINGLE-MAPPING seam only. A multi-target seam has no `tool:`/`adapter:`
    of its own, so "the resolved adapter's user_keys" would be undefined for a seam-level key.
  - the structural tier-3 keys, and the tier-2 person block.
Anything else is REJECTED, not ignored.

`policies:` IS NOT MERGEABLE AT ANY TIER. Tier 3 is gitignored and unreviewed: if it could set
`db_write_requires_approval: off` or `hard_halt_before_external_posts: false`, a per-machine file
would silently disable the kit's safety gates with nothing in code review to catch it. Rejecting is
not the same as ignoring — ignoring would let someone believe they had turned a gate off.

WHO THE OWNER IS, AND HOW THAT WAS DECIDED. `owner` / `owner_source` answer both in one place, so
no skill has to re-derive the rule from `person` + `project.assignee_dir` and get it wrong:
  resolved                the person `bin/whoami.py` resolved (or an explicit --person).
  unbound                 people/<id>.yaml files EXIST but nobody resolved (a miss, an ambiguity,
                          or an identity-free placeholder). `owner` is null — filing this person's
                          work under `project.assignee_dir` would land it in a COLLEAGUE'S folder,
                          which is the failure mode nobody notices. Callers halt and bind first.
  assignee_dir_fallback   no people map at all: `project.assignee_dir`, the documented last resort
                          for repos that predate owner routing.
  none                    no people map and no `assignee_dir` — nothing to file under.

NOT A HOOK HELPER — a public CLI. No Claude environment variable is required anywhere.

  effective_config.py --root <repo> --json
  effective_config.py --root <repo> --key seams.warehouse.cli
  effective_config.py --root <repo> --verify-plan     # one JSON object per seam/target unit
  effective_config.py --root <repo> --viewer-plan     # the resolved viewer config
  effective_config.py --root <repo> --seam <name> [--target <name>]   # select ONE unit

TARGET SELECTION lives here, in the same binary that merges the tiers — never a second one (two
binaries would mean two YAML parsers, two --root conventions, and two answers to "which warehouse
am I on"). `--seam` alone resolves the seam's `default:` target (or the single mapping); `--target`
names one explicitly. An unresolvable NAME is a hard error naming what is configured — never a
fallback to another target, because falling back is precisely the wrong-warehouse (and, for chat,
the wrong-audience) failure. Contract: adapters/README.md § "Selecting a target from config".

EXIT CODES: 0 ok · 2 usage · 3 missing · 4 malformed · 5 stale · 6 prohibited override ·
7 seam not configured · 8 target unresolvable (unknown name; `targets:` with a missing or invalid
`default:`; an explicit --target on a single mapping).
These are the CLI SURFACE ONLY. The library entry point `resolve()` never raises and never exits —
two of its callers are hooks that must fail open, and `build_ticket_index.load_config()` must keep
returning defaults for an absent file.

Stdlib only. Read-only: no network, no writes, no credentials.
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

from _yamlite import YamliteError, config_trace, parse_file, scalar_str  # noqa: E402

SCHEMA_VERSION = 1

STACK_REL = ".claude/config/stack.yaml"
LOCAL_REL = ".claude/config/connections.local.yaml"

EXIT_OK, EXIT_USAGE, EXIT_MISSING, EXIT_MALFORMED, EXIT_STALE, EXIT_PROHIBITED = 0, 2, 3, 4, 5, 6
EXIT_NO_SEAM, EXIT_NO_TARGET = 7, 8

TIER_TEAM, TIER_PERSON, TIER_MACHINE, TIER_INHERITED = "team", "person", "machine", "inherited"

# How the owner of new work was decided (see the module docstring). Named constants because the
# strings are a CONTRACT: skills branch on them, and `unbound` is the one that must halt a caller.
OWNER_RESOLVED, OWNER_UNBOUND = "resolved", "unbound"
OWNER_FALLBACK, OWNER_NONE = "assignee_dir_fallback", "none"

# Structural keys the RESOLVER owns, not any adapter. Carved out of user_keys validation
# explicitly — without this, validation rejects every valid local file for declaring who you are.
STRUCTURAL_KEYS = {"person", "schema_version", "mode", "stack_fingerprint"}

# Tier-2 person keys. Validated against their own schema rather than the seam allowlist: they are
# not seam config at all and have no adapter to declare them.
PERSON_KEYS = {"display_name", "tracker_handle", "identities", "voice", "viewer"}

# Keys NO adapter may declare in `user_keys:`. Each either selects data or wires the seam itself.
# `cli` is here deliberately: it is what db_write_guard gates on, and letting one teammate's
# gitignored file narrow the set of commands that get gated is a safety hole, not a preference.
# The legacy `dev_key:` spellings are here too — they are dev-TARGET selection under another name.
RESERVED_SEAM_KEYS = {
    "tool", "adapter", "transport", "default", "targets", "target", "cli", "mcp",
    "catalog", "schema", "database", "dataset", "project", "warehouse_id",
    "conn", "host", "server", "site", "workgroup_name", "cluster_identifier",
    "dev_target", "dev_db", "dev_catalog", "dev_schema", "dev_dataset",
    "default_branch", "default_channel", "default_mode", "always_include", "include_self",
    "repo", "org", "team_id", "board_id", "workspace_gid",
    # Delivery routing. `audience` and `classification` SELECT a target, `channel`/`drive_folder`
    # ARE the destination, and `sharing_scope` is what the human authorizes at the /ship gate. A
    # gitignored, unreviewed per-machine file must never be able to move a message to another
    # audience or a client file to another store — the same reasoning that reserves `cli`.
    "audience", "classification", "sharing_scope", "channel", "drive_folder",
    # `remote_path` is drive_folder's twin for the rclone docstore (the team-owned half of
    # "{remote}:{remote_path}"), and `base_path` is the COMPOSED destination both docstore shapes
    # route and fingerprint on. Neither may come from a gitignored file: a tier-3 override of
    # either silently re-points a delivery, which is the same hole `drive_folder` closes.
    "remote_path", "base_path",
}
# Whole blocks no overlay may contribute, at any tier.
RESERVED_BLOCKS = {"policies", "project"}


class ConfigError:
    __slots__ = ("code", "path", "message", "source")

    def __init__(self, code: str, path: str, message: str, source: str = "") -> None:
        self.code, self.path, self.message, self.source = code, path, message, source

    def as_dict(self) -> dict:
        return {"code": self.code, "path": self.path, "message": self.message, "source": self.source}


def _exit_code_for(errors: list[ConfigError]) -> int:
    order = {"missing": EXIT_MISSING, "malformed": EXIT_MALFORMED,
             "stale": EXIT_STALE, "prohibited_override": EXIT_PROHIBITED}
    codes = [order[e.code] for e in errors if e.code in order]
    return max(codes) if codes else EXIT_OK


# ── locating things ────────────────────────────────────────────────────────────────────────────
def kit_root() -> Path:
    """Where the ADAPTERS live. Kit assets ship with the plugin; stack.yaml is project data, and on
    a plugin/pip install those roots diverge. Resolve from this script's own dir — never the
    project root (selftest section 20 guards this class of install bug)."""
    env = os.environ.get("CLAUDE_PLUGIN_ROOT")
    if env and (Path(env) / "adapters").is_dir():
        return Path(env)
    return Path(__file__).resolve().parent.parent


def user_config_home() -> Path:
    return Path(os.environ.get("XDG_CONFIG_HOME") or (Path.home() / ".config")) / "ticketwright"


def _trace(root: Path, note: str) -> None:
    config_trace(root, note)


# ── loading ────────────────────────────────────────────────────────────────────────────────────
def _load(path: Path, errors: list[ConfigError], label: str) -> dict | None:
    if not path.is_file():
        return None
    try:
        data = parse_file(path)
    except YamliteError as exc:
        errors.append(ConfigError("malformed", label, str(exc), str(path)))
        return None
    except OSError as exc:
        errors.append(ConfigError("malformed", label, f"unreadable: {exc}", str(path)))
        return None
    if data is None:
        return {}
    if not isinstance(data, dict):
        errors.append(ConfigError("malformed", label, "top level must be a mapping", str(path)))
        return None
    return data


def resolve_person(root: Path, explicit: str | None, tier3: dict | None) -> str | None:
    """--person -> bin/whoami.py (tier-3 `person:` -> $TICKETWRIGHT_PERSON -> identity map) -> None.

    The resolver does NOT grow its own identity matcher. `bin/whoami.py` is the kit's single,
    deliberately non-guessing matcher (statuses resolved/miss/ambiguous/conflict, exact matches
    only; `bin/resolve_user.py` is a voice-mapping shim over it). Two independent identity
    resolvers is the thing that must not happen — so the whole order, including the
    $TICKETWRIGHT_PERSON tier, lives THERE, and the already-parsed tier 3 is passed through. An
    `ambiguous` or `miss` result yields no person rather than a pick.
    """
    if explicit:
        return explicit
    try:
        import whoami  # noqa: PLC0415 — same dir; imported lazily to keep the CLI cheap
        res = whoami.resolve(root, tier3=tier3)
        if res.get("id"):
            return str(res["id"])
    except Exception:  # noqa: BLE001 — identity is optional; never let it break config resolution
        pass
    return None


def people_ids(root: Path) -> list[str]:
    """Every `people/<id>.yaml` id across both tier-2 homes — PRESENCE, not parseability.

    Deliberately a filename scan rather than `whoami.load_people()`: a people file the parser
    chokes on still means this repo has a roster, and treating it as "no people map" would restore
    exactly the `assignee_dir` fallback the roster exists to prevent.
    """
    ids: set[str] = set()
    for home in (user_config_home() / "people", root / "people"):
        try:
            if home.is_dir():
                ids.update(p.stem for p in home.glob("*.yaml") if p.is_file())
        except OSError:
            continue
    return sorted(ids)


def _resolve_owner(res: "Resolution") -> None:
    """Set `owner` + `owner_source` — see the module docstring for the four outcomes."""
    if res.person:
        res.owner, res.owner_source = res.person, OWNER_RESOLVED
        return
    if res.people:
        # A roster exists and this person is not in it (or is an identity-free placeholder).
        res.owner, res.owner_source = None, OWNER_UNBOUND
        return
    assignee = res.project.get("assignee_dir")
    if isinstance(assignee, str) and assignee.strip():
        res.owner, res.owner_source = assignee.strip(), OWNER_FALLBACK
        return
    res.owner, res.owner_source = None, OWNER_NONE


def _adapter_frontmatter(adapter_rel: str | None, root: Path) -> dict | None:
    """An adapter's frontmatter, or None when it cannot be found or read.

    Adapters are KIT assets; the stack is PROJECT data. On a plugin/pip install those roots diverge,
    so look in the kit first and fall back to the project for repo-vendored adapters.
    """
    if not adapter_rel:
        return None
    for base in (kit_root(), root):
        cand = base / adapter_rel
        if cand.is_file():
            try:
                from _yamlite import parse_frontmatter  # noqa: PLC0415
                fm, _ = parse_frontmatter(cand.read_text(encoding="utf-8", errors="replace"),
                                          str(cand))
            except (YamliteError, OSError):
                return None
            return fm
    return None


def _as_key_list(raw: object) -> list[str]:
    if isinstance(raw, list):
        return [str(k).strip() for k in raw if str(k).strip()]
    if isinstance(raw, str) and raw.strip():
        return [raw.strip()]
    return []


def adapter_requires(adapter_rel: str | None, root: Path) -> list[str]:
    """The config keys an adapter declares it cannot work without."""
    fm = _adapter_frontmatter(adapter_rel, root)
    return _as_key_list(fm.get("requires")) if fm else []


def adapter_key(adapter_rel: str | None, root: Path, key: str) -> str | None:
    """One scalar an adapter spells for itself: `dev_key:`, `channel_key:`, `destination_key:`.

    The pattern is deliberate and reused rather than re-invented per seam — an adapter names the key
    ITS tool uses (Slack says `default_channel`, Teams says `channel`) so no skill ever has to know
    which tool it is talking to. Callers validate the returned NAME before using it as a lookup:
    adapter frontmatter is repo-supplied input, not documentation.
    """
    fm = _adapter_frontmatter(adapter_rel, root)
    val = (fm or {}).get(key)
    return val.strip() if isinstance(val, str) and val.strip() else None


def _adapter_user_keys(adapter_rel: str | None, root: Path,
                       errors: list[ConfigError]) -> set[str] | None:
    """The `user_keys:` an adapter declares, or None when the adapter cannot be found."""
    if not adapter_rel:
        return None
    for base in (kit_root(), root):
        cand = base / adapter_rel
        if cand.is_file():
            fm = _adapter_frontmatter(adapter_rel, root)
            if fm is None:
                return None
            raw = fm.get("user_keys")
            keys = set()
            if isinstance(raw, list):
                keys = {str(k).strip() for k in raw if str(k).strip()}
            elif isinstance(raw, str) and raw.strip():
                keys = {raw.strip()}
            bad = keys & RESERVED_SEAM_KEYS
            # An adapter's OWN destination is reserved too, derived rather than listed. The static
            # set above can only name the destination keys that exist TODAY; a new adapter that
            # declares `destination_key: x` and then lists `x` in user_keys would leave its
            # destination tier-3 overridable, which is the redirect hole `drive_folder` was added
            # to close. Deriving it means the rule holds for adapters nobody has written yet.
            own_dest = {k for k in (adapter_key(adapter_rel, root, "destination_key"),
                                    adapter_key(adapter_rel, root, "channel_key")) if k}
            bad |= keys & own_dest
            if bad:
                errors.append(ConfigError(
                    "prohibited_override", f"adapter:{adapter_rel}",
                    "adapter declares reserved key(s) in user_keys: " + ", ".join(sorted(bad))
                    + " — these select data or wire the seam and can never be personal",
                    str(cand)))
                keys -= bad
            return keys
    return None


# ── seam shapes ────────────────────────────────────────────────────────────────────────────────
def _is_multi_target(seam: Any) -> bool:
    return isinstance(seam, dict) and isinstance(seam.get("targets"), dict)


def _seam_scalars(seam: dict) -> dict:
    """A seam's own scalar keys, which its targets inherit. `default`/`targets` are structure."""
    return {k: v for k, v in seam.items()
            if k not in ("targets", "default") and not isinstance(v, (dict, list))}


def _effective_target(seam: dict, target: dict) -> dict:
    """A target inherits any key it does NOT DEFINE — keyed on absence, not emptiness.

    An explicit `verify: null` is a deliberate "skip" and must not fall through to the seam's
    command. This ports the rule bin/verify_stack.sh already implements.
    """
    out = dict(_seam_scalars(seam))
    for k, v in target.items():
        out[k] = v
    return out


def select_unit(seams: dict, seam_name: str,
                target_name: str | None) -> tuple[dict | None, dict | None]:
    """The CONFIG half of target resolution: one seam, optionally one named target.

    Returns (unit, None) or (None, error). The caller-context precedence (an explicit flag, the
    `-- warehouse-target:` file header, the ticket's declaration) lives in adapters/README.md
    § Multi-target seams and cannot be known here; this function owns only its config steps — an
    explicit name, else the seam's `default:`, else the single mapping itself.

    An unresolvable NAME is a hard error naming what IS configured, never a fallback to another
    target: falling back is precisely the wrong-warehouse (and, for chat, the wrong-audience)
    failure. That includes a `targets:` block whose `default:` is missing or names an unknown
    target — the first-listed target is a display convention, not a selection rule.
    """
    seam = seams.get(seam_name)
    if not isinstance(seam, dict):
        return None, {"code": "no_such_seam",
                      "message": f"seam `{seam_name}` is not configured in this stack",
                      "configured": sorted(k for k, v in seams.items() if isinstance(v, dict))}
    if not _is_multi_target(seam):
        if "targets" in seam:
            # `targets: null` / `targets: []` is a MALFORMED discriminator, not a single mapping.
            # Resolving it as single would bypass every named-target rule downstream (including
            # /ship's halt), so it is unresolvable — same hard edge as an unknown name.
            return None, {"code": "no_such_target",
                          "message": f"`{seam_name}` has a `targets:` key that is not a mapping "
                                     f"of named targets — fix the config; a malformed `targets:` "
                                     f"never resolves as a single mapping",
                          "configured": []}
        if target_name is not None:
            return None, {"code": "no_such_target",
                          "message": f"`{seam_name}` is a single mapping — no targets are "
                                     f"configured, so `{target_name}` cannot be selected",
                          "configured": []}
        return {"seam": seam_name, "target": None, "is_default": True, "label": seam_name,
                "values": dict(seam), "selected_by": "single"}, None
    targets = seam["targets"]
    names = sorted(t for t, v in targets.items() if isinstance(v, dict))
    raw_default = seam.get("default")
    # Normalize before ANY lookup: a malformed `default:` holding a list or mapping is unhashable,
    # and `targets.get(unhashable)` raises instead of failing the selection cleanly.
    default = raw_default if isinstance(raw_default, str) and raw_default.strip() else None
    if target_name is None:
        if not default or not isinstance(targets.get(default), dict):
            what = (f"names unknown target `{default}`" if default
                    else ("is missing" if raw_default in (None, "")
                          else "is not a target name"))
            return None, {"code": "no_such_target",
                          "message": f"`{seam_name}` has targets but its `default:` {what} — an "
                                     f"unresolvable selection never falls back to a listed target",
                          "configured": names}
        target_name, selected_by = str(default), "default"
    elif not isinstance(targets.get(target_name), dict):
        return None, {"code": "no_such_target",
                      "message": f"`{seam_name}` has no target `{target_name}`",
                      "configured": names}
    else:
        selected_by = "explicit"
    mark = "*" if target_name == default else ""
    return {"seam": seam_name, "target": target_name, "is_default": target_name == default,
            "label": f"{seam_name}[{target_name}]{mark}",
            "values": _effective_target(seam, targets[target_name]),
            "selected_by": selected_by}, None


# ── the overlay ────────────────────────────────────────────────────────────────────────────────
class _Overlay:
    def __init__(self, data: dict, tier: str, source: Path) -> None:
        self.data, self.tier, self.source = data, tier, str(source)


def _apply_overlay(base: dict, ov: _Overlay, root: Path, prov: dict,
                   errors: list[ConfigError], warnings: list[str]) -> None:
    src, tier = ov.source, ov.tier

    def reject(path: str, msg: str) -> None:
        errors.append(ConfigError("prohibited_override", path, msg, src))

    mode = ov.data.get("mode")
    seam_overlay = ov.data.get("seams")
    if isinstance(mode, str) and mode.strip().lower() == "defaults" and seam_overlay:
        reject("mode", "mode: defaults declares that team defaults were accepted, but this file "
                       "also carries seam overrides — one of the two is wrong")
        return

    for block in RESERVED_BLOCKS:
        if block in ov.data:
            reject(block, f"`{block}:` is not mergeable at any tier — a per-machine or per-person "
                          f"file must never change {'safety policy' if block == 'policies' else 'team project facts'}")

    for key in ov.data:
        if key in RESERVED_BLOCKS or key in STRUCTURAL_KEYS or key in PERSON_KEYS or key == "seams":
            continue
        reject(key, f"unknown top-level key `{key}` — the merge is an allowlist, so an "
                    f"unanticipated key is refused rather than inherited")

    if not isinstance(seam_overlay, dict):
        return
    base_seams = base.setdefault("seams", {})
    for seam_name, seam_ov in seam_overlay.items():
        if not isinstance(seam_ov, dict):
            reject(f"seams.{seam_name}", "a seam override must be a mapping")
            continue
        base_seam = base_seams.get(seam_name)
        if not isinstance(base_seam, dict):
            reject(f"seams.{seam_name}",
                   f"seam `{seam_name}` is not configured in the team stack — an overlay may "
                   f"override a seam, never create one")
            continue
        if _is_multi_target(base_seam):
            _overlay_multi(base_seam, seam_ov, seam_name, root, tier, src, prov, errors, reject)
        else:
            _overlay_single(base_seam, seam_ov, seam_name, root, tier, src, prov, errors, reject)


def _overlay_multi(base_seam, seam_ov, seam_name, root, tier, src, prov, errors, reject) -> None:
    for key, val in seam_ov.items():
        if key != "targets":
            reject(f"seams.{seam_name}.{key}",
                   f"`{seam_name}` is a multi-target seam, so it has no adapter of its own — "
                   f"scope the override to a target: seams.{seam_name}.targets.<name>.{key}")
            continue
        if not isinstance(val, dict):
            reject(f"seams.{seam_name}.targets", "targets override must be a mapping")
            continue
        for tname, tov in val.items():
            base_target = base_seam["targets"].get(tname)
            if not isinstance(base_target, dict):
                reject(f"seams.{seam_name}.targets.{tname}",
                       f"target `{tname}` is not defined in the team stack — an overlay may "
                       f"override a target's credentials, never create, rename or delete one")
                continue
            allowed = _adapter_user_keys(_effective_target(base_seam, base_target).get("adapter"),
                                         root, errors)
            _merge_allowed(base_target, tov, f"seams.{seam_name}.targets.{tname}", allowed,
                           tier, src, prov, reject)


def _overlay_single(base_seam, seam_ov, seam_name, root, tier, src, prov, errors, reject) -> None:
    if "targets" in seam_ov:
        reject(f"seams.{seam_name}.targets",
               f"`{seam_name}` is a single-mapping seam in the team stack — an overlay may not "
               f"introduce targets")
        return
    allowed = _adapter_user_keys(base_seam.get("adapter"), root, errors)
    _merge_allowed(base_seam, seam_ov, f"seams.{seam_name}", allowed, tier, src, prov, reject)


def _merge_allowed(dest: dict, overlay: dict, path: str, allowed: set[str] | None,
                   tier: str, src: str, prov: dict, reject) -> None:
    if allowed is None:
        reject(path, "cannot read the adapter's `user_keys:` declaration, so no override can be "
                     "validated — refusing rather than guessing which keys are personal")
        return
    for key, val in overlay.items():
        full = f"{path}.{key}"
        if key in RESERVED_SEAM_KEYS:
            reject(full, f"`{key}` selects data or wires the seam — it is team-owned and can "
                         f"never be set from a person or machine file")
            continue
        if key not in allowed:
            reject(full, f"the adapter does not declare `{key}` in `user_keys:` "
                         f"(declared: {', '.join(sorted(allowed)) or 'none'})")
            continue
        dest[key] = val
        prov[full] = {"tier": tier, "source": src}


def _deep_merge(base: dict, over: dict) -> dict:
    """Key-by-key merge used ONLY between the two tier-2 homes: the in-repo `people/<id>.yaml`
    overrides the cross-repo copy per key, not whole-file."""
    out = dict(base)
    for k, v in over.items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = _deep_merge(out[k], v)
        else:
            out[k] = v
    return out


# ── the resolution ─────────────────────────────────────────────────────────────────────────────
class Resolution:
    def __init__(self) -> None:
        self.root = Path(".")
        self.person: str | None = None
        self.people: list[str] = []      # the roster: every people/<id>.yaml, both tier-2 homes
        self.owner: str | None = None    # whose tickets/<owner>/ new work belongs in
        self.owner_source: str = OWNER_NONE
        self.project: dict = {}
        self.policies: dict = {}
        self.seams: dict = {}
        self.person_config: dict = {}
        self.viewer_team: dict = {}      # `seams.viewer` / `viewer:` in stack.yaml
        self.viewer_person: dict = {}    # tier 2: glob -> CATEGORY (portable)
        self.viewer_machine: dict = {}   # tier 3: category -> application (machine)
        self.provenance: dict = {}
        self.errors: list[ConfigError] = []
        self.warnings: list[str] = []
        self.tiers: dict = {}
        self.team_seams: dict = {}

    @property
    def ok(self) -> bool:
        return not self.errors

    def exit_code(self) -> int:
        return _exit_code_for(self.errors)

    def as_dict(self) -> dict:
        return {
            "schema": SCHEMA_VERSION,
            "root": str(self.root),
            "person": self.person,
            "people": self.people,
            "owner": self.owner,
            "owner_source": self.owner_source,
            "tiers": self.tiers,
            "project": self.project,
            "policies": self.policies,
            "seams": self.seams,
            "person_config": self.person_config,
            "viewer": viewer_plan(self),
            "selected": self.selected(),
            "provenance": self.provenance,
            "errors": [e.as_dict() for e in self.errors],
            "warnings": self.warnings,
        }

    def selected(self) -> dict:
        out = {}
        for name, seam in self.seams.items():
            if _is_multi_target(seam):
                out[name] = seam.get("default")
            elif isinstance(seam, dict):
                out[name] = None
        return out

    def units(self) -> list[dict]:
        """Every verifiable unit: a single-mapping seam, or one row per target."""
        rows = []
        for name, seam in self.seams.items():
            if not isinstance(seam, dict):
                continue
            if _is_multi_target(seam):
                default = seam.get("default")
                for tname, target in seam["targets"].items():
                    if not isinstance(target, dict):
                        continue
                    rows.append({"seam": name, "target": tname,
                                 "is_default": tname == default,
                                 "label": f"{name}[{tname}]" + ("*" if tname == default else ""),
                                 "values": _effective_target(seam, target)})
            else:
                rows.append({"seam": name, "target": None, "is_default": True,
                             "label": name, "values": dict(seam)})
        return rows

    def get(self, dotted: str, default: Any = None) -> Any:
        node: Any = self.as_dict()
        for part in dotted.split("."):
            if isinstance(node, dict) and part in node:
                node = node[part]
            else:
                return default
        return node


def _compose_paths(res: Resolution) -> None:
    """`base_path` = the docstore's full destination, composed from its team half + its machine half.

    Two shapes, one rule. A MOUNTED docstore composes `{mount_root}/{drive_folder}`: the destination
    is a TEAM decision (`drive_folder`, tier 1) and only the local mount prefix is per-user
    (`mount_root`, tier 3). An UNMOUNTED one (rclone) composes `{remote}:{remote_path}` the same way
    — `remote_path` is the team's destination, `remote` is this machine's alias for the account that
    reaches it. Composing here means adapter verb bodies and verify strings keep interpolating
    `{base_path}` unchanged, and — because routing fingerprints the composed value — a tier-3 edit to
    either machine half moves the delivery plan's fingerprint instead of silently redirecting.
    """
    for unit in res.units():
        vals = unit["values"]
        if vals.get("base_path"):
            continue
        if vals.get("drive_folder"):
            machine, composed_fmt = vals.get("mount_root"), "{m}/{t}"
            team = vals["drive_folder"]
        elif vals.get("remote_path"):
            machine, composed_fmt = vals.get("remote"), "{m}:{t}"
            team = vals["remote_path"]
        else:
            continue
        if not machine:
            continue
        composed = composed_fmt.format(m=str(machine).rstrip("/"), t=str(team).lstrip("/"))
        seam = res.seams[unit["seam"]]
        target = seam["targets"][unit["target"]] if unit["target"] else seam
        target["base_path"] = composed
        key = f"seams.{unit['seam']}" + (f".targets.{unit['target']}" if unit["target"] else "")
        src = ("mount_root + drive_folder" if vals.get("drive_folder") else "remote + remote_path")
        res.provenance[f"{key}.base_path"] = {"tier": TIER_INHERITED, "source": f"composed from {src}"}


def resolve(root: str | Path, person: str | None = None,
            stack_path: str | Path | None = None) -> Resolution:
    """Merge all three tiers. NEVER raises and never exits — see the module docstring."""
    res = Resolution()
    res.root = Path(root).resolve()
    _trace(res.root, "resolve")

    stack_path = Path(stack_path).resolve() if stack_path else (res.root / STACK_REL)
    res.tiers["team"] = str(stack_path)
    if not stack_path.is_file():
        res.errors.append(ConfigError("missing", "stack.yaml",
                                      f"no team config at {stack_path}", str(stack_path)))
        return res

    team = _load(stack_path, res.errors, "stack.yaml")
    if team is None:
        return res
    # Bind each lookup once so the isinstance guard provably covers the value that is assigned
    # (a double `team.get(...)` reads as two chances to disagree, even though it never does).
    _project, _policies, _seams = team.get("project"), team.get("policies"), team.get("seams")
    res.project = _project if isinstance(_project, dict) else {}
    res.policies = _policies if isinstance(_policies, dict) else {}
    res.seams = _seams if isinstance(_seams, dict) else {}
    for key in ("project", "policies", "seams"):
        for sub in (team.get(key) or {}) if isinstance(team.get(key), dict) else {}:
            res.provenance[f"{key}.{sub}"] = {"tier": TIER_TEAM, "source": str(stack_path)}
    if isinstance(team.get("viewer"), dict):
        res.viewer_team = dict(team["viewer"])
    elif isinstance(res.seams.get("viewer"), dict):
        res.viewer_team = dict(res.seams["viewer"])

    local_path = res.root / LOCAL_REL
    tier3 = _load(local_path, res.errors, "connections.local.yaml")
    if tier3 is not None:
        res.tiers["machine"] = str(local_path)

    res.person = resolve_person(res.root, person, tier3)
    res.people = people_ids(res.root)
    _resolve_owner(res)

    # tier 2: cross-repo defaults, then the in-repo copy overriding key by key
    tier2: dict = {}
    tier2_sources: list[str] = []
    tier2_origin: dict[str, str] = {}   # top-level key -> the file that last supplied it
    if res.person:
        xdg = user_config_home() / "people" / f"{res.person}.yaml"
        repo = res.root / "people" / f"{res.person}.yaml"
        for path in (xdg, repo):
            data = _load(path, res.errors, f"people/{res.person}.yaml")
            if data is not None:
                tier2 = _deep_merge(tier2, data)
                # Per-key origin, not just "the last file read": with two tier-2 homes, attributing
                # everything to the in-repo copy would misreport which file a value actually came
                # from — the one question provenance exists to answer.
                for key in data:
                    tier2_origin[key] = str(path)
                tier2_sources.append(str(path))
    if tier2_sources:
        res.tiers["person"] = tier2_sources

    # tier-3 document validity: a versioned document, so file existence alone cannot be mistaken
    # for "configured".
    if tier3:
        fp = tier3.get("stack_fingerprint")
        if isinstance(fp, str) and fp.strip():
            try:
                actual = hashlib.sha256(stack_path.read_bytes()).hexdigest()
            except OSError:
                actual = ""
            if actual and not actual.startswith(fp.strip()):
                res.errors.append(ConfigError(
                    "stale", "stack_fingerprint",
                    "this machine config was completed against a different version of the team "
                    "stack — re-run the per-person setup", str(local_path)))

    res.team_seams = copy.deepcopy(res.seams)

    if tier2:
        res.person_config = {k: v for k, v in tier2.items() if k in PERSON_KEYS}
        for key in res.person_config:
            res.provenance[f"person_config.{key}"] = {
                "tier": TIER_PERSON, "source": tier2_origin.get(key, tier2_sources[-1])}
        _apply_overlay({"seams": res.seams}, _Overlay(tier2, TIER_PERSON,
                                                      Path(tier2_origin.get("seams",
                                                                            tier2_sources[-1]))),
                       res.root, res.provenance, res.errors, res.warnings)
    if tier3:
        _apply_overlay({"seams": res.seams}, _Overlay(tier3, TIER_MACHINE, local_path),
                       res.root, res.provenance, res.errors, res.warnings)
        if isinstance(tier3.get("viewer"), dict):
            res.viewer_machine = dict(tier3["viewer"])
    if isinstance(tier2.get("viewer"), dict):
        res.viewer_person = dict(tier2["viewer"])

    _compose_paths(res)
    return res


# ── the viewer plan ────────────────────────────────────────────────────────────────────────────
# Viewer config is RESOLVER-OWNED, not a seam override. `viewer` was never a `stack.yaml` seam: it
# is the sixth ADAPTER directory, deliberately per-user. So it carries `adapter:`/`open_cmd:` in the
# machine tier even though `adapter` is reserved for every real seam — the two rules do not collide
# because viewer never goes through the seam allowlist at all.
#
# The SPLIT is the non-obvious part. The portable half is the glob -> CATEGORY map (`*.sql` is a
# "sql-editor" file); the machine half is which application fills each category, plus the commands.
# Committing `routes[].app` would send `DataGrip` to someone's Linux box, where the same preference
# is spelled `datagrip.desktop` — the exact failure the split exists to prevent.
VIEWER_LOCAL_REL = ".claude/config/viewer.local.yaml"


def _disabled(cfg: dict) -> bool:
    return scalar_str(cfg.get("enabled")) in ("false", "no", "off", "0")


def _compose_routes(person: dict, machine: dict) -> list[dict]:
    _apps = machine.get("apps")
    apps = _apps if isinstance(_apps, dict) else {}
    routes = []
    for entry in (person.get("categories") or []):
        if not isinstance(entry, dict):
            continue
        glob, category = entry.get("glob"), entry.get("category")
        if not glob or not category:
            continue
        app = apps.get(category)
        if app:
            routes.append({"glob": str(glob), "app": str(app)})
    return routes


def viewer_plan(res: "Resolution") -> dict:
    """The resolved viewer config, first usable source wins.

    ORDER, and why the new form is SECOND rather than first:
      1. `.claude/config/viewer.local.yaml`   — unchanged. An explicitly written local file still
         wins, so nobody who already has one sees any change at all. The `/review` gate writes this
         file just-in-time and that flow is deliberately left alone.
      2. composed tier-2 categories + tier-3 apps                                          [new]
      3. `${XDG_CONFIG_HOME:-$HOME/.config}/ticketwright/viewer.yaml`  — unchanged
      4. `seams.viewer` in stack.yaml (team-wide)                      — unchanged

    A COMPLETENESS PREDICATE guards source 2. handoff.sh is whole-file first-hit-wins, not a merge,
    so a half-configured composed source — categories written, applications not, which is the normal
    state before the per-person flow has run — would win, produce no `open_cmd`, and silently open
    nothing. Worse, the self-healing interview would not fire, because it only offers setup when NO
    config exists. So source 2 only counts when it actually yields a usable command.
    """
    local = res.root / VIEWER_LOCAL_REL
    if local.is_file():
        data = _load(local, [], "viewer.local.yaml") or {}
        out = dict(data)
        out["source"] = str(local)
        out["routes"] = [r for r in (data.get("routes") or []) if isinstance(r, dict)]
        out["usable"] = not _disabled(data) and bool(data.get("open_cmd") or data.get("default_cmd"))
        out["enabled"] = not _disabled(data)
        return out

    if res.viewer_person or res.viewer_machine:
        machine, person = res.viewer_machine, res.viewer_person
        routes = _compose_routes(person, machine)
        enabled = not (_disabled(machine) or _disabled(person))
        out = {k: machine.get(k) for k in ("tool", "adapter", "open_cmd", "default_cmd",
                                           "reveal_cmd", "verify") if machine.get(k)}
        out.update({"source": "people/<id>.yaml + connections.local.yaml", "routes": routes,
                    "enabled": enabled,
                    "usable": enabled and bool(out.get("open_cmd") or out.get("default_cmd"))})
        if out["usable"] or not enabled:
            return out
        # Not usable: fall through rather than shadowing a working source with a half-written one.

    user = user_config_home() / "viewer.yaml"
    if user.is_file():
        data = _load(user, [], "viewer.yaml") or {}
        out = dict(data)
        out["source"] = str(user)
        out["routes"] = [r for r in (data.get("routes") or []) if isinstance(r, dict)]
        out["enabled"] = not _disabled(data)
        out["usable"] = out["enabled"] and bool(data.get("open_cmd") or data.get("default_cmd"))
        return out

    if res.viewer_team:
        out = dict(res.viewer_team)
        out["source"] = res.tiers.get("team", "stack.yaml")
        out["routes"] = [r for r in (res.viewer_team.get("routes") or []) if isinstance(r, dict)]
        out["enabled"] = not _disabled(res.viewer_team)
        out["usable"] = out["enabled"] and bool(out.get("open_cmd") or out.get("default_cmd"))
        return out

    return {"source": None, "routes": [], "enabled": False, "usable": False}


# ── the leak lint ──────────────────────────────────────────────────────────────────────────────
def _team_unit_values(res: "Resolution", unit: dict) -> dict:
    """What TIER 1 alone says for this unit — the committed, shared values."""
    seam = res.team_seams.get(unit["seam"])
    if not isinstance(seam, dict):
        return {}
    if unit["target"]:
        target = seam.get("targets", {}).get(unit["target"])
        return _effective_target(seam, target) if isinstance(target, dict) else {}
    return dict(seam)


def _flag_variants(key: str) -> tuple[str, ...]:
    return (key, key.replace("_", "-"))


def lint(res: "Resolution") -> list[tuple[str, str]]:
    """Warnings about machine-local values sitting in the COMMITTED stack. Warn, never fail.

    Two checks, because the leak takes two shapes and the first check alone misses the one the
    real-world report actually named:

    1. A literal in a key the adapter DECLARES personal (`profile: analytics-prod`). Keyed on the
       DECLARATION, so it still fires alongside an unrelated `{warehouse_id}` token elsewhere.
    2. A machine literal baked into the `verify:` STRING
       (`verify: "databricks --profile analytics-prod current-user me"`). A stack with no `profile:` key at
       all would otherwise produce zero warnings while carrying the leak verbatim.

    Tokenless verifies are correct and stay silent: `snow connection test` and
    `bq query --dry_run "SELECT 1"` name nothing machine-specific.
    """
    out: list[tuple[str, str]] = []
    # The legacy tier-1 voice map holds a person's work email and display name in committed team
    # config. It still resolves, so nothing breaks on upgrade — but this is where that gets said,
    # once per run, rather than from resolve_user on every one of its many invocations.
    vp = res.project.get("voice_profiles")
    if isinstance(vp, dict) and vp.get("map"):
        out.append(("project", "`voice_profiles.map` holds personal identities in committed team "
                               "config — move each person to people/<id>.yaml (tier 2). The legacy "
                               "map still resolves, so this is a cleanup, not a breakage."))
    for unit in res.units():
        team = _team_unit_values(res, unit)
        declared = _adapter_user_keys(unit["values"].get("adapter"), res.root, []) or set()
        for key in sorted(declared):
            if key in team and team[key] not in (None, ""):
                out.append((unit["label"],
                            f"`{key}: {team[key]}` is committed in stack.yaml, but the adapter "
                            f"declares it personal — move it to .claude/config/connections.local.yaml"))
        verify = team.get("verify")
        if isinstance(verify, str) and verify.strip():
            for key in sorted(declared):
                if "{" + key + "}" in verify:
                    continue
                for flag in _flag_variants(key):
                    for sep in (" ", "="):
                        marker = f"--{flag}{sep}"
                        idx = verify.find(marker)
                        if idx == -1:
                            continue
                        value = verify[idx + len(marker):].split()[0] if sep == " " else \
                            verify[idx + len(marker):].split()[0]
                        out.append((unit["label"],
                                    f"verify hardcodes a machine-local `--{flag} {value}` — use "
                                    f"`{{{key}}}` and set {key} in connections.local.yaml"))
                        break
                    else:
                        continue
                    break
        # Which key holds the machine half depends on the adapter: a mounted docstore says
        # `mount_root`, the unmounted one says `remote`. Naming only the first let an rclone slot
        # hardcode `base_path` in committed config and lose the tier split without a word.
        machine_half = next((k for k in ("mount_root", "remote") if k in declared), None)
        if team.get("base_path") and machine_half:
            out.append((unit["label"],
                        "`base_path` mixes a team decision with a machine path — split it into "
                        + ("`drive_folder` (stack.yaml) + `mount_root` (connections.local.yaml)"
                           if machine_half == "mount_root" else
                           "`remote_path` (stack.yaml) + `remote` (connections.local.yaml)")))
    return out


# ── token interpolation (the verify half) ──────────────────────────────────────────────────────
def interpolate(template: str, tokens: dict) -> tuple[str, list[str]]:
    """Substitute `{key}` tokens, reporting any that stayed unresolved.

    bin/verify_stack.sh's shell interp() leaves an unmatched `{profile}` LITERAL, so a tokenized
    verify would execute `databricks --profile {profile} …` on a machine with no tier 3. Callers
    must treat a non-empty `unresolved` as SKIP-WITH-WARNING, never as a command to run.
    """
    out = template
    for key, val in tokens.items():
        if val is None:
            continue
        out = out.replace("{" + key + "}", str(val))
    unresolved = []
    i = 0
    while True:
        start = out.find("{", i)
        if start == -1:
            break
        end = out.find("}", start)
        if end == -1:
            break
        name = out[start + 1:end]
        if name and all(c.isalnum() or c in "_-" for c in name):
            unresolved.append(name)
        i = end + 1
    return out, unresolved


# Characters that let a substituted value BREAK OUT of the command it was interpolated into.
# verify commands are run through `eval`, and a token's value can now come from a gitignored local
# file, so a value carrying any of these is refused rather than executed. Deliberately narrow:
# spaces, dots and slashes are normal in a mount path and must keep working.
SHELL_METACHARS = set(";|&$`<>()\n\r\\")


def unsafe_tokens(template: str, tokens: dict) -> list[str]:
    """Token names whose value would inject shell syntax into `template`."""
    bad = []
    for key, val in tokens.items():
        if val is None or "{" + key + "}" not in template:
            continue
        if set(str(val)) & SHELL_METACHARS:
            bad.append(key)
    return sorted(bad)


def unit_tokens(res: Resolution, unit: dict) -> dict:
    tokens = {k: v for k, v in res.project.items() if not isinstance(v, (dict, list))}
    for k, v in unit["values"].items():
        if not isinstance(v, (dict, list)):
            tokens[k] = v
    return tokens


# ── CLI ────────────────────────────────────────────────────────────────────────────────────────
def _unit_row(res: Resolution, unit: dict) -> dict:
    vals = unit["values"]
    verify = vals.get("verify")
    # An adapter's `requires:` keys, checked against what is actually SET on this unit. WARN, never
    # fail: an unfilled key is a setup-time TODO, not an unreachable tool, and failing would reject
    # configs written before the check existed. `null` and `""` count as unset — a required key
    # blanked out is the same failure as one never written. Seam-scoped on purpose, so a `project.*`
    # key can never stand in for a missing seam key of the same name.
    missing = [k for k in adapter_requires(vals.get("adapter"), res.root)
               if vals.get(k) in (None, "")]
    row = {"kind": "unit", "label": unit["label"], "seam": unit["seam"], "target": unit["target"],
           "is_default": unit["is_default"], "tool": vals.get("tool") or "?",
           "adapter": vals.get("adapter") or "", "verify": None, "unresolved": [], "unsafe": [],
           "missing_required": missing,
           # The CONFIGURED transport, as resolved for this unit (a target inherits the seam-level
           # value; a target's own wins). Consumed by verify_stack.sh's permission-posture
           # advisory, which falls back to the adapter's frontmatter only when this is empty —
           # the configured unit is the authority on how the team actually connects.
           "transport": vals.get("transport") or ""}
    if isinstance(verify, str) and verify.strip():
        tokens = unit_tokens(res, unit)
        cmd, unresolved = interpolate(verify, tokens)
        row["verify"], row["unresolved"] = cmd, unresolved
        row["unsafe"] = unsafe_tokens(verify, tokens)
    return row


def _emit_verify_plan(res: Resolution) -> None:
    """One JSON row per seam/target unit, plus the structural problems a `targets:` block can have.

    Emitting the structure here rather than in bash is what lets bin/verify_stack.sh drop its hard
    `yq` requirement without reimplementing seam semantics in shell.
    """
    for name, seam in res.seams.items():
        if not isinstance(seam, dict):
            continue
        if not _is_multi_target(seam):
            print(json.dumps(_unit_row(res, {"seam": name, "target": None, "is_default": True,
                                             "label": name, "values": dict(seam)})))
            continue
        targets = seam["targets"]
        default = seam.get("default")
        # Resolve the default BEFORE listing targets, so a bad pointer reports one clear error
        # rather than also triggering the ordering warning (meaningless for a nonexistent name).
        default_ok = False
        if not default:
            print(json.dumps({"kind": "seam_error", "seam": name,
                              "message": f"{name}: 'targets' present but no 'default:' — "
                                         f"skills cannot pick a target"}))
        elif default not in targets:
            print(json.dumps({"kind": "seam_error", "seam": name,
                              "message": f"{name}: default '{default}' is not one of the "
                                         f"defined targets"}))
        else:
            default_ok = True
        for i, (tname, target) in enumerate(targets.items()):
            if not isinstance(target, dict):
                # SKIPPING a malformed target made it invisible: no unit row, no error, and a
                # `targets:` block holding only junk sailed through every downstream check that
                # keys on unit rows (including verify_stack's missing-router failure). A target
                # that exists but cannot be verified is a finding, not an omission.
                print(json.dumps({"kind": "seam_error", "seam": name,
                                  "message": f"{name}: target '{tname}' is not a mapping of "
                                             f"config keys — it cannot be verified or routed"}))
                continue
            mark = "*" if (default_ok and tname == default) else ""
            print(json.dumps(_unit_row(res, {
                "seam": name, "target": tname, "is_default": bool(mark),
                "label": f"{name}[{tname}]{mark}",
                "values": _effective_target(seam, target)})))
            # Readers that predate multi-target display the FIRST target, so listing the default
            # first keeps an un-relaunched session honest.
            if i == 0 and default_ok and tname != default:
                print(json.dumps({"kind": "seam_warn", "seam": name,
                                  "message": f"{name}: default '{default}' is not the first "
                                             f"target — pre-multi-target readers show the first one"}))


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        prog="effective_config.py",
        description="Merge stack.yaml + people/<id>.yaml + connections.local.yaml into one answer.",
        epilog="Exit codes: 0 ok, 2 usage, 3 missing, 4 malformed, 5 stale, 6 prohibited override, "
               "7 seam not configured, 8 target unresolvable.")
    ap.add_argument("--stack", default=None, help="explicit tier-1 stack.yaml path")
    ap.add_argument("--root", default=None, help="repo root (default: $CLAUDE_PROJECT_DIR, else cwd)")
    ap.add_argument("--person", default=None, help="person id for tier 2 (default: resolved)")
    ap.add_argument("--json", action="store_true", help="emit the full resolution as JSON")
    ap.add_argument("--key", default=None, help="print one dotted value (e.g. seams.warehouse.cli)")
    ap.add_argument("--verify-plan", action="store_true", help="one JSON row per seam/target unit")
    ap.add_argument("--viewer-plan", action="store_true", help="the resolved viewer config as JSON")
    ap.add_argument("--lint", action="store_true", help="warn about machine-local values in committed config")
    ap.add_argument("--seam", default=None, metavar="NAME",
                    help="select one seam as JSON, inheritance and overlays applied "
                         "(adapters/README.md § Selecting a target from config)")
    ap.add_argument("--target", default=None, metavar="NAME",
                    help="with --seam: select this named target instead of the seam's default; "
                         "an unknown name is a hard error (exit 8), never a fallback")
    ap.add_argument("--quiet", action="store_true", help="suppress the human-readable error report")
    args = ap.parse_args(argv)

    # Presence is `is not None`, never truthiness: `--target ''` must be a usage error, not a
    # silent fall-through to the full-config output.
    if args.target is not None and args.seam is None:
        ap.error("--target requires --seam")
    if args.seam is not None:
        if args.json or args.key or args.verify_plan or args.viewer_plan or args.lint:
            ap.error("--seam is its own output mode — combine it only with --target "
                     "(and --root/--stack/--person/--quiet)")
        if not args.seam.strip() or (args.target is not None and not args.target.strip()):
            ap.error("--seam and --target need a non-empty name")

    root = args.root
    if not root:
        # An explicit --stack may point outside any project (verify_stack.sh is given a
        # bare path in several fixtures); derive the project root from it the way
        # verify_stack.sh always has.
        root = (os.environ.get("CLAUDE_PROJECT_DIR")
                or (str(Path(args.stack).resolve().parent.parent.parent) if args.stack
                    else os.getcwd()))
    res = resolve(root, args.person, args.stack)

    sel_exit: int | None = None
    if args.seam is not None:
        unit, sel_err = select_unit(res.seams, args.seam, args.target)
        # select_unit's contract is unit XOR sel_err; the explicit `unit is None` arm keeps the
        # error path loud (never a crash on sel_err[...]) even if that contract is ever broken.
        if unit is None and not sel_err:
            sel_err = {"code": "no_such_seam",
                       "message": f"`{args.seam}` did not resolve to a unit", "configured": []}
        if sel_err:
            print(json.dumps({"schema": SCHEMA_VERSION, "seam": args.seam, "target": args.target,
                              "error": sel_err,
                              "errors": [e.as_dict() for e in res.errors],
                              "warnings": res.warnings}, indent=2, default=str))
            if not args.quiet:
                hint = (" (configured: " + ", ".join(sel_err["configured"]) + ")"
                        if sel_err["configured"] else "")
                print(f"effective_config: {sel_err['code']}: {sel_err['message']}{hint}",
                      file=sys.stderr)
            # A stack that failed to LOAD is the real story — `no_such_seam` against zero seams
            # would misdirect the fix — so missing/malformed keep their own exit codes.
            if not any(e.code in ("missing", "malformed") and e.path == "stack.yaml"
                       for e in res.errors):
                sel_exit = EXIT_NO_SEAM if sel_err["code"] == "no_such_seam" else EXIT_NO_TARGET
        else:
            row = _unit_row(res, unit)
            out = {"schema": SCHEMA_VERSION, "seam": row["seam"], "target": row["target"],
                   "selected_by": unit["selected_by"], "is_default": row["is_default"],
                   "label": row["label"], "tool": row["tool"], "adapter": row["adapter"],
                   "values": unit["values"], "verify": row["verify"],
                   "unresolved": row["unresolved"], "unsafe": row["unsafe"],
                   "missing_required": row["missing_required"],
                   "errors": [e.as_dict() for e in res.errors], "warnings": res.warnings}
            if out["unresolved"] or out["unsafe"]:
                # A command string is runnable or it is null — never a half-interpolated template,
                # never one carrying an injected tier-3 value. Same refusal verify_stack.sh applies;
                # the reason stays readable in `unresolved` / `unsafe`.
                out["verify"] = None
            print(json.dumps(out, indent=2, default=str))
    elif args.key:
        val = res.get(args.key)
        if val is not None:
            print(scalar_str(val) if isinstance(val, bool) else
                  ("" if val is None else (json.dumps(val) if isinstance(val, (dict, list)) else val)))
    elif args.verify_plan:
        _emit_verify_plan(res)
    elif args.viewer_plan:
        print(json.dumps(viewer_plan(res)))
    elif args.lint:
        for label, msg in lint(res):
            print(f"{label}\t{msg}")
    else:
        print(json.dumps(res.as_dict(), indent=2, sort_keys=False, default=str))

    if res.errors and not args.quiet:
        for err in res.errors:
            print(f"effective_config: {err.code}: {err.path}: {err.message}", file=sys.stderr)
    # A failed selection (7/8) outranks a merely-degraded resolution; a SUCCESSFUL selection never
    # masks a resolution error — a prohibited override still exits 6 with the selection printed.
    return sel_exit if sel_exit is not None else res.exit_code()


if __name__ == "__main__":
    sys.exit(main())
