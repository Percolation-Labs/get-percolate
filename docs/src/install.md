# Install

There are three ways in, they install the same thing, and you can move between
them later.
{: .lede }

## Docker Compose

What we are trying to do here is get a working database and services with
nothing to compile and no ordering to get right.
{: .goal }

<!-- run: shell -->
```bash
curl -fsSL https://raw.githubusercontent.com/Percolation-Labs/get-percolate/main/compose/docker-compose.yml \
  -o docker-compose.yml
docker compose up -d
```

Six services come up, and that is a list of **roles rather than a recommended
process count**: PostgREST for the REST surface, a `worker` for steps that leave
the machine, an `ingest-worker` for reading uploaded files, the Content Server
for uploads, the Agent Runtime for model turns, and MinIO for bytes. Three of
those are one image under three commands, so a real deployment usually runs
fewer — often just a worker, since `sql` and `p8ql` steps need no process at
all — or many more, a pool per queue. The one pairing not to collapse is the two
workers: `--queue` takes a single queue, so merging them means choosing which of
outbound calls and ingestion silently stops happening.

The db image is **pinned to a version**, so `docker compose up -d` gives every
reader the same database rather than whatever their machine last pulled.
Updating therefore means changing the tag, not pulling a moving one:

```bash
# edit compose/docker-compose.yml: percolate-postgres:19-<old> -> :19-<new>
docker compose up -d
```

That is the deliberate half of a trade. `:19` used to float, and a floating tag
makes "works on my machine" literally true and unfalsifiable — a stale local
`:19` served @@extension@@'s predecessor here for an afternoon and produced a
convincing bug report about a defect that had already been fixed. `ci/versions.py`
now enforces the pinned tag against `versions.toml`, so the number moves in one
place and every file that repeats it moves with it.

The new image brings the new extension files; one more statement installs them
into the database that already exists:

```sql
set role app_owner;
alter extension percolate update;
```

`set role app_owner` is not decoration. An extension update creates its new
objects as whoever runs it, so running this as a superuser would hand every new
table a superuser owner and leave the policies on it inert — the one failure
this collection is built to refuse. Updating as `app_owner` is what keeps
ownership and row-level security exactly as a fresh install has them.

Every release ships `percolate--<old>--@@extension@@.sql` for each version
already published, and it is the whole schema replayed: every statement in it
is written to survive being applied twice, and `build-sql.py` refuses one that
is not. An upgraded database was checked against a fresh install of the same
version object by object — 629 of them, identical.

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

And ask it what it was built from, which is a different question:

```sql
select * from percolate_build();
```

```
 component | version | commit_sha | built_at             | consistent
-----------+---------+------------+----------------------+-----------
 parser    | @@extension@@   | 2e679e3    | 2026-09-03 16:04:00Z | f
 schema    | @@extension@@   | 9f832b1    | 2026-09-03 19:52:00Z | f
```

`consistent` is `f` there because the two halves were built from different
commits — the shape of a real incident, not a decorative example. A `-dirty`
suffix on a commit means that build came from a working tree that matched no
commit at all.

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

`percolate_build()` answers the other axis, and the two are not
interchangeable. Capabilities detect the parser and the schema drifting apart
from **each other**; both halves can agree perfectly and both be several
commits behind the source that produced them. That second case cost a day
once — a test suite failing on two parser bugs that were already fixed in the
tree, against a `.so` compiled before the fix — so the build now says what it
came from rather than leaving it to be inferred.

<p class="related"><strong>Related</strong>
<a href="operating.html#version-skew">what skew looks like in production</a> ·
<a href="first-workflow.html">the first thing to run against it</a></p>
</details>

## Helm

What we are trying to do here is install the whole stack into a cluster, with
passwords we generate ourselves.
{: .goal }

```bash
helm install percolate oci://ghcr.io/percolation-labs/charts/percolate \
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
`helm repo add percolate https://percolation-labs.github.io/get-percolate/charts`
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
curl -fsSL https://raw.githubusercontent.com/Percolation-Labs/get-percolate/main/install.sh | sh
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
and `pg_trgm`, and none of those is a trusted extension — so those come from
the superuser half of `bootstrap.sql`, before it hands over. Everything
`percolate` itself creates is then owned by a **non-superuser**, which is not a
detail: a superuser bypasses RLS unconditionally, so a superuser-owned install
would leave every policy in the collection inert while looking correct. The
extension asserts this about itself rather than trusting the installer to get
it right, which is what makes the bare `CREATE EXTENSION` fail loudly instead
of quietly.

<p class="related"><strong>Related</strong>
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
`permission denied for function upsert_agent` with a 401, and the agent runtime
answers `a verified bearer token is required`.

What we are trying to do here is get from an empty `rbac` to a bearer token that
the REST interface and the agent runtime both accept.
{: .goal }

<!-- run: sql -->
```sql
select rbac.bootstrap_admin('me@example.com', 'a long passphrase') as uid \gset
```

That is the whole step. It creates the user, creates an `admin` role, grants it
the permissions the system actually checks, and makes the first `user_roles`
row — and it **refuses to run once any role has been granted to anyone**, which
is what keeps it a bootstrap rather than a back door.

This page used to spell the same thing out as a list of `insert` statements to
copy, and the list was wrong. `role_permissions.action` is free text compared
with `=`, so a wrong verb is not an error anywhere: it inserts, the role looks
populated, and every policy that consults it returns false. The list here
granted `workflow_runs`/`read` where every RLS policy in the collection asks for
`select`, so following this page exactly produced an administrator who then saw
**zero rows** in `workflow.runs_api` with no way to tell that from "my workflow
never ran". The vocabulary is now derived in one place inside the extension
instead of transcribed into prose that can drift away from it.

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
body = b64(json.dumps({"sub": "<the uid bootstrap_admin returned>",
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
{"code":"42501","message":"permission denied for function upsert_agent"}  # HTTP 401

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
trying to bootstrap. So the first `user_roles` row cannot come from
`grant_role`, and every grant after it can. That is a real bootstrap step
rather than an oversight: the alternative is a function that grants
`users/admin` to whoever asks first.

`bootstrap_admin` is that step with the escalation closed rather than left to
the caller. It refuses the moment `rbac.user_roles` holds anything, so it is
reachable only while the system has no administrator — the one window in which
handing out `users/admin` is not a privilege escalation. It is also not granted
to `web_anon` or `authenticated`, so it does not exist over PostgREST; like the
`CREATE EXTENSION` before it, it is run from a privileged local session.

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

## The sample, which nothing loads for you

A fresh install is **empty**, and almost every worked example in these pages
reads data. There is a sample for that, and loading it is a step you take
rather than something a container did while you were not looking.

What we are trying to do here is get the domain the rest of this documentation
queries, and be able to tell it apart from our own data afterwards.
{: .goal }

`percolate` is the CLI from `percolate-core`, and nothing you have run so far
installed it — the compose stack runs that image, it does not put the command on
your PATH. It needs **Python 3.11 or newer**; on a Mac the system `python3` is
older than that and `pip` will report the package as simply not existing rather
than as unsupported.

The extras are not optional decoration: `sample` is the YAML reader and `agent`
is what turns `plugin.yaml`'s agents — which are JSON Schema documents, not
prompt strings — into rows. Without them the load refuses before it writes
anything, which is the right behaviour and still a stop.

<!-- run: pip -->
```bash
pip install 'percolate-core[sample,agent]>=@@core_min@@'
```

`samples/harbour` is a path **inside this repository**, so it needs to be on
disk — a compose install has only the one file you curled. The DSN has to be
the owner's, because the load writes `rbac.*`; the CLI names the compose one in
its own error if you forget:

```bash
git clone https://github.com/Percolation-Labs/get-percolate
cd get-percolate
export P8_ADMIN_DSN=postgres://p8:p8@localhost:5432/percolate
percolate sample load samples/harbour --as-email me@example.com
```

A port-operations company: two tenants, four operators, five vessels, three
ports, inspections, a corpus of reports and a graph tying them together.

```
harbour 1.0.0
  sql schema.sql
  embedding model text-embedding-3-small (1536d)
  entity operator <- harbour.operators
  entity vessel <- harbour.vessels
  entity port <- harbour.ports
  ...
  edge operator:MERB -subsidiary_of-> operator:MERI
  plugin harbour (0 servers, 1 skills, 1 agents)
  workflow harbour_deficiencies
```

**Most of it is tenanted**, so mint a token that names one of the two
organisations or you will see only the shared tier and think nothing loaded:

```bash
percolate auth token --email me@example.com \
  --orgs d0000000-0000-0000-0000-00000000000a     # Meridian; ...000b is Kestrel
```

**It needs an embedding key**, in `LLM_API_KEY`, because the corpus goes in
through `POST /files` and is embedded by the running pipeline. `--dry-run` says
what a load would need without writing anything; `--skip-documents` loads
everything else, and `LOOKUP`, `FUZZY`, `GRAPH` and `TEXT` all work without it
— only `SEMANTIC` and `SEARCH` need vectors.

<details class="why" markdown="1">
<summary>Why it works — a directory of the documents you would have written
anyway, and why the vectors are not in it</summary>

The sample is `samples/harbour/` in the repository, and it is worth opening
before you run it. `schema.sql` is the company's own tables — nothing in it
mentions Percolate, which is the point, because Percolate indexes tables you
already have. Everything else is a document in the format you would author by
hand: `sources.yaml` is what is addressable, `graph.yaml` is the relation
vocabulary with edges named `vessel:Meridian Dawn` rather than by uuid,
`plugin.yaml` is skills and agents as one removable bundle, `workflows/` are
workflow documents and `documents/` is markdown. Reading it teaches the
formats; a `.sql` dump would have hidden all of them behind four hundred
INSERTs.

**The vectors are deliberately not in the files.** An earlier version of this
fixture shipped literal four-dimension vectors so it would load with nothing
running. It reproduced beautifully and taught the wrong thing: a reader who
copied the pattern had a corpus no model had ever seen and rankings that meant
nothing. Here the documents are embedded by the same pipeline yours will be, so
what you search is what a model produced — and the sample costs one embedding
call per document, which is the honest price of retrieval rather than an
inconvenience.

Nothing loads on first boot for the same reason. Rows that appear because a
container started are rows nobody chose, and a demo you cannot tell apart from
a deployment is a bad demo. Applying the plugin with an empty manifest takes
the skills and agents back out and says what it removed, and `drop schema
harbour cascade` takes the rest:

```sql
select agentic.apply_plugin('{"name":"harbour","version":"1.0.0"}'::jsonb);
drop schema harbour cascade;
```

Uninstalling is the same call as installing rather than a second function,
because the pruning path is the one that knows what else references a row —
which is why the `plugin` columns are `on delete restrict`.

<p class="related"><strong>Related</strong>
<a href="cookbook.html">the ten scenarios it was built for</a> ·
<a href="ingest.html">what happens to each document on the way in</a></p>
</details>

Next: [agents](agents.html), which is the shortest useful thing to do
against a fresh install: write one spec, save it, and call it.
