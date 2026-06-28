# Ticketwright Roadmap

> What's next for the kit. Subject to change; issues and PRs welcome. The principle that gates every
> item: stay **lightweight** (stdlib-only Python, bash-3.2-safe, no embeddings / vector DB / servers)
> and **tool-agnostic** (skills never name a tool; seams swap via one adapter file).

## Where we are — v1.2 (June 2026)

The ticket index is **active**, not just browsable, and observable.

- **Prior-art recall** (`/recall`, `bin/recall.py`) with **IDF object down-weighting** (eval-tuned),
  an advisory verdict line, and a read-only **`--eval`** recall-quality diagnostic.
- **Object reverse-index** (`tickets/OBJECTS.md`), scale-aware above ~150 objects.
- **Deep QC** (`qc-review --deep`) — adversarial reviewer panel.
- **Index observability** — `--recurring` (productize candidates) and `--stats` health metrics.
- **Ingest validation** trust boundary; **privacy guard** (the per-install store can't be committed).
- 19 adapters across 5 seams; 3 worked stacks; **71-check self-test**; GitHub Actions CI.

Lineage: Ticketwright is the canonical evolution of the earlier `crank-tickets` / GDD experiment — the
advanced *engine* (recall, objects, deep-QC, eval, adapters, hooks) with GDD's *distribution* ideas
(plugin packaging, role modes) folded in here.

## Next — v1.3 (distribution + the tracker contract)

| Item | Why | Notes |
|---|---|---|
| **Plugin packaging** (`.claude-plugin/plugin.json`) | One `claude plugin install` instead of `cp -r` four dirs. The change that makes "canonical" real. | Per-repo config (`stack.yaml`, `AGENTS.md`, scaffolding) still written by `/configure-workspace`; bundled `bin/`/`adapters/`/`templates/` referenced via `${CLAUDE_PLUGIN_ROOT}`. |
| **Role-mode AGENTS.md** (analyst / engineer / scientist / generalist) | `/configure-workspace` tailors the rendered rules to the team's persona. | Lightweight: short role-focus snippets, not duplicate templates. |
| **CI scrub + structure check** | Guard against a leaked identifier or a malformed skill/adapter reaching the public repo. | Folds into the existing self-test / CI. |

## Then — v1.4+ (harden the tracker contract)

Surfaced by a two-AI (Codex + agent-panel) review as the top *coverage* gaps — the abstraction is
solid for keyed trackers (Jira/Linear) and good-with-caveats for integer/label ones:

- **Tracker `id_mode` contract** — `keyed | integer | gid` + a normalizer so integer trackers (Azure
  Boards, GitHub Issues) stop being a silent abstraction leak (bare number for the CLI, `KEY-123` for
  branches/folders/index). *The single highest-value contract fix.*
- **Semantic adapter lint** — verify each adapter's token references resolve and required frontmatter is
  present (today the self-test checks verb *shape*, not correctness).
- **Executable `download_attachments`** — ship a real per-adapter snippet or a declared manual fallback
  (today several are prose "curl each URL"; the Jira helper is described but not shipped).
- **First-class `transition` state resolution** — a command to enumerate a tracker's workflow states
  instead of "resolve the done state from the project."

## New trackers (each ≈ one adapter file)

YouTrack / Plane (key-prefix → copy Linear/Jira) · Shortcut (integer → copy GitHub Issues) ·
ClickUp / Height (label-status → copy Monday) · Trello (list-as-status → copy Asana).

## Deliberately out of scope

Embeddings / vector retrieval (lexical rank→read-top-K scales to ~500 tickets), weight auto-tuning
(`--eval` showed the hand-set `4/3/5/1` weights are robust — a tuner would overfit and erode
transparency), and a standalone knowledge-base/orchestration service.
