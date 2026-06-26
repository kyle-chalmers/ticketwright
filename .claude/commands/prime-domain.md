---
description: Prime business/domain context for a topic — the glossary + rules slice, not everything
argument-hint: <topic> (e.g. "debt sale", "collections roll rate", "fraud")
allowed-tools: [Read, Grep, Glob]
---

# /prime-domain

Loads the **business meaning** behind a topic — definitions, status taxonomies, calculation rules,
known data-quality gotchas — from the context pack, scoped to what the ticket is about. Run when the
*business logic* is the uncertain part (not the schema).

## Resolve
- **Topic:** `$ARGUMENTS`.
- **Context pack:** the `documentation/` tree (built/refreshed by `/build-context-pack`): catalog,
  business-context, glossary, runbooks.

## Steps
1. **Find the relevant slices:** `!grep -ril "<topic>" documentation/ 2>/dev/null` and read only the
   matching sections (not whole files).
2. **Extract:** the definition(s), any status/category taxonomy, the calculation or eligibility
   rules, exclusions, and documented edge cases / data-quality caveats for this topic.
3. **Pull the operating rules** that apply: scan `AGENTS.md` (or the rendered global-rules file) for
   any hard rule mentioning the topic (e.g. "as-of date is month-end", "exclude edited payments").
4. **Report** a domain brief: what the terms mean here, the rules you must honor, the exclusions, and
   the gotchas — each with a pointer to its source doc so it can be verified.

## Why
Business logic is where data tickets silently go wrong. Priming the glossary + rules slice (not the
whole knowledge base) keeps the agent correct and the context lean. Pairs with `/build-context-pack`,
which produces what this reads.
