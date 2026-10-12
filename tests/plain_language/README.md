# Plain-language lint

`check.py` enforces the message contract in `AGENTS.md`: the plain part of anything a person
sees (everything before ` Details:`) leads with what happened and what to do, and uses none of the
terms in `terms.txt`. Code spans are exempt. Selftest section 59 runs it over the guard golden
corpus, captured output of the guards, the other-runtime shim, the session banners, the stack
check, the identity resolver and the doctor, the config modules' error strings (`effective_config.py`
and `delivery_plan.py`), and the `/ship`, `/review` and `qc-reviewer` text inside
`<!-- ticketwright:user-facing:begin -->` / `<!-- ticketwright:user-facing:end -->`. Docs, adapters
and README prose are not linted.

When it fails, it names the term and what to say instead. Rewrite the message; move anything a
maintainer needs into the Details clause. Add a term to `terms.txt` when a new internal word starts
showing up in output.
