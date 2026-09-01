# Install

Three ways in. They install the same thing, and you can move between them.

## Docker Compose

```bash
curl -fsSL https://raw.githubusercontent.com/percolating-sirsh/get-percolate/main/compose/docker-compose.yml \
  -o docker-compose.yml
docker compose up -d
```

Two images and nothing to compile. **The database installs itself on first
start** — the extension bootstrap is baked into the image, so there is no init
directory to fetch alongside the compose file, and no ordering for you to get
right.

Give it a minute, then ask it whether it is actually there:

<div class="evidence" markdown="1">
<div class="label">psql</div>

```
$ psql postgres://p8:p8@localhost:5432/percolate -c "select * from workflow.compiler_capabilities()"

                          compiler_capabilities
-------------------------------------------------------------------------
 {"accepts": {"matrix": true, "output_schema": true, "continue_on": true,
              "signal": true, "timer": true, "sub_workflow": true},
  "missing": []}
```
</div>

`missing` is the field that matters. The compiled parser and the SQL schema ship
independently and will eventually disagree; this probes the installed build with
a canary per feature rather than trusting a version string. If it lists
features, you have version skew — not a syntax problem, which is what it would
otherwise look like.

## Helm

```bash
helm install percolate oci://ghcr.io/percolating-sirsh/charts/percolate \
  -n percolate --create-namespace \
  --set secrets.postgresPassword="$(openssl rand -base64 24)" \
  --set secrets.authenticatorPassword="$(openssl rand -base64 24)" \
  --set secrets.workerPassword="$(openssl rand -base64 24)" \
  --set secrets.jwtSecret="$(openssl rand -base64 48)"
```

The chart is an **OCI artifact**, so there is no chart repository, no
`index.yaml` and no DNS in the path — three things that can each break
independently of the chart. A classic `helm repo add percolate
https://docs.percolationlabs.ai/charts` also works, and Flux and Argo can point
straight at `charts/percolate` in git with nothing published at all.

The chart brings up the database, PostgREST, the three services, one worker pool
and MinIO. No CRDs and no operator — the only custom resources are KEDA's, and
only if you turn autoscaling on. Flux and Argo consume it directly; see the
[chart README](https://github.com/percolating-sirsh/get-percolate/tree/main/charts/percolate)
for both manifests.

The four passwords are required and the chart **will not generate them**. A
generated value differs between `helm template` and `helm install`, and between
a GitOps dry run and the apply that follows — which makes a continuously-diffing
controller report drift forever, or "heal" it by rewriting the database password
out from under a running StatefulSet.

## Into a Postgres 19 you already run

```bash
curl -fsSL https://raw.githubusercontent.com/percolating-sirsh/get-percolate/main/install.sh | sh
```

Two extensions, and they ship differently because they *are* different:

| Extension | What it is | How it ships |
|---|---|---|
| `percolate` | the whole system — schemas, tables, functions, RLS | **pure SQL**, one file, architecture-independent |
| `percolate_parser` | the P8QL and YAML compilers | a Rust `.so`, **prebuilt per platform** |

`install.sh` reads your `pg_config` — the only thing that knows where *this*
Postgres keeps its extensions — checks the major version, and puts both where
they belong. Prebuilt platforms are `linux/amd64`, `linux/arm64` and
`macos/arm64`. On anything else it installs the SQL extension, tells you plainly
that `define_yaml` and `p8ql:` steps will not resolve until you build the
parser, and **exits non-zero** rather than reporting success for a half install.

Then, as a superuser:

```sql
CREATE EXTENSION IF NOT EXISTS vector;   -- prerequisite, packaged everywhere
CREATE EXTENSION percolate CASCADE;
```

`CASCADE` matters: `percolate` depends on `percolate_parser`, `pgcrypto` and
`pg_trgm`, none of which is a trusted extension. Everything `percolate` itself
creates is owned by a **non-superuser** on purpose.

### pg_cron, if you want schedules

Optional, and its absence is quiet, so it is worth being deliberate. `pg_cron`
is a background worker: there is no `CREATE EXTENSION` that can add it after
startup. Without it, scheduled workflows, the stale-task reaper and every
`timer` step simply never fire.

```
shared_preload_libraries = 'pg_cron'
cron.database_name = 'percolate'
```

One cron job serves the whole system, because every schedule is a row in
`workflow.schedules`.

## Verifying an install properly

`compiler_capabilities()` says the parser is current. For everything else, the
specs repository ships `surface.sql` — an audit of every capability the specs
promise, each row carrying the spec sentence it keeps honest:

```bash
psql "$DSN" -f surface.sql
# NOTICE:  SURFACE COMPLETE: all 137 declared capabilities present
```
