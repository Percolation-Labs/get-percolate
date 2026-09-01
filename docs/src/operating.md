# Operating it

What to scale, what to watch, and which audits will tell you the truth without
being asked nicely.
{: .lede }

## Scaling on queue depth

`queue` is the only signal that both `claim_task` and an autoscaler see, so one
worker pool per queue is how a slow model endpoint stops starving a fast
ingestion queue — and the [ingest queue](ingest.html) is the one to watch
first, since a batch of uploads arrives all at once and then stops.

```yaml
workers:
  - name: http
    queue: http
    autoscaling: {enabled: true, minReplicas: 0, maxReplicas: 20, queueDepthPerPod: 25}
  - name: agents
    queue: agents
    replicas: 2
```

The KEDA trigger is a SQL query, because what you actually want to know is how
much work is waiting, and CPU does not tell you that:

```sql
select count(*)::int from workflow.tasks
where queue = 'http' and status = 'ready' and run_after <= now()
```

Note `status = 'ready'` rather than a row count of `workflow.tasks`. A pending
task blocked on a dependency is not work that anyone can do, and counting it
scales up pods which find nothing and then scale back down, which costs money
and looks like demand. `minReplicas: 0` is fine here: no ready task, no pod.

## Rate limits

You set `rate_key` on a task and add a row to `workflow.rate_limits`.
`claim_task` consumes the key as part of claiming, so the throttle works with
any worker including one you wrote, rather than depending on every client
implementing the same backoff.

## What to watch

| View | Answers |
|---|---|
| `workflow.v_stuck_tasks` | not moving, **and** not making progress |
| `workflow.v_lease_violations` | a reaped worker tried to publish its result |
| `workflow.encoding_drift()` | a producer returning double-encoded JSON |
| `content.check_drift()` | files no resource points at; resources never chunked |
| `workflow.compiler_capabilities()` | the installed parser versus the SQL schema |

The first one has a lesson in it. It originally could not see a crash loop at
all, because every claim refreshes `heartbeat_at`, so the failure kept resetting
the signal that was meant to reveal it. That is worse than having no view,
because somebody is watching it. Pair staleness with progress: "not moving" and
"moving and getting nowhere" are different failures.

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

`define_yaml` refuses a document that declares anything in `missing`, including
when it compiles cleanly. A missing step kind fails loudly on its own, but
`output_schema` is not a kind: serde drops the unknown key, the document
compiles, and the contract you wrote is not there at run time. If you write a
contract and get a green run you would reasonably assume it was enforced.

## Payload limits

Task `input` and `output` are capped by `workflow.max_payload_bytes`, 64KB by
default. Over the limit a task fails terminally, since the same response will be
the same size on every attempt, unless the worker offloaded the bytes in which
case it completes carrying a `$artifact` ref. See
[what a step leaves behind](outputs.html).

You can raise it, but write down that you did. A cap set with `ALTER DATABASE`
and recorded in no configuration file is how a fresh environment and a
long-lived one end up disagreeing without anything reporting it.

## Backup and the things that are not in the database

Almost everything is in Postgres, which makes backup pleasantly boring — a
normal `pg_dump` or PITR setup captures workflow state, agent conversations,
identity and the graph.

Two things are not:

- Object storage. Artefacts and uploaded files are pointers in `content.files`
  and the bytes are in your bucket. `content.check_drift()` reports the half of
  the reconciliation the database can see, which is "no resource points at this
  file", and the other half is a bucket listing compared against it.
- Secrets. `credential_ref` is a name resolved from the worker's environment.
  That is what makes a dump safe to hand around, and also why restoring one into
  an environment without those names gives you tasks that fail at dispatch.

## Upgrading

The schema ships as one extension. `ALTER EXTENSION percolate UPDATE` for a
version bump; the worker and services are a separate release train and are
compatible across a minor version. Check both after any upgrade:

```sql
select * from workflow.compiler_capabilities();   -- parser vs schema
\i surface.sql                                    -- every promised capability
```

That is the end of the guide. The
[source repository](https://github.com/percolating-sirsh/get-percolate) has the
compose file, the Helm chart and these pages.
