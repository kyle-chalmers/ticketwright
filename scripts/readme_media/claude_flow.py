"""Scenes for demo.gif: one ticket through Ticketwright, as it happens in a Claude Code chat.

This is a rendered walkthrough, not a screen recording, and the README caption says so. The words
come from the skills' own say-this text and outputs (the review verdict line, the delivery plan,
the plan approval), condensed, with the kit's invented orders-and-returns example: alice's TEST-130
builds on bob's TEST-118, as in the README's repo tree. Scene text is HTML built here;
render_gif.py screenshots and stitches it. Edit STEPS when a skill's wording changes.
"""

from __future__ import annotations

import html
import re
from dataclasses import dataclass, field

REPO_NAME = "team-analytics"

CSS = """
  .app { position:absolute; top:56px; left:24px; right:24px; bottom:20px; border-radius:10px;
    overflow:hidden; background:#262624; color:#ECEAE4;
    box-shadow:0 18px 50px rgba(0,0,0,.6), 0 0 0 1px rgba(245,245,245,.08); }
  .app .bar { background:#1F1E1D; color:#A8A49B; }
  .side { position:absolute; top:30px; left:0; bottom:0; width:176px; background:#1F1E1D;
    border-right:1px solid #34332F; padding:12px 10px; box-sizing:border-box; font-size:12.5px; }
  .side .new { border:1px solid #3D3C37; border-radius:8px; padding:7px 10px; color:#ECEAE4; }
  .side h6 { margin:16px 4px 6px; font-size:10.5px; font-weight:600; color:#7D7A72;
    text-transform:uppercase; letter-spacing:.06em; }
  .side .s { padding:7px 10px; border-radius:7px; color:#A8A49B; white-space:nowrap;
    overflow:hidden; text-overflow:ellipsis; }
  .side .s.on { background:#34332F; color:#ECEAE4; }
  .main { position:absolute; top:30px; left:176px; right:0; bottom:0; }
  .feed { position:absolute; top:0; left:0; right:0; bottom:66px; padding:10px 34px 8px;
    display:flex; flex-direction:column; justify-content:flex-end; gap:10px; overflow:hidden; }
  .feed > * { flex-shrink:0; }
  .u { align-self:flex-end; max-width:72%; background:#3A3935; border-radius:14px;
    padding:8px 13px; font-size:14px; line-height:1.4; }
  .u code, .c code { font-family:"JetBrains Mono","DejaVu Sans Mono",Menlo,monospace;
    font-size:12.5px; color:#F0B49C; }
  .c { display:flex; gap:10px; font-size:14px; line-height:1.45; max-width:94%; }
  .c .mark { color:#D97757; font-size:17px; line-height:19px; flex-shrink:0; }
  .c b { color:#FFFFFF; font-weight:600; }
  .tools { display:flex; flex-direction:column; gap:4px; margin-left:27px; }
  .tool { display:flex; align-items:center; gap:8px; font-size:12.5px; color:#B9B5AC;
    font-family:"JetBrains Mono","DejaVu Sans Mono",Menlo,monospace; }
  .tool .st { width:14px; text-align:center; font-weight:700; }
  .tool .st.ok { color:#5BBF77; } .tool .st.run { color:#D97757; }
  .tool .k { color:#7D7A72; }
  .ask { margin-left:27px; border:1px solid #4A4843; border-radius:10px; padding:10px 12px;
    background:#2C2B28; max-width:80%; }
  .ask .h { display:inline-block; font-size:10.5px; font-weight:700; letter-spacing:.05em;
    text-transform:uppercase; color:#1F1E1D; background:#e47d5b; border-radius:4px;
    padding:1px 6px; margin-bottom:6px; }
  .ask .q { font-size:13.5px; margin-bottom:7px; }
  .ask .o { font-size:12.5px; color:#B9B5AC; border:1px solid #3D3C37; border-radius:7px;
    padding:5px 9px; margin-top:4px; }
  .ask .o.pick { border-color:#e47d5b; color:#ECEAE4; background:rgba(228,125,91,.12); }
  .wire { margin-left:27px; font-family:"JetBrains Mono","DejaVu Sans Mono",Menlo,monospace;
    font-size:12px; line-height:1.55; color:#CFCBC2; background:#1F1E1D; border-radius:8px;
    padding:8px 12px; white-space:pre; }
  .wire b { color:#c4ff00; font-weight:600; }
  .composer { position:absolute; left:34px; right:34px; bottom:14px; height:42px;
    border:1px solid #45443F; border-radius:12px; background:#30302D; display:flex;
    align-items:center; padding:0 8px 0 14px; font-size:14px; }
  .composer .ph { color:#7D7A72; }
  .composer .send { margin-left:auto; width:28px; height:28px; border-radius:8px;
    background:#D97757; color:#1F1E1D; display:flex; align-items:center;
    justify-content:center; font-weight:700; font-size:15px; }
  .composer .send.off { background:#4A4843; color:#7D7A72; }
  .caret { display:inline-block; width:2px; height:17px; background:#ECEAE4;
    vertical-align:-3px; margin-left:1px; }
"""

# Anything that would identify a real person, machine or organization must never reach a frame.
# The industry terms mirror selftest section 13b, which keeps the kit's examples invented.
_LEAKS = re.compile(
    r"/Users/|/home/|\b[\w.+-]+@(?!example\.(?:com|org|net)\b)[\w-]+\.[\w.]+"
    r"|(?i:(^|[^a-z])(loan|borrower|delinquen|charge.?off|fico|underwrit|servicing|disburse"
    r"|repayment|payoff|lender|policyholder|claimant|patient|diagnos[ei]s|genesys|talkdesk|five9"
    r"|(dpd|refi)([^a-z]|$)))"
)


def check_clean(markup: str) -> None:
    """Refuse a scene that carries a home path, a real email or industry vocabulary.

    Image sources are local file URIs that never appear on screen, so they are skipped.
    """
    hit = _LEAKS.search(re.sub(r'src="[^"]*"', "", markup))
    if hit:
        raise SystemExit(f"refusing to render a frame containing {hit.group(0)!r}")


# ---------- chat items ----------------------------------------------------------------


def user(text: str) -> str:
    return f'<div class="u">{_inline(text)}</div>'


def claude(markup: str) -> str:
    return f'<div class="c"><span class="mark">&#10043;</span><div>{markup}</div></div>'


def tools(rows: list[tuple[str, str, str]]) -> str:
    """rows: (state, kind, label) with state "ok" or "run"."""
    out = []
    for state, kind, label in rows:
        mark = "&#10003;" if state == "ok" else "&#9680;"
        out.append(
            f'<div class="tool"><span class="st {state}">{mark}</span>'
            f'<span class="k">{html.escape(kind)}</span>{html.escape(label)}</div>'
        )
    return f'<div class="tools">{"".join(out)}</div>'


def ask(header: str, question: str, options: list[str], pick: int | None = None) -> str:
    opts = "".join(
        f'<div class="o{" pick" if i == pick else ""}">'
        f"{'&#10003; ' if i == pick else ''}{html.escape(o)}</div>"
        for i, o in enumerate(options)
    )
    return (
        f'<div class="ask"><div class="h">{html.escape(header)}</div>'
        f'<div class="q">{html.escape(question)}</div>{opts}</div>'
    )


def wire(text: str) -> str:
    """A monospace block; **word** renders lime."""
    body = re.sub(r"[*][*](.+?)[*][*]", r"<b>\1</b>", html.escape(text))
    return f'<div class="wire">{body}</div>'


def _inline(text: str) -> str:
    """Escape text, rendering a leading /command as code."""
    m = re.match(r"(/[\w:-]+)(.*)", text, re.S)
    if not m:
        return html.escape(text)
    return f"<code>{html.escape(m.group(1))}</code>{html.escape(m.group(2))}"


# ---------- frames --------------------------------------------------------------------


def caption(n: int | str, title: str, sub: str) -> str:
    return (
        f'<div class="caption"><span class="n">{n}</span>{title}'
        f'<span class="sub">{sub}</span></div>'
    )


def chat_frame(cap: str, feed: list[str], typed: str | None = None) -> str:
    if typed is None:
        composer = (
            '<span class="ph">Reply to Claude&hellip;</span><span class="send off">&uarr;</span>'
        )
    else:
        composer = (
            f'<span>{_inline(typed)}</span><span class="caret"></span>'
            '<span class="send">&uarr;</span>'
        )
    return (
        cap + '<div class="app"><div class="bar"><i></i><i></i><i></i>'
        f'<span class="t">{REPO_NAME}</span></div>'
        '<div class="side"><div class="new">+ New session</div><h6>Sessions</h6>'
        '<div class="s on">TEST-130 returns by region</div><div class="s">TEST-127 regions</div>'
        '<div class="s">Set up Ticketwright</div></div>'
        f'<div class="main"><div class="feed">{"".join(feed)}</div>'
        f'<div class="composer">{composer}</div></div></div>'
    )


# ---------- the story -----------------------------------------------------------------


@dataclass
class Step:
    """One turn in the chat: an optional typed prompt, then items added (or replacing the last)."""

    n: int
    title: str
    sub: str
    prompt: str
    beats: list[tuple[str, str, float]] = field(default_factory=list)

    @property
    def cap(self) -> str:
        return caption(self.n, self.title, self.sub)


RECALL = """ranked prior work for TEST-130
**TEST-118**  returns baseline       bob     ORDERS, RETURNS
TEST-127  region mapping        alice   REGIONS
TEST-094  order volume weekly   bob     ORDERS"""

PYRAMID_RUN = [
    ("run", "① dialect lint     ", "01_returns_by_region.sql"),
    ("run", "② counts & dedup   ", "re-running"),
    ("run", "③ reconciliation   ", "against RETURNS"),
    ("run", "④ independent run  ", "diffing the CSV"),
]
PYRAMID_OK = [
    ("ok", "① dialect lint     ", "0 findings"),
    ("ok", "② counts & dedup   ", "1,284 rows = 1,284 distinct"),
    ("ok", "③ reconciliation   ", "totals match the source"),
    ("ok", "④ independent run  ", "byte-identical CSV"),
]

DELIVERY = """Delivery plan for alice/TEST-130. Nothing has been sent yet.
Documents  drive   backed up to Analytics/TEST-130
Ticket     jira    comment on TEST-130
Chat       slack   #returns-analytics, as a draft
Code       github  branch TEST-130, and a pull request opens"""

STEPS = [
    Step(
        1,
        "/ticket",
        "opens the ticket with the closest prior work already ranked",
        "/ticketwright:ticket TEST-130",
        [
            (
                "add",
                tools(
                    [
                        ("run", "fetch_ticket ", "TEST-130  Returns by region, Q3"),
                        ("run", "recall ", "ORDERS, RETURNS, region"),
                    ]
                ),
                0.6,
            ),
            (
                "set",
                tools(
                    [
                        ("ok", "fetch_ticket ", "TEST-130  Returns by region, Q3"),
                        ("ok", "recall ", "3 related tickets from 2 owners"),
                    ]
                ),
                0.5,
            ),
            ("add", wire(RECALL), 1.6),
            (
                "add",
                claude(
                    "Bob's <b>TEST-118</b> already built the returns baseline. Reusing its grain "
                    "and its QC checks. <b>Plan written</b>: 3 queries, 5 checks, 4 assumptions."
                ),
                1.4,
            ),
            (
                "add",
                ask(
                    "Approve the plan",
                    "Build TEST-130 from this plan? Nothing is built until you say so.",
                    ["Approve (Recommended)", "Change something"],
                ),
                1.0,
            ),
            (
                "set",
                ask(
                    "Approve the plan",
                    "Build TEST-130 from this plan? Nothing is built until you say so.",
                    ["Approve (Recommended)", "Change something"],
                    0,
                ),
                0.8,
            ),
        ],
    ),
    Step(
        2,
        "/build",
        "runs the approved plan in fresh context",
        "/ticketwright:build",
        [
            (
                "add",
                tools(
                    [
                        ("run", "query ", "01_returns_by_region.sql"),
                        ("run", "qc ", "checks 1 to 5"),
                    ]
                ),
                0.7,
            ),
            (
                "set",
                tools(
                    [
                        ("ok", "query ", "01_returns_by_region_1284rows.csv"),
                        ("ok", "qc ", "5 of 5 checks recorded"),
                    ]
                ),
                0.6,
            ),
            (
                "add",
                claude("Built. Handing it to <b>/review</b> for an independent check."),
                1.0,
            ),
        ],
    ),
    Step(
        3,
        "/review",
        "re-runs every query and walks the validation pyramid",
        "",
        [
            ("add", tools(PYRAMID_RUN), 0.9),
            ("set", tools(PYRAMID_OK), 0.9),
            (
                "add",
                claude(
                    "Layers 1 to 4 pass. <b>Your turn:</b> the CSV and the QC queries are open in "
                    "your own apps."
                ),
                1.2,
            ),
            (
                "add",
                ask("Sign-off", "Do the numbers look right to you?",
                    ["They look right", "Something is off"]),
                0.9,
            ),
            (
                "set",
                ask("Sign-off", "Do the numbers look right to you?",
                    ["They look right", "Something is off"], 0),
                0.7,
            ),
            (
                "add",
                claude(
                    "Review result: <b>APPROVE</b>. Counts, duplicates, reconciliation and an "
                    "independent re-run all checked."
                ),
                1.6,
            ),
        ],
    ),
    Step(
        4,
        "/ship",
        "shows exactly what it will send, then stops",
        "/ticketwright:ship",
        [
            ("add", wire(DELIVERY), 2.4),
            (
                "add",
                claude("Reply <b>go ahead</b> to deliver exactly this plan, or tell me what "
                       "to change."),
                1.2,
            ),
        ],
    ),
    Step(
        5,
        "Delivered",
        "and filed into the team brain for the next ticket",
        "go ahead",
        [
            (
                "add",
                tools(
                    [
                        ("ok", "backup ", "Analytics/TEST-130"),
                        ("ok", "comment ", "TEST-130"),
                        ("ok", "draft ", "#returns-analytics (not sent)"),
                        ("ok", "commit ", "pull request opened"),
                        ("ok", "index ", "INDEX.md, OBJECTS.md, graph"),
                    ]
                ),
                1.0,
            ),
            (
                "add",
                claude(
                    "Delivered. The chat message waits in drafts for you. <b>TEST-130</b> is now "
                    "linked to TEST-118, so the next ticket on returns starts here."
                ),
                2.0,
            ),
        ],
    ),
]
