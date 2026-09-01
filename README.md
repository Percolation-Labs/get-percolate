<img src="docs/assets/logo.png" alt="" width="56" align="left" hspace="12">

# Percolate — an AI workflow engine in Postgres

**Postgres is the system, not the backing store for one.** Workflow state,
agent conversations, identity and permissions, graph and semantic queries all
live in Postgres as tables, functions and native property-graph views. Steps
written as `sql` or `p8ql` run *inside* the database with no process anywhere;
only outbound HTTP needs a worker.

<br clear="left">

```yaml
steps:
  - id: embed
    rest: {url: '{{env.LLM_URL}}/api/embeddings', jsonpath: embedding}
  - id: retrieve
    needs: [embed]
    sql: {function: p8ql_vec, args: ['SEARCH "outage causes" FROM chunks', '{{steps.embed.result}}']}
  - id: triage
    needs: [retrieve]
    agent: classifier
    output_schema:
      type: object
      required: [verdict]
      properties: {verdict: {type: string, enum: [SAFETY, FINANCE, OTHER]}}
```

That is a complete workflow. `define_yaml` compiles it to rows; `start_workflow`
runs it. The `sql` step executes the moment its dependency completes, in the
transaction that completes it.

**Documentation: <https://docs.percolationlabs.ai>**

---

## Three ways to run it

Pick one. They install the same thing.

### 1. Docker Compose — the whole stack, two images

```bash
curl -fsSL https://raw.githubusercontent.com/percolating-sirsh/get-percolate/main/compose/docker-compose.yml -o docker-compose.yml
docker compose up -d
```

Postgres 19 with the extensions baked in, PostgREST, the worker, the Content
Server, the Agent Runtime, and MinIO. Nothing to compile.

```bash
psql postgres://p8:p8@localhost:5432/percolate \
  -c "select workflow.start_workflow('my_flow','{}'::jsonb)"
```

### 2. Helm — a cluster, with Flux or Argo

```bash
helm install percolate oci://ghcr.io/percolating-sirsh/charts/percolate \
  --namespace percolate --create-namespace
```

The chart is published as an **OCI artifact**, which needs no chart repository,
no `index.yaml` and no DNS — three things that can each break independently of
the chart itself. `helm repo add percolate https://docs.percolationlabs.ai/charts`
also works if you prefer a classic repo, and Flux and Argo can point straight at
`charts/percolate` in this git repo without any published artifact at all.

The chart brings up the database, PostgREST, the three services and one worker
pool you can scale. It is a plain chart with no CRDs, so Flux
(`HelmRelease`) and Argo CD (`Application` with a Helm source) both consume it
directly — see [`charts/percolate/README.md`](charts/percolate/README.md).

### 3. Your own Postgres 19

If you already run Postgres and want the extension in it:

```bash
curl -fsSL https://raw.githubusercontent.com/percolating-sirsh/get-percolate/main/install.sh | sh
psql -d yourdb -c "CREATE EXTENSION percolate CASCADE"
```

`install.sh` finds your `pg_config`, downloads the matching release assets, and
puts them where Postgres looks. It installs two extensions:

| Extension | What it is | How it ships |
|---|---|---|
| `percolate` | the whole system — schemas, tables, functions, RLS | **pure SQL**, one file, architecture-independent |
| `percolate_parser` | the P8QL and YAML compilers | a Rust `.so`, **prebuilt per platform** |

`pgvector` is a prerequisite and is packaged everywhere (`apt install
postgresql-19-pgvector`, `brew install pgvector`). `pg_cron` is optional and
only needed for scheduled workflows.

**Supported platforms for the prebuilt parser:** `linux/amd64`,
`linux/arm64`, `macos/arm64`. On anything else `install.sh` installs the SQL
extension and tells you plainly that `define_yaml` and `p8ql` will not resolve
until you build the parser — it does not pretend to have succeeded.

---

## What you get

| | |
|---|---|
| **Workflow engine** | DAG, saga compensation, retry with backoff, matrix fan-out, timers, signals, scheduling — all as rows. `SKIP LOCKED` claiming; the database is the queue. |
| **Agents** | An agent is a row. Prompt, tools and delegation are data. Tools are MCP or OpenAPI endpoints, discovered rather than declared. |
| **Query layer** | `LOOKUP`, `FUZZY`, `GRAPH`, `TEXT`, `SEMANTIC`, `SEARCH` and plain SQL in one dialect, over PG19 property graphs plus pgvector. |
| **Content plane** | Channels, files, resources, chunks — upload, ingest and serve back. |
| **Identity** | Users, roles, API keys, sessions, and RLS that is actually on. No role in the system is a superuser. |

---

## License

MIT.
