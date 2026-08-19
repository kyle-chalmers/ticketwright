# Browsing your tickets as a graph (Obsidian)

Ticketwright renders a small, auto-maintained graph layer under `tickets/` every time the ticket
index rebuilds. It is plain markdown — it works on GitHub and in any editor — but
[Obsidian](https://obsidian.md)'s Graph view is what it is shaped for: open the repo as a vault
and your whole body of work becomes a browsable tickets↔objects web.

Nothing here is required. The layer renders whether or not Obsidian is installed, `/setup` never
asks about it, and the setup report prints at most one pointer at this page.

## Install (two lines)

```bash
brew install --cask obsidian     # macOS; Linux/Windows: download from https://obsidian.md
open -a Obsidian .               # then "Open folder as vault" → this repo's root
```

On Linux/Windows: install from <https://obsidian.md/download>, then **File → Open folder as
vault** and pick the repo root.

## What you'll see — two node types

| Node | File | Meaning |
|---|---|---|
| **Ticket** | `tickets/graph/<owner>.<id>.md` | One node per ticket, keyed by owner **and** id, so two people's same-named tickets never merge. Links to the objects it touched and the tickets it built on. |
| **Object** | `tickets/objects/<object>.md` | One node per data object (table, view, report). Its local graph is every ticket that ever touched it. |

Open a ticket node and you see its objects plus its cross-referenced prior work; open an object
node and you see the full history of work against it — the reverse lookup `tickets/OBJECTS.md`
gives you as a table, drawn as a picture.

## Zero manual setup

The index renderer also seeds `.obsidian/graph.json` with a tickets↔objects filter and color
groups, so the Graph view opens already focused — READMEs filtered out, ticket and object nodes
color-coded. The write is **create/merge-only**: your own forces, zoom, filters and groups are
never clobbered.

## Opting out

In `.claude/config/stack.yaml`:

- `project.graph_notes: false` — turn the whole layer off (no `tickets/graph/`, no
  `tickets/objects/`).
- `project.graph_config: false` — keep the nodes but stop managing `.obsidian/graph.json`.

Both default to `true`. Details on the renderer live in
[docs/ticket-index.md](ticket-index.md).
