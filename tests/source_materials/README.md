# tests/source_materials — the classifier's golden corpus

`fixtures/` holds synthetic source-material files; `golden.json` pins what
`bin/scan_source_materials.py` must classify each one as. `bin/selftest.sh` section 49 replays
the corpus and compares, so a change to the thresholds or the shape patterns turns the suite red
instead of shipping silently.

Every fixture is invented — no real meeting, person, or organization appears here (this is a
public repo; see AGENTS.md).

**The expected kinds are AUTHORED INTENT, not whatever the classifier happens to say.** Each
fixture below was written to have one right answer, stated here in prose first; the regeneration
snippet at the bottom is a convenience for re-serializing after a deliberate change, not the
source of truth. If regenerating flips a fixture's kind, that is the corpus catching a
regression — reconcile it against the intent below rather than accepting the new value.

Six of the nine exist to pin a specific failure mode, and deleting them would quietly weaken
the gate:

- **`2026-08-20-roadmap-sync-meeting.md` — the collision case.** It carries the *curated*
  filename convention but a full transcript body, and must classify `raw_suspect`. This is what
  proves content beats filename: if the convention alone decided, renaming a transcript would
  defeat the gate.
- **`notes.md` — the filename-gate miss.** A full transcript with an innocuous name and no
  `transcript` substring. A filename-only rule passes it; the shape test must catch it.
- **`standup-notes.md` — the false-positive case.** Ordinary meeting notes with a timestamped
  agenda. It must stay `other`. This is what the two-condition shape test (a line COUNT *and* a
  ratio) exists for — either condition alone flags this file.
- **`2026-08-20-pricing-review-meeting.md` — the curated summary that quotes.** It contains two
  verbatim transcript lines and must still classify `curated`; a curated excerpt is the artifact
  the policy wants committed.

- **`weekly-sync.vtt` — the format the platforms actually export.** WebVTT is the default
  transcript download from the major meeting platforms, and it arrives named for the meeting, not
  for what it is. Its timestamp and its speaker sit on *different* lines, so every same-line
  speaker pattern misses it entirely — this file classified as `other` and passed the whole gate
  until the caption rules existed. Must be `raw_suspect`.
- **`recording-export.txt` — the same content, disguised.** Header stripped and renamed to
  `.txt`, so neither the extension rule nor the `WEBVTT` header can help. Only the cue-timing
  count catches it. Must be `raw_suspect`.

The other three cover the plain paths: a self-declaring `*transcript*` filename, a binary, and an
ordinary forwarded input.

**A known limit, fixtured nowhere because the classifier cannot cover it:** a transcript exported
as a binary office document (`.docx`) classifies as `binary` and is NOT flagged — its text is
never extracted. Only its filename and extension are evidence. `bin/scan_source_materials.py`'s
docstring lists this alongside the other honest limits.

Regenerate after a deliberate classification change:

```bash
python3 - <<'PY'
import json, sys
from pathlib import Path
sys.path.insert(0, "bin")
import scan_source_materials as s
out = {}
for f in sorted(Path("tests/source_materials/fixtures").iterdir()):
    r = s.classify_path(f)
    out[f.name] = {"kind": r["kind"], "intake": r["kind"] in (s.KIND_CURATED, s.KIND_OTHER)}
Path("tests/source_materials/golden.json").write_text(json.dumps(out, indent=2) + "\n")
PY
```

Like `tests/emit/`, this directory ships nowhere: it is repo-only test material, deliberately
absent from `pyproject.toml`'s wheel force-includes.
