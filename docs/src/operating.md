# Operating it

The views and audits below are how you inspect runs and queues, investigate
failures and size your worker pools, from SQL or over PostgREST on any install.
{: .lede }

A browser workbench covers the same ground — [Using the UI](ui.html) — and
nothing on this page depends on it: everything here is SQL and PostgREST.

## Scaling on queue depth

`queue` is the only signal that both `claim_task` and an autoscaler can see, so
one worker pool per queue is how a slow model endpoint stops starving a fast
ingestion queue. The [ingest queue](ingest.html) is usually the one to watch
first, since a batch of uploads arrives all at once and then stops.

What we are trying to do here is size each pool to the work that is actually
waiting for it, and scale to zero when there is none.
{: .goal }

```yaml
workers:
  - name: http
    queue: http
    autoscaling: {enabled: true, minReplicas: 0, maxReplicas: 20, queueDepthPerPod: 25}
  - name: ingest
    queue: ingest
    replicas: 1
```

The list replaces the chart's default one, so it names `ingest` again: a list
without it leaves uploads stored and never read.

```sql
-- the KEDA trigger, which is a SQL query rather than a CPU metric
select workflow.queue_depth('http')::int
-- counts tasks that are running, or ready with run_after <= now()
```

<details class="why" markdown="1">
<summary>Why it works — work that can be done or is being done, and not a row
count</summary>

A pending task blocked on a dependency is not work that anyone can do. Counting
it scales up pods that find nothing and then scale back down, which costs money
and looks like demand on every dashboard you have.

A `running` task is counted, though, and leaving it out is wrong in the
opposite direction: ten pods each three minutes into a long task report a depth
of zero, and the autoscaler scales them away from work in flight. The target is
per replica, so N pods holding one task each read as N and stay.

`run_after <= now()` matters for the same reason and is easier to miss: a task
backing off between retries is present in the table and unclaimable, so counting
it produces the same phantom demand. That predicate is also why exponential
backoff keeps the row continuously visible rather than holding it out of the
table — a task that vanished during backoff would make the autoscaler
under-provision exactly while work was pending.

`minReplicas: 0` is safe here: nothing ready and nothing running, no pod. It
depends on the reaper's clock ([pg_cron](install.html#pg_cron-if-you-want-schedules)),
because a task left `running` by a pod that died counts until
`reap_stale_tasks()` returns it to `ready`.

<p class="related"><strong>Related</strong>
<a href="failure.html#crash-recovery">what happens to work a scaled-down pod was
holding</a> ·
<a href="ingest.html">why the ingest queue is bursty</a></p>
</details>

## Rate limits

What we are trying to do here is throttle a source in a way that works with any
worker, including one somebody else wrote.
{: .goal }

<!-- run: sql -->
```sql
insert into workflow.rate_limits (key, capacity, tokens, refill_rate)
values ('openai-completions', 20, 20, 1);
```

<details class="why" markdown="1">
<summary>Why it works — the throttle is in claiming, not in the client</summary>

You set `rate_key` on a step and add a row to `workflow.rate_limits`.
`claim_task` consumes the key as part of claiming, so the throttle applies to
every worker rather than depending on each client implementing the same backoff
correctly.

`rate_lookahead` on the queue config lets a claimer look past a throttled task
rather than stalling behind it, so one rate-limited source does not block an
unrelated one sharing a queue.

The failure to know about is that `rate_key` is a **reference**, not a
declaration. Naming a bucket that does not exist means `claim_task` never hands
the task out — to anybody, forever — with no error and no attempt recorded.

<p class="related"><strong>Related</strong>
<a href="recipes.html#a-throttle-has-to-exist-before-a-step-names-it">the
missing-bucket failure in full</a> ·
<a href="grammar-workflow.html">where `rate_key` sits on a step</a></p>
</details>

## What to watch

| View | Answers |
|---|---|
| `workflow.v_backlog` | per queue: claimable, running, and **how long the oldest has waited** |
| `workflow.v_unclaimable` | work no worker will ever pick up, with the statement that fixes it |
| `workflow.v_capacity` | connection headroom, which runs out before throughput does |
| `workflow.check_hot_paths()` | whether the claim path is still index-backed at depth |
| `workflow.v_stuck_tasks` | not moving, **and** not making progress |
| `workflow.v_lease_violations` | a reaped worker tried to publish its result |
| `workflow.encoding_drift()` | a producer returning double-encoded JSON |
| `content.check_drift()` | files no resource points at; resources never chunked |
| `workflow.compiler_capabilities()` | the installed parser versus the SQL schema |

<details class="why" markdown="1">
<summary>Why it works — the first one has a lesson worth generalising</summary>

A view of `heartbeat_at` alone cannot see a crash loop, because every claim
refreshes it, so the failure keeps resetting the signal that is meant to reveal
it. That is worse than having no view, because somebody is watching it and
concluding things are fine. `v_stuck_tasks` therefore pairs the two.

Pair staleness with progress. "Not moving" and "moving and getting nowhere" are
different failures, and a monitor detecting only the first will report health
during the second.

<p class="related"><strong>Related</strong>
<a href="failure.html#what-to-watch">the same views from the failure side</a></p>
</details>

## Traces — where a slow answer actually went

The views above answer *what is stuck*. They cannot answer *why this one answer
took eleven seconds*, because that time is spread across a model call, four tool
calls and two delegated sub-agents, and the rows record each of those separately.
A trace is the shape that puts them back together.

The agent runtime speaks OpenTelemetry, and it is **off unless you point it
somewhere** — set the endpoint and it starts, unset and it costs nothing. It
needs the extra: `percolate-core[otel]` carries the SDK and the OTLP exporter,
and a runtime installed without it exports nothing rather than failing. The
collector's metrics half — the views above, read as metrics — needs no extra
and works on any install:

```bash
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318
export OTEL_SERVICE_NAME=percolate-agent-runtime
```

Install the exporter with the extra: `pip install 'percolate-core[agent,otel]'`.

What arrives is mostly not ours. pydantic-ai emits the
[GenAI semantic conventions](https://opentelemetry.io/docs/specs/semconv/gen-ai/)
for every model request and tool call — `gen_ai.request.model`,
`gen_ai.operation.name`, token counts, `gen_ai.conversation.id`. Percolate adds
one span around the turn carrying the ids that join a trace to a row:

| Attribute | Joins to |
|---|---|
| `percolate.run.id` | `agentic.runs.id` |
| `percolate.run.session_id` | `agentic.sessions.id` |
| `percolate.run.parent_run_id` | the delegating run |
| `percolate.run.depth` | how deep in the delegation tree |
| `percolate.usage.*` | what the turn spent, the same figure the row carries |

The nesting is the point. A delegated turn is a child span of the turn that
delegated it, so **the delegation tree and the trace tree are one tree** — which
is what a trace viewer draws well and SQL draws badly:

```
percolate.turn researcher                 775ms   run d04a…  depth 0
└── invoke_agent researcher               772ms
    ├── chat gpt-5                        203ms   ← asks for the tool
    ├── execute_tool consult_summarizer   360ms
    │   └── percolate.turn summarizer     359ms   run 7a5f…  depth 1
    │       └── invoke_agent → chat       352ms
    └── chat gpt-5                        202ms   ← the final answer
```

A delegated turn hangs off the parent's `execute_tool` span, because a
delegation *is* a tool call — which is why no new event type was needed for it.
The shape above is a real capture, not a sketch: it is where the 775ms went.

**Prompts and completions are not exported by default.** `include_content` puts
message bodies in span attributes, which walks them straight out of the
database's RLS and into whatever you pointed OTLP at. `P8_OTEL_CONTENT=1` opens
that deliberately, for a debugging session, on a backend you trust.

### Turning it on

Two commands. The first brings up a backend to look at; the second starts
percolate wired to it.

```bash
compose/observability/signoz.sh up

docker compose -f compose/docker-compose.yml \
               -f compose/observability.yml up -d
```

SigNoz is then on <http://localhost:3301> — **not 8080**, which the agent
already uses. Ask the agent something and the turn appears under the service
`percolate-agent-runtime`; `percolate.run.id` on that span is the `agentic.runs`
row. Logs ride the same connection, so the lines a turn wrote land beside the
trace it wrote them during.

The overlay adds one service, `p8-collector`, and sets two variables on the
agent. That collector is percolate's own: it relays what the runtime emits and
reads the views below as metrics, exporting OTLP to whatever `P8_OTLP_BACKEND`
names. Nothing in its config mentions SigNoz — point it at Grafana, Datadog,
Honeycomb or a collector you already run and none of the queries change.

SigNoz itself is deliberately **not** vendored here. It is seven services, five
ClickHouse config files and a startup download; copying that in would mean this
repository owning their upgrade path. `signoz.sh` fetches their own compose at a
pinned ref and runs it unmodified.

<details class="why" markdown="1">
<summary>Why that script exists — two steps that look like a bug in your stack</summary>

**An organisation must exist before anything can be ingested.** Until one does,
SigNoz's collector cannot register and *refuses every OTLP connection*. The
backend logs `cannot create agent without orgId`; the sender sees `Connection
reset by peer`, and a plain `curl` at the ingest port fails identically — so it
reads as a network fault on your side rather than a setup step on theirs. The
script POSTs the registration, and fails loudly rather than shrugging, because
the first version of it reported "already set up" for a password the policy had
rejected and left the whole thing silently broken.

That policy: 12+ characters, with an uppercase, a lowercase, a digit and a
symbol. A rejection arrives as a bare `400`.

**"The containers are up" is not "it accepts telemetry".** On a fresh volume the
collector runs `migrate sync check` and does not open its receivers until
ClickHouse has every schema migration — around ninety seconds. The script waits
for a real `200` on the ingest port before printing success, because otherwise
you go off and configure an exporter against a backend that will reject
everything for the next minute and a half.

</details>

## Postgres itself — percolate's rows as metrics

Traces come from the runtime, live. Everything above under "What to watch" is a
**row**, and only Postgres knows it — queue depth, oldest wait, connection
headroom, runs by outcome. So the collector reads them.

This ships. `compose/observability/percolate-collector.yaml` points the
collector's `sqlquery` receiver at **the same views** in the table above, which
is the reason to do it this way rather than writing metrics against the base
tables: there is no second definition of backlog to drift from the first.

| Metric | From |
|---|---|
| `percolate.queue.claimable`, `.running`, `.backing_off`, `.waiting_on_a_person`, `.workers_seen` | `workflow.v_backlog`, per queue |
| `percolate.queue.oldest_wait_seconds` | `v_backlog` — **the one to alert on** |
| `percolate.queue.unclaimable` | `workflow.v_unclaimable` |
| `percolate.tasks.stuck` | `workflow.v_stuck_tasks` |
| `percolate.db.connections_in_use`, `.connection_headroom` | `workflow.v_capacity` |
| `percolate.agentic.runs` | `agentic.runs`, by status |
| `percolate.agentic.max_delegation_depth` | how deep trees actually go |

Depth alone is ambiguous — a deep queue being drained quickly is healthy. How
long the oldest item has waited is not, which is why `oldest_wait_seconds` is
the alerting signal rather than `claimable`.

Adding one is a query and a name:

```yaml
- sql: "select tenant, count(*) as n from content.resources group by tenant"
  metrics:
    - metric_name: percolate.content.resources
      value_column: n
      attribute_columns: [tenant]
      value_type: int
```

<details class="why" markdown="1">
<summary>Two things that look like a broken scrape and are not</summary>

**A query returning no rows produces no series.** `v_backlog` aggregates by
queue, so on a stack with no work it is *empty* — not zero, absent — and
`percolate.queue.claimable` simply does not appear until something is enqueued.
The whole-table counts (`unclaimable`, `stuck`, the connection pair) always
return their single row, so those are the ones to check when deciding whether
the collector is alive.

**An interval is not a number.** `v_backlog.oldest_wait` is an `interval`,
because a person reads it. A metric has to be scalar, so the shipped query wraps
it: `coalesce(extract(epoch from oldest_wait), 0)`. Selecting the column
directly fails.

</details>

### Do not reach for the `postgresql` receiver

It is the obvious choice and it does not work here. It parses `version()` with
`strconv.Atoi`, and percolate ships on a Postgres 19 **beta**, so every scrape
fails:

```
strconv.Atoi: parsing "19beta3 (Debian 19~beta3-1": invalid syntax
```

Nothing is wrong with your configuration — the receiver cannot read the version
string. `sqlquery` is unaffected because it runs only the SQL you gave it, and it
reports percolate's own state rather than the server's internal statistics, which
is what you wanted from a percolate dashboard anyway. Revisit at a stable 19.

## Work nobody can claim

Some failures produce no error anywhere, and this is the one to know about
because the engine gives no other signal.

What we are trying to do here is find tasks that no worker will ever pick up.
{: .goal }

<!-- run: sql -->
```sql
select reason, count(*), min(waiting) from workflow.v_unclaimable group by 1;
select remedy from workflow.v_unclaimable limit 1;
```

<div class="evidence" markdown="1">
<div class="label">workflow.v_unclaimable</div>

```
                      reason                      | count |  waiting
--------------------------------------------------+-------+----------
 rate_key names no bucket in workflow.rate_limits |     3 | 00:04:11

remedy: insert into workflow.rate_limits (key, capacity, tokens, refill_rate)
        values ('openai-completions', 20, 20, 1);
```
</div>

<details class="why" markdown="1">
<summary>Why it works — `v_stuck_tasks` cannot see this, and the reason is
subtle</summary>

`rate_key` is a **reference** to a row in `workflow.rate_limits`, not a
declaration of one. `claim_task` consumes from that bucket with
`update … where key = $1`, which matches nothing when the bucket does not exist
and therefore returns false — every time, forever. The task sits in `ready`, no
worker claims it, no attempt is recorded, nothing retries, and the worker beside
it reports an empty queue.

`v_stuck_tasks` reports tasks that are **old**, and a freshly created
unclaimable task is not old yet. It surfaces there an hour later, described as
something else. This view asks the structural question instead — is there a
bucket for this key — so it is right immediately.

The `remedy` column is the statement that fixes it, rather than a description of
the fix. A diagnostic you can paste is one you will actually use.

<p class="related"><strong>Related</strong>
<a href="#rate-limits">setting a bucket up first</a> ·
<a href="scaling.html">what else the scale work found</a></p>
</details>

## Retention — the task table only ever grew

Nothing in this engine deleted a task, so `workflow.tasks` grew without bound.
That is not only a disk question: the autoscaler's own probe changes plan on the
ratio of live rows to total rows, so an unbounded table degrades the thing that
decides how many workers you get.

What we are trying to do here is drop runs that finished long enough ago to stop
mattering.
{: .goal }

<!-- run: sql -->
```sql
select * from workflow.purge_completed(interval '30 days');
```

<div class="evidence" markdown="1">
<div class="label">workflow.purge_completed</div>

```
 batches | runs_purged | tasks_purged | runs_skipped
---------+-------------+--------------+--------------
       1 |           1 |        20000 |            1
```
</div>

<details class="why" markdown="1">
<summary>Why it works — it batches by run, and tells you what it could not
take</summary>

**By run rather than by task**, because tasks reference each other within a run
— a compensation points at what it undoes, a fan-out child at its parent — and
both are `NO ACTION`. A batch that split a run would block on its own siblings.

**Batched at all**, because deleting a million task rows in one statement takes
tens of minutes: every row costs an index update per index plus a foreign-key
probe, and it all accumulates in one transaction. Each batch here commits on its
own.

`runs_skipped` is the column to read when the table is not shrinking. A run is
held back if a schedule still points at it as `last_run_id`, if a sub-workflow
parent references it as a child, or if an agent run records one of its tasks —
all legitimate, all invisible without being told.

It keys on `completed_at` rather than `updated_at`, because `runs.updated_at` is
maintained by a touch trigger and therefore means *last modified*: retention on
it would be retention on when somebody last looked at the run.

<p class="related"><strong>Related</strong>
<a href="scaling.html">why an unbounded table costs you</a> ·
<a href="#backup-and-the-two-things-not-in-the-database">what a purge means for
backups</a></p>
</details>

## Version skew

What we are trying to do here is find out whether the compiled parser and the
SQL schema still agree, without comparing version strings.
{: .goal }

<!-- run: sql -->
```sql
select workflow.compiler_capabilities();
```

<div class="evidence" markdown="1">
<div class="label">a build that predates several features</div>

```
{"accepts": {"matrix": false, "output_schema": false, …},
 "missing": ["continue_on", "matrix", "output_schema", "signal", "sub_workflow", "timer"]}
```
</div>

<details class="why" markdown="1">
<summary>Why it works — a missing step kind fails loudly and a missing contract
does not</summary>

The compiled parser and the SQL schema ship independently and will eventually
disagree, so this probes the installed build with one canary per feature rather
than trusting a version number.

`define_yaml` refuses a document declaring anything in `missing`, **including
when it compiles cleanly**. A missing step kind fails on its own, but
`output_schema` is not a kind: serde drops the unknown key, the document
compiles, and the contract you wrote is simply not there at run time. If you
write a contract and get a green run, you would reasonably assume it was
enforced.

<p class="related"><strong>Related</strong>
<a href="authoring.html#three-things-get-refused-rather-than-ignored">the three
refusals</a></p>
</details>

## Payload limits

Task `input` and `output` are capped by `workflow.max_payload_bytes`, 64KB by
default. Over the limit a task fails terminally, since the same response will be
the same size on every attempt — unless the worker offloaded the bytes, in which
case it completes carrying a `$artifact` ref.

<details class="why" markdown="1">
<summary>Why it works — raise it if you need to, but write down that you did</summary>

A cap set with `ALTER DATABASE` and recorded in no configuration file is how a
fresh environment and a long-lived one end up disagreeing with nothing reporting
it. The symptom arrives much later, as a workflow that works in production and
fails in staging for reasons nobody can reproduce.

<p class="related"><strong>Related</strong>
<a href="outputs.html#4-everything-else-is-bytes">what an artifact ref is</a></p>
</details>

## Backup, and the two things not in the database

Almost everything is in Postgres, which makes backup pleasantly boring: a normal
`pg_dump` or PITR setup captures workflow state, agent conversations, identity
and the graph. Two things are not covered by it.

<details class="why" markdown="1">
<summary>Why it works — and where the reconciliation has to happen outside</summary>

**Object storage.** Artefacts and uploaded files are pointers in `content.files`
and the bytes are in your bucket. `content.check_drift()` reports the half of the
reconciliation the database can see — *no resource points at this file* — and the
other half is a bucket listing compared against it, which nothing here can do for
you.

**Secrets.** `credential_ref` is a name resolved from the worker's environment.
That is exactly what makes a dump safe to hand around, and also why restoring one
into an environment without those names gives you tasks that fail at dispatch
rather than tasks that work.

<p class="related"><strong>Related</strong>
<a href="recipes.html#keys-are-names-never-values">every place a credential is
named rather than stored</a> ·
<a href="ingest.html">what else lives in object storage</a></p>
</details>

### Restoring one

A restore is not `psql -f dump.sql` into an empty database, and the reason is a
safety property rather than an inconvenience: the extension **refuses to install
as a superuser**, and a dump's own `CREATE EXTENSION percolate` runs as whoever
invoked `psql`. Install the extension the documented way first, then load only
the data.
{: .goal }

```bash
# 1. the target, with roles and the extension, exactly as a fresh install
psql -U postgres -d postgres -c 'create database percolate_restored'
psql -U postgres -d percolate_restored -f bootstrap.sql

# 2. the data, from a --data-only dump of the source
pg_dump -U postgres -d percolate --data-only -f data.sql
psql -U postgres -d percolate_restored -f data.sql
```

<details class="why" markdown="1">
<summary>Why the extension has to go in first, and what a restore does not carry</summary>

**Superuser is refused on purpose.** A superuser bypasses row-level security
unconditionally, so an extension installed by one would leave every
owner-privileged view returning all rows to every caller. `bootstrap.sql` creates
the roles and installs as `app_owner`, which is the same path a first install
takes — so a restored database is a normal one, not a special case.

**The dump sets an empty `search_path`**, which is what makes it hermetic, and
that in turn means every trigger firing during `COPY` resolves nothing but
`pg_catalog`. Functions here pin `search_path = pg_catalog, public` for exactly
that reason; `dev/restore-is-possible.sh` in the source repo does this whole
round trip on every gate run, because "the backup contains the rows" and "the
rows go back in" are two questions and only the first used to be asked.

**Three things a `--data-only` restore does not bring back**, so check them
rather than assume:

- the `cron` schema and its jobs, if the source had `pg_cron` — install it in
  the target and re-create the schedules
- per-model embedding tables (`aiq.emb_<model>`), which are created when a model
  is first used rather than by the extension. Re-run an embedding and they come
  back; the vectors in them do not
- object storage and secrets, for the reasons in the section above

<p class="related"><strong>Related</strong>
<a href="install.html">what <code>bootstrap.sql</code> does</a></p>
</details>

## Upgrading

What we are trying to do here is move the schema forward and then check that the
two release trains still agree.
{: .goal }

<!-- run: sql -->
```sql
set role app_owner;               -- so new objects are owned as a fresh install's are
alter extension percolate update;
reset role;

select * from workflow.compiler_capabilities();   -- parser vs schema
```

`set role app_owner` is the step that keeps row-level security working: an
update creates its new objects as whoever runs it, and a superuser owner
bypasses every policy on them ([install](install.html#docker-compose) has the
longer version).

The schema ships as one extension; the worker and services are a separate
release train and are compatible across a minor version. Check `missing` after
any upgrade, because the failure mode of not checking is a document that
compiles and does less than it says.

That is the end of the guide. The
[source repository](https://github.com/Percolation-Labs/get-percolate) has the
compose file, the Helm chart and these pages.
