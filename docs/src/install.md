# Install

There are three ways in, they install the same thing, and you can move between
them later.
{: .lede }

## Docker Compose

```bash
curl -fsSL https://raw.githubusercontent.com/percolating-sirsh/get-percolate/main/compose/docker-compose.yml \
  -o docker-compose.yml
docker compose up -d
```

Two images and nothing to compile. The database installs itself the first time
it starts, because the bootstrap is baked into the image, so there is no init
directory to fetch alongside the compose file and no ordering for you to get
right.

Give it a minute and then ask it whether it is really there:

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

`missing` is the field to look at. The compiled parser and the SQL schema ship
independently and they will eventually disagree, so rather than trusting a
version string this probes the installed build with one canary per feature. If
it lists anything you have version skew, which otherwise shows up looking like
a syntax error in your workflow.

## Helm

```bash
helm install percolate oci://ghcr.io/percolating-sirsh/charts/percolate \
  -n percolate --create-namespace \
  --set secrets.postgresPassword="$(openssl rand -base64 24)" \
  --set secrets.authenticatorPassword="$(openssl rand -base64 24)" \
  --set secrets.workerPassword="$(openssl rand -base64 24)" \
  --set secrets.jwtSecret="$(openssl rand -base64 48)"
```

The chart is an OCI artefact, so there is no chart repository, no `index.yaml`
and no DNS involved, and each of those is a thing that can break on its own.
`helm repo add percolate https://percolating-sirsh.github.io/get-percolate/charts` works too if
you prefer a classic repo, and Flux and Argo can both point straight at
`charts/percolate` in git with nothing published at all.

You get the database, PostgREST, the three services, one worker pool and MinIO.
There are no CRDs and no operator — the only custom resources are KEDA's, and
only if you turn autoscaling on.

The four passwords are required and the chart will not generate them for you. A
generated value comes out different between `helm template` and `helm install`,
and between a GitOps dry run and the apply after it, so a controller that diffs
continuously will either report drift forever or "fix" it by rewriting the
database password underneath a running StatefulSet.

## Into a Postgres 19 you already run

```bash
curl -fsSL https://raw.githubusercontent.com/percolating-sirsh/get-percolate/main/install.sh | sh
```

There are two extensions and they ship differently, because they are different
kinds of thing:

| Extension | What it is | How it ships |
|---|---|---|
| `percolate` | the whole system — schemas, tables, functions, RLS | pure SQL, one file, the same on every platform |
| `percolate_parser` | the P8QL and YAML compilers | a Rust `.so`, prebuilt per platform |

A shared library is compiled against one ABI, so there is no portable form of
the parser and we build it for each platform instead. `install.sh` reads your
`pg_config`, which is the only thing that knows where this particular Postgres
keeps its extensions, checks the major version, and puts both files where they
belong.

We publish parser builds for `linux/amd64`, `linux/arm64` and `macos/arm64`. On
anything else the script installs the SQL extension, tells you that
`define_yaml` and `p8ql:` steps will not resolve until the parser is built, and
exits non-zero — so a half install does not look like a successful one.

Then, as a superuser:

```sql
CREATE EXTENSION IF NOT EXISTS vector;   -- packaged nearly everywhere
CREATE EXTENSION percolate CASCADE;
```

You need `CASCADE` because `percolate` depends on `percolate_parser`,
`pgcrypto` and `pg_trgm`, and none of those is a trusted extension. Everything
that `percolate` itself creates is owned by a non-superuser.

### pg_cron, if you want schedules

This one is optional and its absence is quiet, so it is worth setting up
consciously. `pg_cron` runs as a background worker and there is no
`CREATE EXTENSION` that can add it after startup. Without it, scheduled
workflows, the stale-task reaper and every `timer` step just never fire.

```
shared_preload_libraries = 'pg_cron'
cron.database_name = 'percolate'
```

One cron job covers the whole system, since every schedule is a row in
`workflow.schedules`.

## Checking an install properly

`compiler_capabilities()` tells you the parser is current. For everything else
we ship `surface.sql`, which declares every capability the documentation
promises and then checks the database provides it:

```bash
psql "$DSN" -f surface.sql
# NOTICE:  SURFACE COMPLETE: all 137 declared capabilities present
```

Next: [your first workflow](first-workflow.html).
