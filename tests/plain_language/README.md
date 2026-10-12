# Plain-language lint

`check.py` enforces the message contract in `AGENTS.md`: the plain part of anything a person
sees (everything before ` Details:`) leads with what happened and what to do, and uses none of the
terms in `terms.txt`. Code spans are exempt. Selftest section 59 runs it over the guard golden
corpus, captured hook and script output, the config modules' error strings, and skill text inside
`<!-- ticketwright:user-facing:begin -->` / `<!-- ticketwright:user-facing:end -->`.

When it fails, it names the term and what to say instead. Rewrite the message; move anything a
maintainer needs into the Details clause. Add a term to `terms.txt` when a new internal word starts
showing up in output.
