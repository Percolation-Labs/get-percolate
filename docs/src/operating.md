# Operating it

What to scale, what to watch, and which audits will tell you the truth without
being asked nicely.
{: .lede }

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
  - name: agents
    queue: agents
    replicas: 2
```

```sql
-- the KEDA trigger, which is a SQL query rather than a CPU metric
select count(*)::int from workflow.tasks
where queue = 'http' and status = 'ready' and run_after <= now()
```

<details class="why" markdown="1">
<summary>Why it works — `status = 'ready'` rather than a row count, and the
difference costs money</summary>

A pending task blocked on a dependency is not work that anyone can do. Counting
it scales up pods that find nothing and then scale back down, which costs money
and looks like demand on every dashboard you have.

`run_after <= now()` matters for the same reason and is easier to miss: a task
backing off between retries is present in the table and unclaimable, so counting
it produces the same phantom demand. That predicate is also why exponential
backoff keeps the row continuously visible rather than holding it out of the
table — a task that vanished during backoff would make the autoscaler
under-provision exactly while work was pending.

`minReplicas: 0` is safe here. No ready task, no pod.

<p class="related"><strong>Related</strong>
<a href="failure.html#crash-recovery">what happens to work a scaled-down pod was
holding</a> ·
<a href="ingest.html">why the ingest queue is bursty</a></p>
</details>

## Rate limits

What we are trying to do here is throttle a source in a way that works with any
worker, including one somebody else wrote.
{: .goal }

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

`v_stuck_tasks` originally could not see a crash loop at all, because every
claim refreshes `heartbeat_at`, so the failure kept resetting the signal that was
meant to reveal it. That is worse than having no view, because somebody is
watching it and concluding things are fine.

Pair staleness with progress. "Not moving" and "moving and getting nowhere" are
different failures, and a monitor detecting only the first will report health
during the second.

<p class="related"><strong>Related</strong>
<a href="failure.html#what-to-watch">the same views from the failure side</a></p>
</details>

## Work nobody can claim

Some failures produce no error anywhere, and this is the one to know about
because the engine gives no other signal.

What we are trying to do here is find tasks that no worker will ever pick up.
{: .goal }

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

## Upgrading

What we are trying to do here is move the schema forward and then check that the
two release trains still agree.
{: .goal }

```sql
alter extension percolate update;

select * from workflow.compiler_capabilities();   -- parser vs schema
```

The schema ships as one extension; the worker and services are a separate
release train and are compatible across a minor version. Check `missing` after
any upgrade, because the failure mode of not checking is a document that
compiles and does less than it says.

That is the end of the guide. The
[source repository](https://github.com/percolating-sirsh/get-percolate) has the
compose file, the Helm chart and these pages.
