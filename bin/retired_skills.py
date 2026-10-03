#!/usr/bin/env python3
"""Retired skills: the one list, and the one rule for removing what an upgrade left behind.

A skill rename leaves the OLD directory beside the new one on every install that only ever writes:
`ticketwright init` copies the kit in, `ticketwright install` emits a translated tree, and a
vendored copy upgraded by `git pull` prunes nothing. Both copies are then model-invocable and show
up in the slash menu, and the stale one points at templates that no longer exist, so it fails
AFTER its hard halt has already been cleared.

THE RULE. A retired directory is removed only when every file in it is provably ours and unedited:
its bytes hash to a version Ticketwright actually shipped, or (emitted trees only) it carries the
emitter's provenance header, which already marks a file the emitter overwrites on every re-run.
Anything else (an edited copy, a CRLF checkout, a file nobody shipped) keeps the old behavior: a
WARNING naming the directory and the files that differ, and nothing deleted. Removing a file the
user may have changed is not this tool's call; removing one it can prove it wrote is.

  bash "$(git rev-parse --show-toplevel 2>/dev/null || echo .)/bin/tw" retired_skills.py [skills_dir]

prunes `skills_dir` (default: the project's `.claude/skills`) by the same rule, for a vendored install that never
re-runs `init`. Callers: ticketwright/cli.py (`init`) and bin/emit_runtime.py (`install`).
"""
from __future__ import annotations

import hashlib
import os
import shutil
import sys
from pathlib import Path
from typing import Callable, Iterable

RETIRED_SKILLS = ("productize", "spec-and-build")

# sha256 of every blob ever committed under .claude/skills/{productize,spec-and-build}/ on main
# (productize/SKILL.md, productize/authoring.md, spec-and-build/SKILL.md; 20 versions). Frozen,
# because the files are gone from the tree. Regenerated with:
#   git rev-list origin/main -- .claude/skills/productize .claude/skills/spec-and-build \
#     | while read c; do git ls-tree -r $c -- .claude/skills/productize .claude/skills/spec-and-build; done \
#     | awk '{print $3}' | sort -u | while read b; do git cat-file blob $b | shasum -a 256 | cut -d' ' -f1; done | sort -u
# selftest section 54(h) recomputes this from history whenever the clone is not shallow.
SHIPPED_SHA256 = frozenset({
    "0a0f42e7f510f671632b6eac14a03adaa6abbd49256954f7d316fceebfd29ff9",
    "15543a0249e3032291b206881a27eb85525b043d9c77e08780ebba1c8bf5a22d",
    "1a4045bcc1f0866780e322181ad537835766d65a353a1585260e7663dcfda889",
    "23ffb8102c0c1823577078ceaf7ce0cbf997fdae4b975d08e4604ecc7bec0e78",
    "564bf4932a871a0ee2d57d77063829b0245a3cb0687aae99135a42918ffec426",
    "60701aa2752b89a01329e0094d8d01b2c157f601dbad2a3706ae07db20adc5e1",
    "6e8a440d75ac36ea7bf18b9cb74a19254e4abac733353b1ccaa1303c435ca505",
    "70723cd80ffcc5c7ba344376ff0c6fefb66fc2f0f8767e54ac3413206bb3383a",
    "78e14aa8b02568cd4ca30fcf29f8de796bef8469863243f93c0728ce88c5c0cc",
    "80e67c962990c21f8f720c3002a2e2543824ab5011f053a57c36c1ed03db0aaa",
    "89c6d62d46ff3835890d15f3220b4654c3ea93b6776077f8b4e2745a8f336322",
    "a1de506ad335e9bf3482afe4345533583ef694a50acabe53fcbf242382eb74a5",
    "a6a40eeddf85f3ab0b2a98b2df058016e8803a1127405eb25956a49f1c6b67c2",
    "ae7935c2168f457c4cb343ff5d70ddc58e438f88b25703158746b1db929d24eb",
    "b98d18187fc7a568e76430fc85565f6532395ed69ce8f14d34c44b75ac94b19c",
    "c0913302e3850389722d4ea40e8920fdf8bc7991d50dfcca5f2844ce41ea5310",
    "c8bf3deeebf0ebebf24f0a36d32a7a4b6ec6978ec5b9bc53bfeb9d582ac74b47",
    "ebe88a016199e979605bf7b5377ddf5e570f75f151f24cf19832152bfe0024f3",
    "fa8e771d5abcf543099fa066d998166c5a86a35c0384a528609a40a613bc5716",
    "fd8b60c259c97ac29b5dbbc10fe151a061c0776274d41851131bb80ffb558849",
})

# Finder litter, not content: it would otherwise pin every retired directory on macOS.
IGNORED = frozenset({".DS_Store"})


def _unrecognized(stale: Path, shipped: Iterable[str],
                  is_ours: Callable[[str], bool] | None) -> list[Path]:
    """Files under `stale` that are NOT provably an unedited Ticketwright file.

    Anything that cannot be inspected (an unlistable directory, an unreadable file) counts as
    unrecognized: the directory is kept. Never raises."""
    shipped = set(shipped)
    odd: list[Path] = []
    for dirpath, dirnames, filenames in os.walk(stale, onerror=lambda e: odd.append(Path(e.filename))):
        d = Path(dirpath)
        for sub in dirnames:
            if (d / sub).is_symlink():
                odd.append(d / sub)  # os.walk does not follow it; it is not ours to vouch for
        for name in filenames:
            f = d / name
            if name in IGNORED:
                continue
            if f.is_symlink() or not f.is_file():
                odd.append(f)
                continue
            try:
                data = f.read_bytes()
            except OSError:
                odd.append(f)
                continue
            if hashlib.sha256(data).hexdigest() in shipped:
                continue
            if is_ours is not None and is_ours(data.decode("utf-8", errors="replace")):
                continue
            odd.append(f)
    return sorted(set(odd))


def _keep(stale: Path, label: str, why: str) -> None:
    print(f"  WARNING: {stale} is a RETIRED skill left over from an older version. It was "
          f"renamed, not removed, so this install has both, and while it exists an agent may "
          f"pick the stale copy ({label}). It was KEPT because {why}. Delete it once nothing in "
          f"it is needed.", file=sys.stderr)


def prune_retired(root: Path, label: str, *, is_ours: Callable[[str], bool] | None = None,
                  shipped: Iterable[str] = SHIPPED_SHA256, remove: bool = True) -> list[Path]:
    """Remove each unedited retired skill directory under `root`; warn about the rest.

    `is_ours` is the emitter's provenance test (emitted trees only). `remove=False` is the
    verify-only mode: same verdicts, nothing deleted. Returns the directories removed. Never
    raises: an installer must not stop half-done over a leftover it was only tidying up."""
    removed = []
    for name in RETIRED_SKILLS:
        stale = root / name
        if stale.is_symlink():
            _keep(stale, label, "it is a symlink, and nothing is deleted through a link")
            continue
        if not stale.is_dir():
            continue
        odd = _unrecognized(stale, shipped, is_ours)
        if odd:
            names = ", ".join(_rel(p, stale) for p in odd[:5])
            more = f" (+{len(odd) - 5} more)" if len(odd) > 5 else ""
            _keep(stale, label, f"these files differ from every shipped version or could not be "
                                f"read: {names}{more}")
            continue
        if not remove:
            print(f"  WARNING: {stale} is a RETIRED skill left over from an older version, and an "
                  f"unedited copy. Remove it with `ticketwright init` or `bin/tw retired_skills.py` "
                  f"({label}).", file=sys.stderr)
            continue
        try:
            shutil.rmtree(stale)
        except OSError as e:
            _keep(stale, label, f"removing it failed part-way ({e})")
            continue
        removed.append(stale)
        print(f"  removed   {stale} (retired skill; an unedited copy of a version Ticketwright "
              f"shipped, so nothing of yours was in it)")
    return removed


def _rel(p: Path, base: Path) -> str:
    try:
        return str(p.relative_to(base))
    except ValueError:
        return str(p)


def main(argv: list[str]) -> int:
    if argv:
        root = Path(argv[0])
    else:
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        import kit_paths  # the project root, not $PWD: a run from a ticket folder still finds it
        root = kit_paths.resolve_project()[0] / ".claude" / "skills"
    if not root.is_dir():
        print(f"retired_skills: {root} is not a directory", file=sys.stderr)
        return 2
    removed = prune_retired(root, f"pruned via retired_skills.py in {root}")
    if not removed:
        print(f"retired_skills: nothing removed under {root}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
