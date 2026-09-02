# Adapters — the verb contract

Skills are written **once** against abstract *verbs*. An **adapter** is a small markdown playbook
that translates those verbs into one concrete tool's commands. To support a new tool (Asana, BigQuery,
Teams, …) you write **one adapter** — you never touch a skill.

```
skill  ──calls──▶  verb (e.g. tracker.fetch_ticket)
                     │
   stack.yaml ──picks──▶ adapter (tracker/jira.md)
                     │
                     ▼
            concrete command (acli jira workitem view ENG-123)
```

A skill resolves a verb like this:
1. Read the MERGED config (`bin/effective_config.py`, not raw `stack.yaml`) → `seams.<seam>.adapter`.
2. Open that adapter, find the verb's section.
3. Run the command shown there, substituting `{tokens}` from `stack.yaml` + skill args.
4. If `seams.<seam>.verify` fails first (hybrid preflight), **halt** with the adapter's auth notes.

Every adapter file has the same shape: a **frontmatter** block (seam, tool, transport, required
config keys, which keys are personal, auth/setup notes) followed by one `## verb: <name>` section per
verb in that seam's contract. A verb section gives the command(s), inputs, the expected output shape, and any gotchas.

---

## The contract (verbs by seam)

### `tracker` — the ticket system
| Verb | Inputs | Returns |
|---|---|---|
| `fetch_ticket` | `id` | title, description, status, type, assignee, links, attachments list |
| `create_ticket` | type, summary, description, assignee, parent/epic | new `id` + URL |
| `transition` | `id`, `status` | ok/fail |
| `comment` | `id`, body, optional smart-link cards | ok/fail (rendered, not plain text) |
| `search` | query (JQL/equivalent), limit | list of `{id, summary, status}` |
| `download_attachments` | `id`, dest dir | files written (silent if none) |
| `rank_projects_by_activity` | `scope`, `window_days`, `limit` | ranked tracker **containers** (Jira project / Azure Boards project / GitHub repo / Linear team / Asana project / monday board) as `{id, name, activity, last_activity, signal}` — or `unsupported` / `unavailable` + reason |

`rank_projects_by_activity` is the seam's one **bootstrap** verb, and it breaks two rules the
others follow — deliberately, because it runs *before* the seam is configured. Its job is to stop
setup from adopting a dead project just because its name matched the repo, so it cannot depend on
the per-project keys (`{key_prefix}`, `{repo}`, `{team_id}`, …) that the choice is about to fill,
and it runs outside the hybrid preflight in step 4 above — a Jira `verify` embeds `{key_prefix}`,
the very value being determined. It needs **auth plus an account-level `scope`** and nothing else.
It is read-only.

Two more inputs are tuning, not contract, so they stay out of the table above (no verb in any seam
carries numeric defaults there) — but a caller can set both: `scan_cap` (default 200) bounds items
counted per container, and `container_cap` (default 25) bounds containers scanned, so a site with
400 projects does not turn one setup question into hundreds of API calls. An adapter whose scan hits
`scan_cap` says so, because the counts are then `>=` it rather than exact.

Which config key a chosen container fills is declared per-adapter in `container_key:` frontmatter,
following the same principle as `dev_key:` below — adapters spell their own key, skills never name
one. It is not a per-call return value, and it is not universal: Jira's container fills
`project.key_prefix` while Azure Boards' fills `seams.tracker.project` and leaves `key_prefix` a
display convention. A choice also never settles the *dependent* keys (`done_state_id`,
`status_column_id`, `done_state`) — those are resolved from the chosen container afterwards.

**Two failure returns, because they are different claims.** `unsupported` means the tool has no
containers to rank at all (the `local` adapter) — the caller skips ranking **silently** and asks as
it would have anyway. `unavailable` means a rankable tracker refused the scan: not authenticated,
no org-read scope, or a plan tier that withholds the search API. That one gets a line to the human
before the same fallback question, because it is fixable and hiding it wastes their time. Ranking
always produces a *default the human confirms*, never an automatic selection.

### `warehouse` — the data/work backend
| Verb | Inputs | Returns |
|---|---|---|
| `query` | SQL, optional `--format csv` | rows / CSV (header row 1, no preamble) |
| `describe` | object name | columns + types (and DDL when supported) |
| `dialect_notes` | — | *static section*: function names, sizing model, dedup idiom, type-cast rules, the warehouse-specific anti-patterns the `review` skill checks |

### `chat` — team messaging
| Verb | Inputs | Returns |
|---|---|---|
| `draft` | channel, body, mentions | a saved draft (human clicks send) |
| `send` | channel, body, mentions | posted message (only on explicit "send it") |
| `lookup_user` | name/email | user ID for mentions |
| `lookup_channel` | name | channel ID |

### `docstore` — durable backup + shareable links
| Verb | Inputs | Returns |
|---|---|---|
| `backup` | local ticket dir, dest name | files copied to the store |
| `link_for` | a backed-up file | a shareable URL (for tracker/chat smart links) |

### `vcs` — version control + PRs
| Verb | Inputs | Returns |
|---|---|---|
| `branch` | name (the ticket id — `{key_prefix}-NNNN`, or the folder slug under `id_mode: slug`) | branch created/checked out |
| `worktree` | branch | isolated worktree path (the Plan→Implement context reset) |
| `commit` | paths, message (semantic) | commit sha |
| `open_pr` | title (semantic), body | PR URL |

### `meetings` — the spoken record, by reference *(optional)*
| Verb | Inputs | Returns |
|---|---|---|
| `fetch_transcript` | a meeting id (from a validated `meeting_ref:` — grammar in `stack.schema.md`; enumerate with `bin/meeting_refs.py`) | transcript text + metadata `{title, date, participants, content_kind}` — **to context, never to disk**. `content_kind` is `transcript` or `notes`: an adapter whose store holds curated notes rather than a verbatim transcript for this meeting says which, never passing one off as the other |
| `search_meetings` | query and/or date window, limit | list of `{id, title, date, participants}` — `participants: []` is a defined value where the provider's list operation exposes no attendee roster; each adapter's section states what it fills |
| `fetch_action_items` | a meeting id | the typed result below |

**`fetch_action_items` returns a typed result** — documented the way ranking documents its own
two failure returns above, because the statuses carry different caller behaviors:

```
{ status: ok | empty | no_native_export,  items: [...] }
```

- `status: ok` — the provider returned ≥1 native action items; `items` populated.
- `status: empty` — the provider HAS native action-item support and returned zero for this
  meeting; `items: []`. Caller: report "no action items recorded"; do **not** fall back to
  extraction — the provider's answer is authoritative (empty native results ≠ no capability).
- `status: no_native_export` — a **static capability fact declared in the adapter's verb
  section** (never a runtime probe): this provider has no native action-item export; `items`
  absent. Caller: the documented manual fallback — extract action items in-context from the
  `fetch_transcript` text.

The three statuses are mutually exclusive by construction. The existing `unsupported` sentinel is
deliberately NOT reused here: its defined caller behavior is a **silent** skip (see ranking
above), and the no-capability outcome of this verb demands the opposite — an active, documented
fallback. `fetch_transcript` and `search_meetings` are mandatory, with no sentinel.

This slot is **read-only and optional** — omitted like `docstore` when the team has no meeting
provider, and the file-backed intake path (a human export into `source_materials/`) keeps working
unchanged either way. `extract_actions` is deliberately not a verb: extracting action items from
free text is model reasoning, and an adapter is a command translation, not a place to hide
reasoning — the extraction fallback is a documented skill-side step. Every adapter's
`fetch_transcript` section carries the transcript-privacy rule verbatim; the mechanical gates
behind that rule (the gitignore patterns, `bin/scan_source_materials.py`, and the
source-material guard) read filenames and document shape, never meaning — curation stays agent
guidance, and the adapters say so rather than implying parity.

### `viewer` — hand an artifact to the human's own application *(optional)*
| Verb | Inputs | Returns |
|---|---|---|
| `open` | one or more paths | each path handed to the application its glob route names |
| `reveal` | a path | the containing folder shown in the OS file manager |

The gate where a person actually *looks* at a deliverable — generated SQL into their IDE, result
CSVs into their spreadsheet app — instead of the model declaring it correct on their behalf. Driven
by policy `human_review_handoff` (`off` | `review` | `all`).

**This seam's config is per-user, not in `stack.yaml`.** Which app opens a `.sql` is a personal
choice, so it resolves first-hit-wins from `.claude/config/viewer.local.yaml` (gitignored) →
`${XDG_CONFIG_HOME:-$HOME/.config}/ticketwright/viewer.yaml` → a `seams.viewer` block in
`stack.yaml` for a team that wants to standardize. Nothing configured ⇒ the feature is off and
skills carry on unchanged. Shape: `.claude/config/viewer.example.yaml`. Skills never invoke these
commands directly — `bin/handoff.sh` resolves the routes and enforces the rails (never launches in
CI or a headless session, never opens a path outside the project).

---

## Multi-target seams

A seam normally names one tool. A repo that must reach more than one warehouse — prod Snowflake plus
a lakehouse, or two accounts of the same warehouse — declares **named targets** instead:

```yaml
seams:
  warehouse:
    default: prod          # required when `targets:` is present
    cli: snow              # seam-level scalars are inherited by every target
    targets:
      prod: { tool: snowflake,  adapter: adapters/warehouse/snowflake.md,  verify: "…" }
      lake: { tool: databricks, adapter: adapters/warehouse/databricks.md, verify: "…" }
```

`targets:` — not `default:` — is what marks a seam multi-target, because other seams already use
`default_channel` / `default_mode` / `default_branch`. Full field docs: `stack.schema.md`.

### Resolving the active target

First hit wins:

1. an explicit `--warehouse <name>` on the invocation;
2. the `-- warehouse-target: <name>` header comment in the `.sql` file being run or linted;
3. the ticket's declared target — the spec's `primary_target`, else the ticket README's target line;
4. `seams.warehouse.default`;
5. the seam itself, when it is a single mapping (call it `default` in reports).

An unresolvable name is a **halt**: say which names are configured. Never quietly fall back to the
default, because that is precisely the wrong-warehouse failure.

That halt rule is seam-generic, not a warehouse nicety: an unresolvable target name on ANY seam
halts and lists the configured names. When chat and docstore grow targets (the delivery plan below),
the same rule extends backward to the **initial** audience/classification resolution — a ticket with
no declared audience is a halt, never a fall-through to the first-listed or default target, because
the default may be the external one.

### Selecting a target from config — the resolver contract

Steps 1–3 above are caller context (a flag, a file header, the ticket's declaration) — the resolver
cannot know them. What it owns is the config half: given a seam and optionally a target name, return
the effective values with inheritance applied, or refuse loudly. Same binary that merges the three
tiers — never a second one:

    bin/effective_config.py --root <repo> --seam <seam>                  # the default target (or the single mapping)
    bin/effective_config.py --root <repo> --seam <seam> --target <name>  # an explicitly named target

Output is one JSON object:

    {
      "schema": 1,
      "seam": "warehouse",
      "target": "lake",              // null for a single-mapping seam
      "selected_by": "explicit",     // "explicit" (--target) | "default" (the seam's default:) | "single"
      "is_default": false,
      "label": "warehouse[lake]",
      "tool": "databricks",
      "adapter": "adapters/warehouse/databricks.md",
      "values": { ... },             // effective values: seam scalars inherited, the target's own keys
                                     // winning, tier-2/3 overlays already merged. An explicit
                                     // `verify: null` on the target stays null (skip, not fall-through).
      "verify": "databricks --profile my-profile current-user me",
      "unresolved": [],              // {token}s interpolation could not fill
      "unsafe": [],                  // tokens whose value carries shell metacharacters (refused)
      "missing_required": [],        // adapter `requires:` keys unset on this unit
      "errors": [ ... ], "warnings": [ ... ]
    }

Rules a caller can rely on (the later chat/docstore routing release implements against exactly
these):

- **An unresolvable name is a hard error, never a fallback.** `--target ghost` exits **8**
  (`no_such_target`) and the error names the configured targets. So does a multi-target seam whose
  `default:` is missing or names an unknown target, and an explicit `--target` on a single-mapping
  seam. Exit **7** (`no_such_seam`) means the seam is not configured at all — the one case a caller
  may degrade (the way `/ship` already skips an absent chat/docstore) instead of halting.
- **`verify` is a runnable command or `null`, nothing in between.** When interpolation leaves an
  unresolved `{token}`, or a token's value carries shell metacharacters (the tier-3 injection
  refusal), the emitted `verify` is `null` and the reason is in `unresolved` / `unsafe`. No
  half-interpolated or injected command string ever leaves the CLI.
- **A successful selection never masks a resolution error.** A prohibited tier-3 override still
  exits 6 even when the selection itself succeeded — read `errors` before trusting `values`.
- **For chat and docstore, `selected_by: "default"` is not audience resolution.** Once those seams
  hold targets, callers must pass an explicit `--target` derived from the delivery plan's declared
  audience/classification; the bare-default form is only step 4 of the warehouse precedence above.

### One file, one target

Line 1 of every `.sql` file names its target:

```sql
-- warehouse-target: lake
```

That one token drives execution, the dialect lint, and the re-run, so it cannot drift from reality
the way a separate annotation would. A ticket spanning two targets carries two sets of files.

**Never put this in a CSV.** A deliverable CSV must keep its header on row 1 with no preamble.
Record a CSV's target in the ticket README's deliverables list instead.

The header is **required only in a multi-target repo**. In a single-warehouse repo its absence is
correct and silent — otherwise every existing ticket everywhere becomes non-conformant.

Two things check it, deliberately:

- **`/review`** flags a headerless or mismatched `.sql` as a Should-fix finding. This is the
  authoritative half — it reads the header directly and works under any agent.
- **the `db_write_guard` hook** prompts *before* a command runs when the invoked CLI doesn't match
  the header's target, including for read-only SQL, since a read on the wrong warehouse returns
  plausible wrong numbers rather than an error. This half is best-effort: it resolves the target's
  CLI with a stdlib scan, and stays silent on anything it can't read confidently (a flow mapping for
  the whole `targets:` value, a target defined by a YAML alias). It is also Claude-Code-only, because
  hooks don't run under other agents.

So the hook catches things earlier and the review catches them more reliably. Neither replaces the
other, which is why both exist.

### The delivery plan — the persisted routing record

The warehouse gets away with a header comment because the `.sql` file IS the executable artifact.
A chat message or a docstore backup has no such file, so its declaration lives in a **persisted
delivery plan**: `delivery-plan.yaml` at the ticket root, committed with the ticket. **This file is
where the audience declaration lives** — there is no other place, and nothing infers one. `/ship`
resolves it, prints it for approval, and executes from that same resolution; `bin/delivery_plan.py`
is the engine that reads it:

    bin/delivery_plan.py --plan <ticket>/delivery-plan.yaml --seam chat      # route from the declaration
    bin/delivery_plan.py --plan <ticket>/delivery-plan.yaml --seam chat --override <target>
    bin/delivery_plan.py --plan <ticket>/delivery-plan.yaml --seam chat --check-draft <file>
    bin/delivery_plan.py --plan <ticket>/delivery-plan.yaml --seam docstore --file <deliverable>
    bin/delivery_plan.py --plan <ticket>/delivery-plan.yaml --seam docstore --record-delivered <path> --url <url>
    bin/delivery_plan.py --stack <stack.yaml> --audit                        # the config rules below

`--override` is **chat only** — the one escape hatch this design authorizes. A deliverable that
belongs in a different store declares it (below), because a declaration stays with the ticket and a
flag does not. Every routing call also takes the approval pin, in two halves:
**`--expect-target <name>`** (human-readable — catches a changed target name) and
**`--expect-fingerprint <hex>`** (the `resolution_fingerprint` each routed plan line carries — a
digest of target, tool, destination, recipients, sender, scope and mode, so a stack.yaml or plan
edit between approval and delivery that keeps the *name* while moving the channel, the list, the
sender, or the scope refuses instead of delivering). A name is not a resolution; the fingerprint is what the
human approved, and that is what makes "preview equals execution" a mechanism instead of a promise.

Selection itself is `effective_config.py --seam/--target`, called by that engine — never a second
resolver. Exit codes match the resolver's family (0 ok · 2 usage · 3 plan file missing · 4 malformed,
including a destination or recipient carrying shell metacharacters · 7 slot not configured ·
8 the declared value matches no target), plus one **extension**: **9 = the plan declares nothing for
this slot.** On every non-zero exit the emitted `target` and `destination` are `null`, so a caller
cannot lift a usable destination out of a failed routing.

A declaration is demanded when the slot holds `targets:` — **and for a tool-only chat seam**: a
single mapping that names the chat tool but declares no standing destination (no `default_channel`)
reads its `channel:` + `recipients:` from the plan's `chat:` block, authored per-communication, and
routing **halts (exit 9)** when the plan declares none — who a result goes to varies per analysis, so
it is asked at `/ship`, never a standing default. A single-mapping slot that DOES set a standing
destination still routes to itself and needs no plan file, so a repo on either shape behaves as it
did. The schema:

    schema_version: 1
    audience: internal                 # DECLARED by a person (in the spec, or at the /ship approval).
                                       # NEVER inferred from prose, channel names, or labels.
    classification: internal_archive   # docstore routing input, e.g. internal_archive | client_delivery
    chat:
      target: internal                 # chosen chat target (null for a single mapping / tool-only seam)
      channel: "#eng-updates"          # the destination — authored HERE for a tool-only seam (asked
                                       # at /ship), or the resolved echo when the seam holds `targets:`
      recipients: [Alice]              # the recipient list — authored here for a tool-only seam
                                       # (non-empty; never solo-DM), else the target's always_include
                                       # as applied (+ the shipper when include_self is set)
    docstore:
      target: archive                  # chosen docstore target (null when single)
      destination: "Shared drives/Tickets/ENG-1234 example-analysis"
      sharing_scope: team              # declared scope of the destination: team | org | external
    deliverables:                      # OPTIONAL: per-file classification, when one ticket holds
      - file: final_deliverables/summary.pdf     # both an internal working file and a client-facing
        classification: client_delivery          # one. A row's own declaration wins for that file;
                                                 # the plan-level `classification:` covers the rest.
                                                 # Rows are schema-checked: `file` + optional
                                                 # `classification`, both non-empty strings — a row
                                                 # with `classification: null`/[]/"" or an unknown
                                                 # key is exit 4, NEVER a silent fallthrough to the
                                                 # plan-level value. Paths are normalized before
                                                 # matching (`./a.csv` and `a.csv` are one file).
    delivered:                         # one row per delivered file, appended at delivery time
      - file: final_deliverables/results_1234rows.csv
        docstore_target: archive       # recorded so link_for is ALWAYS called against the same store
        url: "https://example.invalid/d/abc123"

Rules (these are the contract, not commentary):

- **The plan-level `classification:` is a FOLDER-WIDE statement.** `/ship`'s backup copies the
  whole ticket folder — `qc_queries/`, `exploratory_analysis/`, everything not split out by a
  `deliverables:` row — so declaring `client_delivery` at plan level sends ALL of it to the
  client-scoped store, not just the files you were thinking about. Split the internal files out
  with rows (or keep the plan level internal and split the client-facing files out) before
  declaring an external classification for the ticket.
- **Audience and classification are declarations, not inferences.** When more than one target is
  configured and no declaration exists, routing HALTS — the never-fall-back rule above, applied at
  the initial resolution, because the fall-through target may be the external one.
- **`sharing_scope` is declarative.** The kit verifies a docstore's mount (`test -d`), never a
  destination's real sharing ACL — correct target *selection* is not proof the folder's actual
  permissions match the declared classification. That is unmanaged infrastructure; a reader must
  not infer protection the kit does not provide.
- **Each chat target declares its own audience, channel, and `always_include`**, applied after
  routing and never inherited from another target. The non-empty-`always_include` requirement binds
  only when `targets:` is present — a single-target chat seam that omits it keeps validating.
- **Seam-level `default_channel` / `default_mode` under `targets:`** are inherited by targets that
  do not define their own (the standard inheritance rule) and are never a silent fallback when
  routing fails. Inheritance stays true of the resolved *values*; what a **routable** target may not
  do is rely on it for its destination — the audit below requires each target to name its own, so an
  inherited channel can never be where a routed message lands.

**The rules `bin/verify_stack.sh` ENFORCES** (each binds only when that slot declares `targets:`;
`--audit` is the same check, and a finding fails the verify run — this list is not advice):

| Rule | Slot | Why it fails rather than warns |
|---|---|---|
| each target declares its own `audience:` / `classification:` | chat / docstore | it is the routing key; an undeclared target is unreachable |
| that value is unique across the slot's targets | chat / docstore | a duplicate makes selection ambiguous, and silently so |
| no `audience:` / `classification:` at slot level | chat / docstore | a slot-level scalar is inherited, and a routing key must never be |
| each target declares its own non-empty `always_include:` | chat | the never-solo-DM list, applied after routing; `[]` is worse than absent because it reads as a decision |
| each target names its own destination key | chat / docstore | two targets sharing one inherited channel is a separation that does not exist |
| no two targets resolve to the same tool + destination | chat / docstore | same reason, stated the other way |
| each target declares `sharing_scope:` (`team`/`org`/`external`) | docstore | `/ship` prints it for authorization; an undeclared scope makes that line unanswerable |
| no destination or recipient carrying shell metacharacters | chat / docstore | the tier-3 injection refusal, inherited from the resolver rather than re-derived |

A slot-level `always_include:` under `targets:` **warns**: lists are not inherited, so it is dead
config that reads as protection. A docstore whose `default:` names its `external` target also warns —
routing never reads `default:`, but every pre-routing reader displays it.

**Which key holds a destination is the adapter's to declare**, following `dev_key:` /
`container_key:`: chat adapters carry `channel_key:` (Slack `default_channel`, Teams `channel`,
Gmail/Outlook `to` — ONE address string, a person or a distribution list; extra recipients belong in
`always_include`, where each is validated and printed individually), docstore adapters carry
`destination_key:` (`drive_folder` for the mounted stores, `remote_path` for `rclone` — always the
team-owned half, so the check does not vary by whose machine it runs on; the per-machine half,
`mount_root` or the rclone `remote` name, is composed into `base_path` by the resolver and is what
makes the routed destination — and therefore the `resolution_fingerprint` — move when someone
re-points a personal alias after an approval). A chat adapter whose medium has a first-class sender — the
email adapters — additionally carries **`sender_key:`** (Gmail/Outlook `identity`): routing surfaces
that value as `sender` on the routed plan line, REFUSES a named target whose sender key resolves to
nothing (mail must not go out as whoever the transport happens to be authenticated as), refuses a
shell-unsafe value, and folds it into the `resolution_fingerprint` — so a post-approval config edit
swapping one shared mailbox for another refuses exactly like a moved channel. The value is
inheritable from the slot on purpose (one shared identity serving two audiences is normal, unlike a
shared destination). Adapters without `sender_key:` are unaffected: `sender` stays null. Skills never name either key, and an adapter declaring a key
name that is not a plain config key is refused rather than guessed at: adapter frontmatter is
repo-supplied input, not documentation.

**What is MECHANICAL here, and what is instruction.** Worth stating plainly rather than implying
parity. Mechanical: `bin/delivery_plan.py` refuses to emit a target for an undeclared, unmatched or
ambiguous value; it refuses an inherited destination, an empty recipient list, and a shell-unsafe
value; `--expect-target` refuses a target other than the approved one; and `bin/verify_stack.sh`
fails a config breaking the table above. Instruction: that `/ship` *calls* those commands, and passes
`--expect-target` after the approval gate. Skills are prose an agent executes, so nothing stops an
agent — or a person — from invoking a chat adapter directly and skipping the router. The pin is
binding when used, not an unavoidable runtime guard. `--chat <target>` is likewise a deliberate,
visible exception to declaration-only delivery: it routes, it warns when it contradicts the ticket,
and it says the routing is not recorded.

**What this does NOT cover.** The kit verifies that a docstore destination *exists* (`test -d`) and
never inspects its real sharing ACL, so a correctly routed file is not evidence that the folder's
permissions match the declared `sharing_scope`. `--check-draft` reads the DRAFT TEXT and proves the
message names every routed recipient; the match is a **case-insensitive substring**, so an
incidental mention of a recipient's name satisfies it — it proves the name appears, not that the
person is addressed — and it cannot see what the chat API finally delivers, or who else
can read the room. Both are unmanaged infrastructure — do not infer protection the kit does not
provide.

### Resolving the dev target

`dev_target` on the resolved target, else the key named by that target's adapter `dev_key:`
frontmatter. Adapters spell their own legacy key; skills never name one.

### Cross-target work is out of scope

Routing a query to the right warehouse is this kit's job. Joining data *across* warehouses is not,
and the boundary is deliberate: moving rows between them is a write subject to
`db_write_requires_approval`, the extract side is a governance decision the kit has no vocabulary
for (note `pii_role` is a *per-target* key), and a hand-rolled bridge breaks `deterministic_outputs`.
A team that genuinely needs it already has federation configured in the warehouse, where the
federated objects are reachable from one target and need no support here.

The supported shape is two single-target queries → two exports → an explicit local combine step,
documented in the spec, whose reconciliation is a validation gate.

## Adapters shipped

Pick the one matching your stack (or copy the closest as a starting point). All implement the full
verb contract for their seam:

- **tracker:** `jira`, `azure-devops` (Azure Boards), `linear`, `asana`, `monday`, `github-issues`,
  `local` (**no tracker at all** — the ticket folder itself; pair with `project.id_mode: slug`)
- **warehouse:** `snowflake`, `bigquery`, `databricks`, `postgres`, `redshift`, `synapse` (also Azure SQL / SQL Server / Fabric)
- **chat:** `slack`, `teams`, `gmail`, `outlook` (email is a chat **target**, not a seam of its own —
  same four verbs, destination key `to`, `always_include` rendered as visible Cc, draft-first;
  each adapter's frontmatter states the mapping's rough edges honestly)
- **docstore:** `gdrive`, `sharepoint`, `rclone` (mountless — Drive/OneDrive/Dropbox/S3/Box via the rclone CLI)
- **meetings** *(optional)*: `zoom`, `fireflies`, `granola` (local notes cache — credential-free),
  `teams` (Graph transcripts; AI insights need Copilot licensing — the adapter says so), `notion`
  (meeting-notes pages via a Notion MCP)
- **vcs:** `github`, `gitlab`, `azure-repos`
- **viewer** *(optional)*: `macos-open`, `xdg-open`, `windows-start` — pick the one for your OS
- **runtime** *(capability declarations, not a tool seam)*: `claude-code`, `codex-cli`, `cursor`,
  `antigravity` (Google; aliased `gemini-cli`), `opencode`, `devin` (aliased `windsurf`), `cline`
  — see below

Don't see your tool? Adding one is a single file — see "Writing a new adapter" below. Seven worked
`stack.yaml` configs ship — Jira/Snowflake/Slack/Drive/GitHub, Asana/BigQuery/Teams/SharePoint/GitLab,
Azure DevOps/Synapse/Teams **+ Outlook email**/SharePoint/Azure Repos, Snowflake **+** Databricks
(two warehouse targets in one seam), **Slack + Teams + Gmail and Drive + SharePoint** (three
audiences in one repo — internal, client, and stakeholders-by-email — routed by a declared
audience), a repo with **no warehouse seam** (document/report deliverables), and a solo repo
with **no tracker and no chat/docstore**. The same skills run against all seven, unedited — which is
the claim those configs exist to keep honest.

> **MCP-transport adapters** (Asana, Linear, Monday, Teams, Slack, Gmail, Outlook, and the
> meetings seam's Fireflies / Teams / Notion / Zoom-MCP routes) reference each operation with a
> server-namespaced placeholder like `mcp__<server>__<op>`. The exact tool name + parameters depend on
> your connected MCP server — confirm them once and adjust the adapter (never the skills).

## Runtime adapters — the directory that has no verbs

`adapters/runtime/` is the eighth adapter directory and the second that is **not** a `stack.yaml`
seam. It answers a different question from every other directory here: not "which tool fills this
slot for the project", but "which agent is running right now, and what can it actually do".

That difference is the reason it has no verb contract. A seam is something the PROJECT depends on and
the whole team shares, so it is resolved per repo and written to committed config. Which agent a
given person happens to be running is per-machine — two teammates on the same repo may be on
different ones — so it is never a `stack.yaml` entry. Runtime adapters declare capabilities in
frontmatter instead, and `bin/kit_paths.py` reads them:

```yaml
skills_root:  session_start:  tool_gate:  subagents:  structured_questions:
model_cmd:  model_sandbox:  detect_env:
gate_ask_tier:  gate_fail_mode:  subagent_isolation:  reads_foreign_skills:  global_skills_root:
hook_wiring:  hook_protocol:  hook_wiring_caveat:  # + rules_root: on runtimes that don't read AGENTS.md
```

`tool_gate` is the load-bearing one — it records whether that harness can intercept a command before
it runs, which is what decides whether `db_write_requires_approval` is mechanically enforced or is
guidance the model can forget. A value of `unknown` is a real answer and is treated as the floor: no
capability is assumed.

`gate_ask_tier` and `gate_fail_mode` refine that axis and are deliberately separate: whether a gate
can *ask* a human and how it behaves when the hook *errors* are independent properties (the richest
gate researched has no session hook; a runtime with a session hook has a gate that fails open by
documented design), so nothing may average them into a single capability score. `gate_fail_mode`
records the runtime's NATIVE default, not the installed state. Per-runtime values with footnoted
caveats: `docs/runtimes.md` § "The matrix, machine-readable".

`hook_wiring`, `hook_protocol` and `hook_wiring_caveat` drive the hook installer (PROMPT 7 / U3).
`hook_wiring` is the artifact `ticketwright install` emits for the DB-write guard — a documented
hooks-config file (`.cursor/hooks.json`, `.agents/hooks.json`), a documented plugin file
(OpenCode), `native` (Claude Code — nothing is ever emitted under `.claude/`), or `unknown` (the
protocol may be documented while the config location is not; the installer then prints the manual
wiring line instead of guessing a path). `hook_protocol` selects which schema
`bin/hook_shim.py` speaks (`codex-json`, `cursor-json`, `agy-json`, `exit-code`, `claude-json` =
refused, `unknown` = refused). `hook_wiring_caveat` is the one-line honesty statement the install
report prints verbatim (trusted-by-hash, documented fail-open, …). `rules_root` (cline only today)
names a runtime's always-loaded rules surface when it is NOT `AGENTS.md`, so the enforcement table
is emitted where that runtime's users actually read. Values are pinned by selftest section 43.

`model_cmd` and `model_sandbox` are a pair. The first is the headless one-shot command
`bin/enrich_ticket.py` runs; the second records whether that command is *restricted*, because the
prompt it receives is a ticket README — tracker-sourced text on most installs. Only a small allowlist
of model CLIs may appear as `model_cmd`'s first word: adapters live inside the repo on a vendored
install, and a markdown file reads as inert in review, so without that allowlist a `model_cmd:` line
would be an easy place to hide an arbitrary command. The evidence behind every value, with sources and access dates, is in
[docs/runtimes.md](../docs/runtimes.md).

**So the two rules below do not apply to this directory:** there are no verb sections to implement,
and there is no `stack.yaml` seam entry to add. Everything else — the frontmatter keys, the
tool-neutrality rule for skills — is unchanged.

## Writing a new adapter

*(For a **tool** seam. A `runtime` adapter skips steps 3 and 4 — see the section above.)*

1. Copy the closest reference adapter in the same seam.
2. Keep the frontmatter keys (`seam`, `tool`, `transport`, `requires`, `user_keys`, `auth`; a chat
   adapter also carries `channel_key:` and a docstore adapter `destination_key:`, naming the key
   THIS tool uses for its destination — without it the tool cannot be a named delivery target; a
   chat adapter whose medium has a first-class sender also carries `sender_key:`, see above).
   `requires:` is
   ENFORCED, not decorative: `bin/verify_stack.sh` reads it and warns for every listed key the seam
   does not set. List exactly the keys the adapter cannot work without — a key named here that the
   adapter merely *prefers* produces a warning on a perfectly good config. Keys the adapter reads
   optionally belong in the trailing comment, not the list.
3. Implement **every** verb section for that seam — if the tool can't do one, say so and give the
   manual fallback (skills will surface it rather than silently skipping).
4. Add a `verify` command to your `stack.yaml` seam entry (read-only, exits non-zero when unreachable).
5. Run `bash bin/verify_stack.sh` — it confirms each seam's adapter file exists and runs the seam's
   read-only `verify` to check reachability. (`bash bin/selftest.sh` checks verb coverage vs. this contract.)

**A new `meetings` adapter** (Otter, Fathom, Gong, …) follows the same five steps with three
seam-specific rules: implement exactly the three read-only verbs (`fetch_transcript`,
`search_meetings`, `fetch_action_items` — a provider with no native action-item export declares
`status: no_native_export` statically in that verb's section, never at runtime); carry the
transcript-privacy rule verbatim in the `fetch_transcript` section, plus the honesty sentence
naming the mechanical gates and their shape-not-meaning limit (copy both from any shipped meetings
adapter); and declare only credentials/local paths in `user_keys:` — a meeting id never appears in
config, because it arrives per-ticket via `meeting_ref:` (grammar in `stack.schema.md`, validated
by `bin/meeting_refs.py`). Any other provider is one documented file — no skill edits.

### `## Permission posture (MCP)` — required when `transport:` is `mcp` or `both`

On the MCP transport the kit's shell hooks cannot see the traffic, so a policy's enforcement moves
into the tool's own permission controls — and the adapter is where the kit says so. Every adapter
whose frontmatter declares `transport: mcp` or `both` carries a `## Permission posture (MCP)`
section with exactly three `###` parts (selftest section 51b pins the structure and lints the
probe):

1. **`### Native control`** — where the control lives for the MCP path (the connection's role, the
   token's scope, the connector's OAuth grants, the server's own config), covering all three
   connection shapes: official connector (its app settings), CLI-configured server (its config
   file), homegrown (its owner — the posture becomes a suggestion to forward).
2. **`### Recommended setting (by policy)`** — written against the policy names
   (`db_write_requires_approval`, `chat_default_draft`, `hard_halt_before_external_posts`), never
   restated rules.
3. **`### Read-only probe`** — a fenced code block holding read-only introspection or a read call
   (never a mutation, never a bare enumeration that prints secrets — the names-only precedent).
   The fence is linted against the SQL mutation denylist; explanatory prose around it may name
   write-class grants freely.

**NATIVE (tool-side) needs a comparison rule.** The rendered AGENTS.md posture table may claim
NATIVE for a policy only where the probe is a genuine read-only privilege *introspection* AND the
adapter states the comparison rule that turns a probe result into `matches` / `exceeds-policy` /
`unverified` (today: the warehouse adapters). Seams whose grant sets cannot be introspected from
inside a session — chat and tracker connectors — cap at `unverified`, stay GUIDANCE in the table,
and their posture sections must say so plainly, pointing at the settings surface where a human
confirms the grant. Setup records every outcome in gitignored
`.claude/config/posture.local.yaml` (display-only; never resolver-merged).

### `user_keys:` — which of this tool's keys are PERSONAL

`stack.yaml` is committed and shared, so a value that is true only on one machine must not live
there. `user_keys:` is how an adapter declares which of its config keys a person may override from
`.claude/config/connections.local.yaml` (tier 3, gitignored):

```yaml
user_keys: [profile]      # a named profile from the tool's own local config file
```

Rules for choosing them:

- **Credentials and local paths only.** A key that selects WHICH DATA is read — `catalog`, `schema`,
  `database`, `dataset`, `warehouse_id`, a workspace host — is team-owned, full stop. Two teammates
  must never silently read different data, so those keys are RESERVED and the resolver refuses to
  let any adapter declare them.
- **Not the same list as `requires:`.** `requires:` is a minimum-capability declaration; a tool can
  require a CLI and still take all its data-selection settings from the team.
- **Empty is a real answer.** Most tools keep credentials outside config entirely — an environment
  variable, a credentials file, an `auth login` session. Declare `user_keys: []` and say why in a
  comment rather than inventing a personal key.
- **Split a mixed key instead of declaring it.** A value that is half team decision and half machine
  path (a docstore's `base_path`) should become two keys — the team half in `stack.yaml`, the machine
  half in tier 3 — rather than becoming personal wholesale.

`bin/verify_stack.sh` warns when a committed `stack.yaml` sets one of these keys to a literal, and
when a machine-local value is hardcoded into a `verify:` string instead of a `{token}`.

**Rule:** adapters may name concrete tools/CLIs/IDs freely. **Skills may not.** `bin/selftest.sh`
(section 3) enforces this: it greps `.claude/skills/**` + `.claude/commands/**` for tool names, with
two sanctioned exceptions (the CLI-detection probe in `setup` and the self-lint line in
`skillify`).
