# What Percolate is

Percolate is an AI workflow engine that lives inside PostgreSQL. Workflow
state, agent conversations, identity and permissions, and graph and semantic
queries are all tables and functions in your database, rather than state held
by a control plane that talks to your database.
{: .lede }

The nice consequence of that is that most steps need no process at all. A step
is `sql`, `p8ql`, `rest`, `agent` or `work`. The first two run inside Postgres
as soon as the steps they depend on finish, in the same transaction that
finishes them. Only `rest` and `agent` leave the machine, and only `work` runs
code you wrote. So a pipeline made of queries and graph updates completes with
nothing running anywhere.

Here is a small one:

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

`define_yaml` compiles that into rows and `start_workflow` runs it. Three rows,
not two: `SEARCH` ranks against a vector, and producing one is a model call. So
`retrieve` becomes a queued task that embeds the question and a query step that
consumes it, and only the query step runs inside the database. `classify` is
queued too. Nobody writes the embed step — the endpoint comes from the model
registry, and the model is written into the query so the vector and the space
being searched cannot be two different models.

## Three ideas everything else follows from

### The database never blocks on HTTP

There is no HTTP client extension installed. When a step needs the network it
becomes a row, `pg_notify` nudges a worker, and the worker is the thing that
blocks. If the database made the call itself it would hold a backend and an
open transaction for the length of somebody else's latency, so a slow model
endpoint would cost you connection slots instead of worker capacity.

This one decision shapes most of the rest. It is why there is a worker at all,
why `mode: async` exists, and why an agent step turns out to be an ordinary
REST call with the URL filled in for you.

### Fan-out needs no controller

A `matrix` step expands a query result into N children in the transaction that
completes it, and rewires whatever depended on the parent onto the children.

Argo does the equivalent with a controller pod that reads a JSON array, which
costs three processes and a serialisation round trip, and leaves a window where
the parent is `done` and the children do not exist yet. If the controller dies
in that window the fan-out is stranded with nothing to resume from. Here there
is no window, because there is no second step.

### No role is a superuser

A superuser bypasses row-level security completely, and so does a view owned by
the same role that owns the table. So `app_owner` owns the tables and functions
and `api_viewer` owns only the `*_api` views, which is what makes reads through
those views RLS-filtered.

Every schema checks this when it loads and refuses to install if it does not
hold. It is worth a check rather than a comment because if you get it wrong
every policy in the schema is still there and none of them do anything.

## What it costs

The pitch above is one-sided, so:

| | |
|---|---|
| **PostgreSQL 19** | SQL/PGQ property graphs are a PG19 feature and the query parser is compiled against its ABI, so there is no graceful fallback to 18. PG19 is in beta. |
| **A compiled extension** | `percolate_parser` is Rust. We publish builds for linux/amd64, linux/arm64 and macos/arm64; anything else you build yourself. |
| **Your database is in the path** | Workflow state in Postgres means workflow throughput is bounded by your Postgres. At this scale that is usually the right trade, but it is a real one. |
| **Not a hosted product** | There is no dashboard and no SaaS. The management surface is the same RPC set a worker uses, over PostgREST. |

## How this documentation is written

Everything here was run against a live database before it was written down.
Where something did not survive that, we changed the page rather than the
claim.

The chip at the top of each page tells you which of three states it is in:

| | |
|---|---|
| `proven` | we ran it, and there is an assertion behind it |
| `designed` | specified and reviewed, but not yet run end to end |
| `absent` | named because it is missing, since leaving it out would read as done |

Moving a page back to `designed` when something turns out to be unbuilt is a
normal edit.

[Install](install.html) is next, and after that
[your first workflow](first-workflow.html) walks a four-step pipeline through
from `define_yaml` to a completed run.
