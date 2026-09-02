# What Percolate is

Percolate is an AI workflow engine that lives inside PostgreSQL. Workflow state,
agent conversations, identity and permissions, and graph and semantic queries are
all tables and functions in your database, rather than state held by a control
plane that talks to your database.
{: .lede }

The nice consequence of that is that most steps need no process at all. A step is
`sql`, `p8ql`, `rest`, `agent` or `work`. The first two run inside Postgres as
soon as the steps they depend on finish, in the same transaction that finishes
them. Only `rest` and `agent` leave the machine, and only `work` runs code you
wrote — so a pipeline made of queries and graph updates completes with nothing
running anywhere.

What we are trying to do here is retrieve from a corpus and have a model
classify what came back, in a document short enough to read at a glance.
{: .goal }

```yaml
name: triage
steps:
  - id: retrieve
    p8ql: 'SEARCH "outage" FROM chunks LIMIT 3'
  - id: classify
    needs: [retrieve]
    agent: triage_bot
    input: 'Classify: {{steps.retrieve.result}}'
    output_schema:
      type: object
      required: [verdict]
      properties: {verdict: {type: string, enum: [SAFETY, FINANCE, OTHER]}}
```

<details class="why" markdown="1">
<summary>Why it works — two authored steps become three tasks, and nobody writes
the third</summary>

`define_yaml` compiles that into rows and `start_workflow` runs it. Three rows
rather than two, because `SEARCH` ranks against a vector and producing one is a
model call: `retrieve` becomes a queued task that embeds the question plus a
query step that consumes it, and only the query step runs inside the database.
`classify` is queued too.

Nobody writes the embed step. The endpoint comes from the model registry, and
the model is written into the query so that the vector and the space being
searched cannot be two different models — a mistake that returns a number rather
than an error, and is therefore made a compile-time refusal instead.

<p class="related"><strong>Related</strong>
<a href="grammar-workflow.html#a-vector-query-is-two-tasks">the desugaring in
full</a> ·
<a href="first-workflow.html">a four-step pipeline end to end</a></p>
</details>

## Three ideas everything else follows from

### The database never blocks on HTTP

There is no HTTP client extension installed. When a step needs the network it
becomes a row, `pg_notify` nudges a worker, and the worker is the thing that
blocks.

<details class="why" markdown="1">
<summary>Why it works — the alternative costs connection slots instead of worker
capacity</summary>

If the database made the call itself it would hold a backend and an open
transaction for the length of somebody else's latency, so a slow model endpoint
would cost you connection slots rather than worker capacity.

This one decision shapes most of the rest. It is why there is a worker at all,
why `mode: async` exists, and why an agent step turns out to be an ordinary REST
call with the URL filled in for you.

<p class="related"><strong>Related</strong>
<a href="grammar-workflow.html#rest-steps-and-where-the-credential-lives">what a
`rest:` step carries</a> ·
<a href="failure.html">why the worker decides what retries</a></p>
</details>

### Fan-out needs no controller

A `matrix` step expands a query result into N children in the transaction that
completes it, and rewires whatever depended on the parent onto the children.

<details class="why" markdown="1">
<summary>Why it works — there is no window, because there is no second step</summary>

Argo does the equivalent with a controller pod that reads a JSON array, which
costs three processes and a serialisation round trip, and leaves a window where
the parent is `done` and the children do not exist yet. If the controller dies in
that window the fan-out is stranded with nothing to resume from.

Here the children are inserted by the statement that marks the parent done, so
the window does not exist to be lost in.

<p class="related"><strong>Related</strong>
<a href="cookbook.html#7-fan-out-over-a-query-result">a fan-out with its rows
captured</a> ·
<a href="grammar-workflow.html#matrix-the-work-to-do-is-a-query-result">every
matrix key</a></p>
</details>

### No role is a superuser

A superuser bypasses row-level security completely, and so does a view owned by
the same role that owns the table. So `app_owner` owns the tables and functions
and `api_viewer` owns only the `*_api` views, which is what makes reads through
those views RLS-filtered.

<details class="why" markdown="1">
<summary>Why it works — it is checked at load time, because getting it wrong
leaves every policy inert</summary>

Every schema checks this when it loads and refuses to install if it does not
hold. That is worth a check rather than a comment: if you get it wrong, every
policy in the schema is still there and none of them do anything.

It was found the hard way. With a superuser schema owner, a non-admin user
reading through `users_api` saw every row in the table — with correct policies in
place, and those same policies provably working on a direct read by the same role
in the same session. The test harness had been running as a superuser for that
schema's entire history and never caught it, because no test read through the
views as a non-owner until one was written specifically to.

<p class="related"><strong>Related</strong>
<a href="install.html#into-a-postgres-19-you-already-run">why the extension is
non-superuser installable</a> ·
<a href="query.html#over-rest-and-the-two-things-that-look-like-bugs">what it
looks like from a caller</a></p>
</details>

## Expressive, secure, scalable

Those are the three properties the design is answerable to, and **expressive** is
the load-bearing one. It is not a claim about syntax: the question is whether a
mixed collective of people, models and processes can have its coordination
written down, rather than forced into a request/response shape that has both the
latency and the authority the wrong way round.

What makes it possible is where the coordination lives. State is the substrate
and tools, models, sources and people attach to it at the edges — so a
[delegation is a row](agents.html#delegation-is-an-ordinary-tool-call) rather
than a stack frame, a [tool is an OpenAPI or MCP binding](agents.html) rather
than a function registered inside a process, a fan-out is [decided by a query
result](cookbook.html#7-fan-out-over-a-query-result) rather than by a controller
holding the plan, and [waiting for a
person](cookbook.html#8-wait-for-a-person-or-for-a-clock) is a row in
`waiting_external` with no process doing the waiting. **Secure** is that the
substrate enforces it and refuses to install when it cannot: the superuser rule
above is checked at load time, and the tools an agent may call, the rows a query
returns and the tasks a worker may claim are one RLS decision rather than an
authorization system per service. **Scalable** is that no component holds the
plan and the hot paths were [measured rather than asserted](scaling.html),
including the one that turned out to be two orders of magnitude slower than it
should have been.

<details class="why" markdown="1">
<summary>Why it works — the coordination problem is in one place rather than in
the seams between four systems</summary>

Multimodal query, workflow dynamics, conversation and ingestion are normally four
systems, and the coordination problem then lives in the seams between them. That
is where this class of system actually fails: a vector built by a different model
than the space it is ranked against, a citation pointing at a chunk that has
since been re-ingested, a workflow that cannot see the conversation that spawned
it, an approval that nothing recorded. In one database those seams are joins, and
some of the failures stop being expressible — [the embed step is written by the
compiler](grammar-workflow.html#a-vector-query-is-two-tasks) so the two models
cannot differ, and an agent's [citations are built from what its context actually
contained](agents.html) rather than from what the model says it used.

The human half is the same move. A scheduler that has to hold a policy about a
person who answers in six hours has three options and all three are bad: hold the
slot, time out, or escalate. When the decision is a row instead, the run waits
without occupying anything, `signal_task` checks who you are through the same
RBAC as every other call, and the approval is in the audit trail because making
it was a write.

<p class="related"><strong>Related</strong>
<a href="cookbook.html#8-wait-for-a-person-or-for-a-clock">an approval walked
through</a> ·
<a href="agents.html">an agent, its tools and who it may delegate to</a> ·
<a href="scaling.html">what the hot paths cost</a></p>
</details>

## What it costs

The pitch above is one-sided, so:

| | |
|---|---|
| **PostgreSQL 19** | SQL/PGQ property graphs are a PG19 feature and the query parser is compiled against its ABI, so there is no graceful fallback to 18. PG19 is in beta. |
| **A compiled extension** | `percolate_parser` is Rust. We publish builds for linux/amd64, linux/arm64 and macos/arm64; anything else you build yourself. |
| **Your database is in the path** | Workflow state in Postgres means workflow throughput is bounded by your Postgres. At this scale that is usually the right trade, but it is a real one. |
| **Not a hosted product** | There is no dashboard and no SaaS. The management surface is the same RPC set a worker uses, over PostgREST. |

## How to read these pages

Every page is built out of one repeating unit, and knowing the shape makes the
site much faster to skim.

<ol class="steps" markdown="1">
<li markdown="1">**The lesson** — a heading and a sentence or two saying what you are about to learn.</li>
<li markdown="1">**The example** — one line beginning *what we are trying to do here is …*, then the SQL or the YAML, then the output where we captured it.</li>
<li markdown="1">**Why it works** — the mechanism and the trade-off, collapsed. Open it when you want the reasoning; skip it when you want the next example.</li>
</ol>

Each of those collapsed blocks ends with links to the pages that own the
concepts it touched, so following the reasoning is also how you navigate.

Everything here describes what is shipped and running, and it was run against a
live database before it was written down. Where something did not survive that,
we changed the page rather than the claim.

There is no per-page status label, and its removal was deliberate. A page that
said "designed" was still a page on the site, and "designed" is indistinguishable
from "works" to anybody skimming. So a thing that is not built does not get a
page here — it gets a spec in
[p8-subsystems](https://github.com/percolating-sirsh/p8-subsystems). Gaps inside
a feature that *is* shipped are named where they bite, in the section they belong
to, rather than collected behind a label at the top.

[Install](install.html) is next, and after that [agents](agents.html) is the
shortest useful loop in the system: an agent is a specification, the
specification is a row, and the page walks writing one, saving it and calling it
over REST before it explains any of the reasoning. [Your first
workflow](first-workflow.html) then walks a four-step pipeline from `define_yaml`
to a completed run.
