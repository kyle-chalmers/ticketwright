---
description: Intentionally malformed frontmatter. Not a real skill.
name [THIS LINE HAS NO COLON so the YAML parser must reject it
---

# Negative-control fixture

Copied over a real SKILL.md in a throwaway tree so CI can assert that validation FAILS.
If it passes with this file in place, the gate is not reading skills. See the
plugin-validate job in .github/workflows/ci.yml.
