<img src="docs/assets/logo.png" alt="" width="56" align="left" hspace="12">

# Percolate — an AI workflow engine in Postgres

Percolate is an AI workflow engine that lives inside PostgreSQL, so Postgres is
the system here rather than the backing store for one. Workflow state, agent
conversations, identity and permissions, and graph and semantic queries are all
tables, functions and native property-graph views in your own database. A step
written as `sql` or `p8ql` runs inside the database as soon as the steps it
depends on finish, so a pipeline made of queries and graph updates completes
with no process running anywhere; only outbound HTTP needs a worker.

<br clear="left">

```yaml
steps:
  - id: retrieve
    p8ql: 'SEARCH "outage causes" FROM chunks'
  - id: triage
    needs: [retrieve]
    agent: classifier
    output_schema:
      type: object
      required: [verdict]
      properties: {verdict: {type: string, enum: [SAFETY, FINANCE, OTHER]}}
```

That is a complete workflow. `define_yaml` compiles it to rows and
`start_workflow` runs it, and the query step executes the moment its dependency
completes, in the transaction that completes it.

Those two authored steps become three tasks. `SEARCH` ranks against a vector and
the database makes no model calls of its own, so `retrieve` compiles into a task
that embeds the text at an endpoint the model registry supplies plus the query
that consumes it. You never write the first one. The model is written into both,
so the vector and the space being searched cannot come from two different
models — a mistake that would return a number rather than an error.

**Documentation: <https://percolating-sirsh.github.io/get-percolate>**

---

## Three ways to run it

These all install the same thing, so pick whichever suits where you are running
it.

### 1. Docker Compose — the whole stack, two images

```bash
curl -fsSL https://raw.githubusercontent.com/percolating-sirsh/get-percolate/main/compose/docker-compose.yml -o docker-compose.yml
docker compose up -d
```

You get Postgres 19 with the extensions baked in, PostgREST, two workers (one
for outbound HTTP and one for ingestion), the Content Server, the Agent Runtime
and MinIO, with nothing to compile.

Make yourself the first administrator before anything else. A fresh install
ships with no users at all, since the alternative is a default account with a
password everybody knows, and until one exists every `*_api` view is correctly
empty for everybody, which looks a lot like a system that is not working:

```bash
psql postgres://p8:p8@localhost:5432/percolate \
  -c "select rbac.bootstrap_admin('you@example.com', 'a long passphrase')"
```

A workflow has to be defined before it can be started, and both are ordinary
SQL, so this is the whole round trip against a fresh stack:

```bash
psql postgres://p8:p8@localhost:5432/percolate <<'SQL'
select workflow.define_yaml($$
name: hello
steps:
  - id: now
    sql: {function: p8ql, args: ['SELECT now()']}
$$);
select workflow.start_workflow('hello', '{}'::jsonb);
SQL
```

Then load the sample, since a fresh install stays empty until you put something
in it. `percolate` is the CLI from `percolate-core` (Python 3.11+) and
`samples/harbour` lives in this repository, so you need both on your machine and
a compose install gives you neither:

```bash
pip install 'percolate-core>=0.1.7'
git clone https://github.com/percolating-sirsh/get-percolate && cd get-percolate
percolate sample load samples/harbour --as-email you@example.com
```

The sample is a port-operations company with two tenants, a fleet, a corpus and
a graph, and it is the domain every worked example in the documentation queries
against. It needs an embedding key, because the corpus is embedded by the
running pipeline rather than shipped as literal vectors, and `--skip-documents`
loads everything else if you would rather not supply one yet.

The run has already finished by the time `start_workflow` returns, because a
`sql` step executes in the transaction that made it ready and no worker is
involved. If you have no `psql` on the host, `docker compose exec db psql -U p8
-d percolate` uses the one in the image.

### 2. Helm — a cluster, with Flux or Argo

```bash
helm install percolate oci://ghcr.io/percolating-sirsh/charts/percolate \
  --namespace percolate --create-namespace
```

We publish the chart as an **OCI artifact**, so there is no chart repository, no
`index.yaml` and no DNS in the path, and each of those is a thing that can break
independently of the chart itself. If you prefer a classic repo then `helm repo
add percolate https://percolating-sirsh.github.io/get-percolate/charts` works
too, and Flux and Argo can point straight at `charts/percolate` in this git repo
without any published artifact at all.

The chart brings up the database, PostgREST, the three services and two worker
pools you can scale independently, `http` for outbound calls and `ingest` for
uploaded files. It is a plain chart with no CRDs, so Flux (`HelmRelease`) and
Argo CD (`Application` with a Helm source) both consume it directly — there is
more on that in [`charts/percolate/README.md`](charts/percolate/README.md).

### 3. Your own Postgres 19

If you already run Postgres and want the extension in it:

```bash
curl -fsSL https://raw.githubusercontent.com/percolating-sirsh/get-percolate/main/install.sh | sh
psql -d yourdb -v auth_pw=... -v worker_pw=... -f bootstrap.sql
```

`install.sh` finds your `pg_config`, downloads the matching release assets and
puts them where Postgres looks. `bootstrap.sql` then creates the cluster roles
and installs the extension **as `app_owner`**, and a bare `CREATE EXTENSION
percolate` is refused, because a superuser owner bypasses every RLS policy in
the collection while leaving all of them in place and looking correct. Two
extensions get installed:

| Extension | What it is | How it ships |
|---|---|---|
| `percolate` | the whole system — schemas, tables, functions, RLS | **pure SQL**, one file, architecture-independent |
| `percolate_parser` | the P8QL and YAML compilers | a Rust `.so`, **prebuilt per platform** |

`pgvector` is a prerequisite and is packaged everywhere (`apt install
postgresql-19-pgvector`, `brew install pgvector`). `pg_cron` is optional and
only needed for scheduled workflows.

We build the parser for `linux/amd64`, `linux/arm64` and `macos/arm64`. On
anything else `install.sh` installs the SQL extension, tells you that
`define_yaml` and `p8ql` will not resolve until you build the parser yourself,
and exits non-zero, so a half install does not look like a successful one.

---

## What you get

| | |
|---|---|
| **Workflow engine** | DAG, saga compensation, retry with backoff, matrix fan-out, timers, signals, scheduling — all as rows. `SKIP LOCKED` claiming; the database is the queue. |
| **Agents** | An agent is a row. Prompt, tools and delegation are data. Tools are MCP or OpenAPI endpoints, discovered rather than declared. |
| **Query layer** | Eight modes in one dialect — `LOOKUP`, `GRAPH`, `RELEVANCE`, `PATH`, `TEXT`, `SEMANTIC`, `SEARCH`, `SCHEMA` — over PG19 property graphs plus pgvector. `FUZZY` is a modifier on `LOOKUP`, not a mode. |
| **Content plane** | Channels, files, resources, chunks. Post a file and the ingest worker parses and chunks it with nothing else to write — PDF, DOCX, HTML, markdown and audio; embedding needs a registered model and its key; a CSV becomes a Parquet dataset instead, because a table is not prose. |
| **Identity** | Users, roles, API keys, sessions, and RLS that is actually on. No role in the system is a superuser. |

---

## What it costs

Everything above is the pitch, so here is the other side of it.

| | |
|---|---|
| **PostgreSQL 19** | SQL/PGQ property graphs are a PG19 feature and the query parser is compiled against its ABI, so there is no fallback to 18. PG19 is in beta. |
| **A compiled extension** | `percolate_parser` is Rust. We publish builds for linux/amd64, linux/arm64 and macos/arm64, and anything else you build yourself. |
| **Your database is in the path** | Workflow state in Postgres means workflow throughput is bounded by your Postgres. At this scale that is usually the right trade, but it is a real one. |
| **Not a hosted product** | There is no dashboard and no SaaS. The management surface is the same RPC set a worker uses, over PostgREST. |

There is more on all four, and what we measured, in the
[documentation](https://percolating-sirsh.github.io/get-percolate).

---

## License

MIT.
