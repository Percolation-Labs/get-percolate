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

Give it a minute, then ask it whether it is really there. If you have no `psql`
on the host — and nothing above installed one — the database container has its
own:

```bash
docker compose exec db psql -U p8 -d percolate -c "select * from workflow.compiler_capabilities()"
# or, with a local client:
psql postgres://p8:p8@localhost:5432/percolate -c "select * from workflow.compiler_capabilities()"
```

<div class="evidence" markdown="1">
<div class="label">docker compose exec db psql …, on a fresh volume</div>

```
{"accepts": {"sql": true, "p8ql": true, "rest": true, "work": true,
             "agent": true, "embed": true, "timer": true, "matrix": true,
             "signal": true, "batching": true, "rate_key": true,
             "continue_on": true, "sub_workflow": true,
             "output_schema": true, "p8ql_vector_desugar": true},
 "missing": [], "available": true}
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

You get the database, PostgREST, the three services, two worker pools — `http`
and `ingest` — and MinIO.
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

## The first user, and a token

A fresh install has **no users, no roles and no permissions** — those tables are
empty on purpose, because the alternative is a default administrator with a
known password. Nothing over HTTP works until you create one: PostgREST answers
`not authorized to author agents` and the agent runtime answers
`a verified bearer token is required`.

What we are trying to do here is get from an empty `rbac` to a bearer token that
the REST interface and the agent runtime both accept.
{: .goal }

```sql
-- 1. a user
select rbac.create_user_with_password('me@example.com', 'a long passphrase') as uid \gset

-- 2. a role, and the four resources the system actually gates on
insert into rbac.roles (name, description) values ('admin', 'everything');
insert into rbac.role_permissions (role, resource, action) values
    ('admin', 'users',              'admin'),
    ('admin', 'agents',             'update'),
    ('admin', 'workflow_runs',      'read'), ('admin', 'workflow_runs',      'write'),
    ('admin', 'workflow_schedules', 'read'), ('admin', 'workflow_schedules', 'write');

-- 3. the FIRST grant is an insert, not rbac.grant_role() -- see below
insert into rbac.user_roles (user_id, role) values (:'uid'::uuid, 'admin');
```

Then sign a JWT with the same secret the stack was given — `P8_JWT_SECRET`,
which the compose file defaults to
`change-me-a-long-random-string-at-least-32-chars`. Two claims are load-bearing:
`sub` is the user id every RLS policy reads through `rbac.current_user_id()`, and
`role` is the Postgres role PostgREST switches to.

```python
import base64, hmac, hashlib, json, time
b64 = lambda b: base64.urlsafe_b64encode(b).rstrip(b"=")
secret = b"change-me-a-long-random-string-at-least-32-chars"
head = b64(json.dumps({"alg": "HS256", "typ": "JWT"}).encode())
body = b64(json.dumps({"sub": "<the uid from step 1>",
                       "role": "authenticated",
                       "exp": int(time.time()) + 3600}).encode())
sig  = b64(hmac.new(secret, head + b"." + body, hashlib.sha256).digest())
print((head + b"." + body + b"." + sig).decode())
```

That is the `$TOKEN` every `curl` in these docs wants.

<div class="evidence" markdown="1">
<div class="label">the same call, before and after</div>

```
$ curl -s localhost:3000/rpc/upsert_agent -H 'Content-Profile: agentic' \
       -H 'Content-Type: application/json' -d '{"p_spec":{"name":"harbourmaster"}}'
{"code":"P0001","message":"not authorized to author agents"}          # HTTP 400

$ curl -s localhost:3000/rpc/upsert_agent -H 'Content-Profile: agentic' \
       -H "Authorization: Bearer $TOKEN" \
       -H 'Content-Type: application/json' -d '{"p_spec":{"name":"harbourmaster"}}'
{"id":"4dc4e929-…","name":"harbourmaster", …}                          # HTTP 200
```
</div>

<details class="why" markdown="1">
<summary>Why the first grant cannot go through `grant_role`, and why `psql` could
author an agent all along</summary>

`rbac.grant_role` is gated on `rbac.has_permission(current_user_id(), 'users',
'admin')`, and on an empty database nobody holds that — including the person
trying to bootstrap. So the first `user_roles` row is a plain insert made by a
connection privileged enough to write the table, and every grant after it can go
through the function. That is a real bootstrap step rather than an oversight:
the alternative is a function that grants `users/admin` to whoever asks first.

It is also why the SQL on the [agents](agents.html) page works from `psql`
before any of this. `agentic.may_author` permits the call when
`rbac.current_user_id()` is null and the session is a privileged local one —
the migration path, deliberately — so `psql` is authoring as the database owner,
not as a user. The moment the same call arrives over HTTP there is a JWT and
therefore a user, and the permission is checked.

Passwords are for `rbac.login`, which exchanges them for a refresh token; it
does not mint the access token, because whatever holds `P8_JWT_SECRET` does.
There is no packaged endpoint that hands you one yet, so signing it yourself —
or from your own auth provider, with the same secret and the same two claims —
is what "getting a token" means today.

<p class="related"><strong>Related</strong>
<a href="agents.html#call-it-over-rest">the calls that need it</a> ·
<a href="query.html#over-rest-and-the-two-things-that-look-like-bugs">what an
anonymous caller sees instead</a></p>
</details>

Next: [agents](agents.html), which is the shortest useful thing to do
against a fresh install: write one spec, save it, and call it.
