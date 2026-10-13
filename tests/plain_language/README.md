# Plain-language lint

`check.py` checks one part of the writing rule in `AGENTS.md`: the plain part of anything a person
sees (everything before ` Details:`) is non-empty and uses none of the terms in `terms.txt`. Code
spans are exempt. Section 59 also pins the caveats of specific named messages. The rest of the rule
(lead with what happened and what to do, talk to the person, keep caveats, keep protocol tokens
exact) is a writing rule contributors follow by hand. Selftest section 59 runs it over the guard golden
corpus, captured output of the guards, the other-runtime shim, the session banners, the stack
check, the identity resolver and the doctor, the config modules' error strings (`effective_config.py`
and `delivery_plan.py`), and the `/ship`, `/review` and `qc-reviewer` text inside
`<!-- ticketwright:user-facing:begin -->` / `<!-- ticketwright:user-facing:end -->`. Docs, adapters
and README prose are not linted.

When it fails, it names the term and what to say instead. Rewrite the message; move anything a
maintainer needs into the Details clause. Add a term to `terms.txt` when a new internal word starts
showing up in output.
