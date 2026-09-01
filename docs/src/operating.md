# Operating it

What to scale, what to watch, and which audits will tell you the truth without
being asked nicely.
{: .lede }

## Scaling on queue depth

`queue` is the only signal that both `claim_task` and an autoscaler see, so one
worker pool per queue is how a slow model endpoint stops starving a fast
ingestion queue.

```yaml
workers:
  - name: http
    queue: http
    autoscaling: {enabled: true, minReplicas: 0, maxReplicas: 20, queueDepthPerPod: 25}
  - name: agents
    queue: agents
    replicas: 2
```

The KEDA trigger is a SQL query, because the honest measure of "is there work"
is not CPU:

```sql
select count(*)::int from workflow.tasks
where queue = 'http' and status = 'ready' and run_after <= now()
```

Note `status = 'ready'`, not a row count of `workflow.tasks`. **A pending task
blocked on a dependency is not work anyone can do**, and counting it scales up
pods that will find nothing and scale back down — a loop that costs money and
looks like demand. `minReplicas: 0` is legitimate: no ready task, no pod.

## Rate limits

`rate_key` on a task plus a row in `workflow.rate_limits`. `claim_task` consumes
the key as part of claiming, so a throttle works with **any** worker — including
one you wrote — rather than depending on every client implementing the same
backoff.

## What to watch

| View | Answers |
|---|---|
| `workflow.v_stuck_tasks` | not moving, **and** not making progress |
| `workflow.v_lease_violations` | a reaped worker tried to publish its result |
| `workflow.encoding_drift()` | a producer returning double-encoded JSON |
| `content.check_drift()` | files no resource points at; resources never chunked |
| `workflow.compiler_capabilities()` | the installed parser versus the SQL schema |

The first one carries a lesson worth generalising. It originally could not see a
crash loop, because every claim refreshes `heartbeat_at` — so the failure reset
the signal that was supposed to reveal it. That is worse than having no view,
because someone is watching it. **Pair staleness with progress:** "not moving"
and "moving and getting nowhere" are different failures.

## Version skew

The compiled parser and the SQL schema ship independently and will eventually
disagree. `compiler_capabilities()` probes the installed build with a canary per
feature rather than trusting a version string:

<div class="evidence" markdown="1">
<div class="label">select workflow.compiler_capabilities()</div>

```
{"accepts": {"matrix": false, "output_schema": false, …},
 "missing": ["continue_on", "matrix", "output_schema", "signal", "sub_workflow", "timer"]}
```
</div>

`define_yaml` refuses a document declaring anything in `missing` — **including
when it compiles clean**, which is the whole point. A missing step *kind* fails
loudly. `output_schema` is not a kind: serde drops the unknown key, the document
compiles, and the declared contract simply is not there at run time. An author
who writes a contract and gets a green run reasonably concludes it is enforced.

## Payload limits

Task `input` and `output` are capped by `workflow.max_payload_bytes`, 64KB by
default. Over the limit, a task fails **terminally** — the same response is the
same size on every attempt — unless the worker offloaded the bytes, in which
case it completes carrying a `$artifact` ref. See
[What a step leaves behind](outputs.html).

Raise it deliberately if you must, and know that you have: a cap set by
`ALTER DATABASE` that appears in no configuration file is how a fresh
environment and a long-lived one end up disagreeing with nothing saying so.

## Backup and the things that are not in the database

Almost everything is in Postgres, which makes backup pleasantly boring — a
normal `pg_dump` or PITR setup captures workflow state, agent conversations,
identity and the graph.

Two things are not:

- **Object storage.** Artifacts and uploaded files are pointers in
  `content.files`; the bytes are in your bucket. `content.check_drift()` reports
  the half of the reconciliation the database can see — "no resource points at
  this file" — and the storage half is a bucket listing compared against it.
- **Secrets.** `credential_ref` is a name resolved from the worker's
  environment. That is why a dump is safe to hand around, and also why restoring
  one into an environment without those names gives you tasks that fail at
  dispatch.

## Upgrading

The schema ships as one extension. `ALTER EXTENSION percolate UPDATE` for a
version bump; the worker and services are a separate release train and are
compatible across a minor version. Check both after any upgrade:

```sql
select * from workflow.compiler_capabilities();   -- parser vs schema
\i surface.sql                                    -- every promised capability
```
