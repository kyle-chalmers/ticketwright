---
description: Prime context for the data objects a ticket touches — scoped schemas/DDL, not the catalog
argument-hint: <object-or-topic> [more objects...]
allowed-tools: [Read, Bash, Grep, Glob]
---

# /prime-warehouse

Loads the **specific** warehouse objects relevant to the task — their columns, DDL, and dependencies
— instead of the entire data catalog. Run after `/prime-ticket`, once you know which tables/views
are in play.

## Resolve
- **Objects:** `$ARGUMENTS` (names or a topic to search for).
- **Config:** `.claude/config/stack.yaml` → `seams.warehouse` (adapter, dev_db, etc.). If
  `seams.warehouse` is absent/null, report "no warehouse configured" and stop.

## Steps
1. **Preflight verify** the warehouse seam (run `seams.warehouse.verify`; if it fails, halt with the
   adapter's auth notes — don't guess at schemas).
2. **Resolve the objects.** If given a topic not an exact name, first check the local context pack
   (`!grep -ril "<topic>" documentation/ 2>/dev/null | head`) and the adapter's discovery query to
   find the real object names.
3. **Describe each object** via the adapter's `describe` verb (columns + types, and DDL where
   supported). Pull a 5-row sample via `query` (`SELECT * … LIMIT 5`) to see real values.
4. **Map dependencies** (what the object reads / what reads it) using the adapter's lineage approach
   (`dialect_notes` says how — use the real dependency/lineage source, not a naive object list that
   misses dynamic or base tables).
5. **Report** a compact schema brief: per object, the key columns, join keys (+ any cast/filter
   rules from `dialect_notes`), grain, and the safest source layer to read from.

## Why
Front-loads the *exact* schema facts the implement phase needs, so JOINs and filters are right the
first time — without bloating context with 290 objects you won't touch.
