# What Percolate is

An AI workflow engine that lives inside PostgreSQL. Workflow state, agent
conversations, identity and permissions, graph and semantic queries are tables
and functions in your database — not state held by a control plane that talks
to your database.
{: .lede }

The practical consequence is that **most steps need no process**. A step is
`sql`, `p8ql`, `rest`, `agent` or `work`. The first two run *inside* Postgres
the moment their dependencies complete, in the transaction that completes them.
Only `rest` and `agent` leave the machine, and only `work` runs code you wrote.
A pipeline of queries and graph updates finishes with nothing running anywhere.

```yaml
name: triage
steps:
  - id: embed
    rest: {url: '{{env.LLM_URL}}/api/embeddings', jsonpath: embedding}
  - id: retrieve
    needs: [embed]
    sql: {function: p8ql_vec, args: ['SEARCH "outage" FROM chunks LIMIT 3', '{{steps.embed.result}}']}
  - id: classify
    needs: [retrieve]
    agent: triage_bot
    input: 'Classify: {{steps.retrieve.result}}'
    output_schema:
      type: object
      required: [verdict]
      properties: {verdict: {type: string, enum: [SAFETY, FINANCE, OTHER]}}
```

`define_yaml` compiles that to rows. `start_workflow` runs it. `retrieve`
executes in the database; `embed` and `classify` become queued tasks a worker
picks up.

## Three ideas the whole thing rests on

### The database never blocks on HTTP

No HTTP client extension is installed, deliberately. A step that needs the
network becomes a **row**; `pg_notify` nudges a worker; the worker blocks, never
Postgres. A blocking call inside the database would hold a backend and a
transaction open for someone else's latency — a slow model endpoint would cost
you connection slots rather than worker capacity.

This is the one decision that shapes everything else. It is why there is a
worker at all, why `mode: async` exists, and why an agent step is an ordinary
REST call whose URL the compiler fills in.

### Fan-out has no controller

A `matrix` step expands a query result into N children **in the transaction that
completes it**, and rewires the successors onto the children. Argo does this
with a controller pod reading a JSON array; that costs three processes, a
serialisation round trip, and a window in which the parent is `done` and the
children do not exist — so a controller crash strands the fan-out with nothing
to resume from.

Here there is no window, because there is no second step.

### No role in the system is a superuser

Superusers bypass row-level security unconditionally, and so does a view owned
by the table owner. So `app_owner` owns tables and functions — the trusted
`SECURITY DEFINER` path — while `api_viewer` owns only the `*_api` views, which
means reads through them are RLS-filtered.

Every schema self-checks this at load time and **refuses to install** if it does
not hold. That check exists because the failure it prevents is silent: every
policy in the schema stays syntactically present and semantically inert.

## What it costs you

Worth stating plainly, because the pitch above is one-sided.

| | |
|---|---|
| **PostgreSQL 19** | SQL/PGQ property graphs are a PG19 feature and the query parser is compiled against its ABI. There is no graceful degradation to 18. PG19 is in beta. |
| **A compiled extension** | `percolate_parser` is Rust. Prebuilt for linux/amd64, linux/arm64 and macos/arm64; anything else you build yourself. |
| **Your database is load-bearing** | Workflow state in Postgres means workflow throughput is bounded by your Postgres. That is usually the right trade at this scale, and it is a real one. |
| **Not a hosted product** | No dashboard, no SaaS. The management surface is the same RPC set a worker uses, over PostgREST. |

## Where the pieces live

| | |
|---|---|
| [p8-subsystems](https://github.com/percolating-sirsh/p8-subsystems) | the specs and the schema — the source of truth, and the assertions behind every claim on this site |
| [percolate-core](https://github.com/percolating-sirsh/percolate-core) | the worker, Content Server and Agent Runtime |
| [get-percolate](https://github.com/percolating-sirsh/get-percolate) | the compose file, the Helm chart, and these docs |

The specs repository is unusual and worth knowing about: **every design claim in
it was run against a live database before being written down**, and the ones
that did not survive are recorded as corrections rather than quietly fixed.
`surface.sql` is an audit that checks each promised capability against a real
database and fails loudly. The status chip at the top of each page here means
the same thing.
