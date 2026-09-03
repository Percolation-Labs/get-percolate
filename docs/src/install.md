# Install

There are three ways in, they install the same thing, and you can move between
them later.
{: .lede }

## Docker Compose

What we are trying to do here is get a working database and services with
nothing to compile and no ordering to get right.
{: .goal }

```bash
curl -fsSL https://raw.githubusercontent.com/percolating-sirsh/get-percolate/main/compose/docker-compose.yml \
  -o docker-compose.yml
docker compose up -d
```

Give it a minute, then ask it whether it is really there:

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

<details class="why" markdown="1">
<summary>Why it works — the database installs itself, and `missing` is the field
to read</summary>

Two images and nothing to compile. The bootstrap is baked into the image, so the
database installs itself the first time it starts — there is no init directory to
fetch alongside the compose file and no ordering for you to get right.

`missing` is what to look at rather than a version string. The compiled parser
and the SQL schema ship independently and will eventually disagree, so this
probes the installed build with one canary per feature. If it lists anything you
have version skew, which otherwise shows up looking like a syntax error in a
workflow that is not wrong.

The compose file pins `percolate-postgres:19`, which moves to whatever the
newest build in that major is — fine for trying this out, not for a deployment
you want to hold still. `percolate-postgres:19-0.1.1` is the immutable tag
behind today's `:19`; pin that instead if you need one. Pre-1.0 there is no
in-place extension upgrade, so the image tag is the only lever for keeping a
deployment on a known version rather than the next build that lands.

<p class="related"><strong>Related</strong>
<a href="operating.html#version-skew">what skew looks like in production</a> ·
<a href="first-workflow.html">the first thing to run against it</a></p>
</details>

## Helm

What we are trying to do here is install the whole stack into a cluster, with
passwords we generate ourselves.
{: .goal }

```bash
helm install percolate oci://ghcr.io/percolating-sirsh/charts/percolate \
  -n percolate --create-namespace \
  --set secrets.postgresPassword="$(openssl rand -base64 24)" \
  --set secrets.authenticatorPassword="$(openssl rand -base64 24)" \
  --set secrets.workerPassword="$(openssl rand -base64 24)" \
  --set secrets.jwtSecret="$(openssl rand -base64 48)"
```

You get the database, PostgREST, the three services, one worker pool and MinIO.
There are no CRDs and no operator — the only custom resources are KEDA's, and
only if you turn autoscaling on.

<details class="why" markdown="1">
<summary>Why it works — an OCI artefact, and four passwords the chart refuses to
generate</summary>

The chart is an OCI artefact, so there is no chart repository, no `index.yaml`
and no DNS involved, and each of those is a thing that can break on its own.
`helm repo add percolate https://percolating-sirsh.github.io/get-percolate/charts`
works too if you prefer a classic repo, and Flux and Argo can both point straight
at `charts/percolate` in git with nothing published at all.

The four passwords are required and the chart will not generate them for you,
which looks unhelpful until you see the failure it avoids. A generated value
comes out different between `helm template` and `helm install`, and between a
GitOps dry run and the apply after it — so a controller that diffs continuously
will either report drift forever or "fix" it by rewriting the database password
underneath a running StatefulSet.

`postgres.image.tag` defaults to `19` for the same reason the compose file
does — it tracks the newest build in that major, not one release. Set it to
`19-0.1.1` to pin instead; pre-1.0 there is no in-place extension upgrade, so
the tag is what keeps a cluster on a known version rather than whatever `19`
build lands next.

<p class="related"><strong>Related</strong>
<a href="operating.html#scaling-on-queue-depth">turning autoscaling on</a></p>
</details>

## Into a Postgres 19 you already run

What we are trying to do here is add the extensions to a database that already
exists, without a service anywhere.
{: .goal }

```bash
curl -fsSL https://raw.githubusercontent.com/percolating-sirsh/get-percolate/main/install.sh | sh
```

```sql
-- then, as a superuser
CREATE EXTENSION IF NOT EXISTS vector;   -- packaged nearly everywhere
CREATE EXTENSION percolate CASCADE;
```

<details class="why" markdown="1">
<summary>Why it works — two extensions that ship differently, because they are
different kinds of thing</summary>

| Extension | What it is | How it ships |
|---|---|---|
| `percolate` | the whole system — schemas, tables, functions, RLS | pure SQL, one file, the same on every platform |
| `percolate_parser` | the P8QL and YAML compilers | a Rust `.so`, prebuilt per platform |

A shared library is compiled against one ABI, so there is no portable form of the
parser and we build it per platform instead. `install.sh` reads your
`pg_config` — the only thing that knows where this particular Postgres keeps its
extensions — checks the major version, and puts both files where they belong.

We publish parser builds for `linux/amd64`, `linux/arm64` and `macos/arm64`. On
anything else the script installs the SQL extension, tells you that `define_yaml`
and `p8ql:` steps will not resolve until the parser is built, and exits non-zero,
so a half install does not look like a successful one.

`CASCADE` is needed because `percolate` depends on `percolate_parser`, `pgcrypto`
and `pg_trgm`, and none of those is a trusted extension. Everything `percolate`
itself creates is owned by a **non-superuser**, which is not a detail: a
superuser bypasses RLS unconditionally, so a superuser-owned install would leave
every policy in the collection inert while looking correct.

<p class="related"><strong>Related</strong>
<a href="index.html#no-role-is-a-superuser">why no role here is a superuser</a> ·
<a href="query.html#over-rest-and-the-two-things-that-look-like-bugs">what that
looks like when it goes wrong</a></p>
</details>

### pg_cron, if you want schedules

This one is optional and its absence is quiet, so it is worth setting up
consciously.

What we are trying to do here is give the engine a clock, which it needs for
three separate things.
{: .goal }

```
shared_preload_libraries = 'pg_cron'
cron.database_name = 'percolate'
```

```sql
select cron.schedule('workflow-tick',   '* * * * *', $$select workflow.tick()$$);
select cron.schedule('workflow-reaper', '* * * * *', $$select workflow.reap_stale_tasks()$$);
select cron.schedule('workflow-timers', '* * * * *', $$select workflow.promote_due_timers()$$);
```

<details class="why" markdown="1">
<summary>Why it works — and what silently does not happen without it</summary>

`pg_cron` runs as a background worker, so there is no `CREATE EXTENSION` that can
add it after startup. Without it, scheduled workflows never fire, the stale-task
reaper never runs so a crashed worker's tasks are never recovered, and every
`timer` step waits forever. None of those produce an error; they produce a
system that looks idle.

One set of jobs covers the whole deployment however many schedules you have,
because a schedule is a row in `workflow.schedules` rather than a cron entry.

`cron.database_name` is the usual reason a correctly-created job never runs — it
can only be one database, and the default is `postgres`.

<p class="related"><strong>Related</strong>
<a href="recipes.html#1-bring-a-source-in">a scheduled workflow</a> ·
<a href="failure.html#crash-recovery">what the reaper recovers</a></p>
</details>

## Checking an install properly

What we are trying to do here is check that every capability the documentation
promises is actually present, rather than that the extension loaded.
{: .goal }

```bash
psql "$DSN" -f surface.sql
# NOTICE:  SURFACE COMPLETE: all 137 declared capabilities present
```

<details class="why" markdown="1">
<summary>Why it works — every row carries the sentence it keeps honest</summary>

`compiler_capabilities()` tells you the parser is current. `surface.sql` is the
other half: it declares every capability the documentation promises, each row
carrying the spec sentence it exists to keep honest, and checks the database
provides it — failing loudly rather than reporting a count.

It exists because every gap in this collection had been found the hard way, and
it caught a stale development harness on its first run.

<p class="related"><strong>Related</strong>
<a href="operating.html#upgrading">running both after an upgrade</a></p>
</details>

Next: [agents](agents.html), which is the shortest useful thing to do
against a fresh install: write one spec, save it, and call it.
