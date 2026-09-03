# Scaling

Numbers rather than adjectives. Everything here was measured against PostgreSQL
19beta3 with `dev/scale/run.sh` in the specs repository, and the environment is
named at the bottom because a benchmark without one is not a benchmark.
{: .lede }

The short version is that this engine has three hot paths, all of them are
queries, and the one that matters most had an index that did not match it — so
if you are running an older build, the first section is the one to read.

## The claim path is the only query that really matters

Every worker runs it on every task, so its cost is multiplied by worker count and
by backlog depth at the same time. Nothing else in the engine is.

What we are trying to do here is check that claiming a task from a deep queue
uses an index rather than sorting the backlog.
{: .goal }

```sql
explain (analyze, buffers, costs off)
select * from workflow.tasks
where queue = 'http' and status = 'ready' and run_after <= now()
order by priority desc, created_at
for update skip locked limit 20;
```

<div class="evidence" markdown="1">
<div class="label">200,000 ready tasks, 8 concurrent workers, 10s</div>

```
index (queue, priority, run_after)              78.7 claims/s   101.7 ms mean
index (queue, priority desc, created_at)    13,965.3 claims/s     0.57 ms mean
```
</div>

The same comparison on a three-node cluster, with the database on one node and
the workers on others so every claim crosses a network hop:

<div class="evidence" markdown="1">
<div class="label">kind, 2 pods × 4 connections, bounded at 40,000 claims</div>

```
index (queue, priority, run_after)              43.6 claims/s   183.4 ms mean
index (queue, priority desc, created_at)     9,406.7 claims/s     0.85 ms mean
```
</div>

Lower throughput and higher latency than a single box, which is the network and
is the number to plan against.

<details class="why" markdown="1">
<summary>Why it works — the index has to match the ORDER BY, and when it does not
the planner sorts the whole backlog</summary>

The claim orders by `priority desc, created_at`. An index of
`(queue, priority, run_after)` does not contain `created_at` at all, so it cannot
supply that order — and because every row in a deep queue matches
`status = 'ready'`, the index offers no selectivity either. The planner correctly
concludes a sequential scan plus a sort is cheaper, and then sorts the entire
ready set to return twenty rows:

```
Seq Scan on tasks (rows=200000) -> Sort (external merge Disk: 38800kB)
Execution Time: 73.269 ms
```

Thirty-eight megabytes of temp I/O, per claim, per worker. With the index
matching the sort it is an index scan that stops after twenty rows:

```
Index Scan using idx_tasks_claimable (rows=20)
Buffers: shared hit=22 read=2
Execution Time: 0.069 ms
```

**This is flat in the backlog** — 0.069 ms at 200k ready, 0.044 ms at 1M — which
is the property you actually want. Depth stops mattering.

`priority desc` is spelled out rather than left to a reverse scan because the
mixed direction (`desc` then `asc`) cannot be served by reading one index
backwards; that would reverse both keys.

<p class="related"><strong>Related</strong>
<a href="operating.html#scaling-on-queue-depth">what the autoscaler reads</a></p>
</details>

## Polling is cheaper than it sounds

Workers do not wait to be told about work. Each one claims on a loop, and sleeps
for `P8_POLL_SECONDS` (default 2) only when it found nothing.

What we are trying to do here is see what an idle worker costs the database.
{: .goal }

<div class="evidence" markdown="1">
<div class="label">a claim against an empty queue</div>

```
Index Scan using idx_tasks_claimable (rows=0)
Buffers: shared hit=8
Execution Time: 0.044 ms
```
</div>

<details class="why" markdown="1">
<summary>Why it works — the poll only runs when a worker is idle, and the index
holds only claimable rows</summary>

Two properties make this cheap in the way that matters.

`idx_tasks_claimable` is partial on `status = 'ready'`, so it contains only
claimable rows. It is sized by the backlog rather than by the table — 1.3 MB for
200k ready tasks against a 66 MB table. An empty queue is an empty index probe.

And the sleep happens only when the claim returned nothing. A worker that claimed
something loops straight back and claims again, so under load there is no polling
at all. **Polling cost is inversely proportional to utilisation**: it is highest
when the system is doing nothing and has the capacity to serve it.

That gives a cost of `workers ÷ interval` trivial queries per second,
**independent of task rate**. Fifty workers at two seconds is 25 index probes a
second.

The cost you do pay is latency: a mean of `interval/2` before an idle worker
notices new work. If that matters on an interactive queue, lower
`P8_POLL_SECONDS` — two seconds to 250 ms is eight times the poll rate on a
0.044 ms query, which is still nothing.

<p class="related"><strong>Related</strong>
<a href="grammar-workflow.html#queries-that-need-no-process">the steps that need
no worker at all</a></p>
</details>

## Adding workers is the scaling mechanism

The layer that actually scales is not how attentive one worker is. It is how
many there are, and that is a query the autoscaler runs.

What we are trying to do here is let the pool size follow the work that is
actually waiting.
{: .goal }

```sql
select workflow.queue_depth('http');
```

<details class="why" markdown="1">
<summary>Why it works — `SKIP LOCKED` makes a worker joining or leaving cost no
coordination</summary>

`claim_task` selects `for update skip locked`, so two workers reaching for the
same row simply do not collide — the second skips it and takes the next. Nothing
tracks how many workers exist, nothing assigns work to one, and adding or
removing a worker requires no rebalance. Compare a partitioned log, where adding
a consumer triggers a group rebalance and a stop-the-world pause.

That is what makes autoscaling on depth safe: KEDA can take a pool from zero to
twenty and back without the engine knowing or caring.

Measured throughput on a 10-core host, claiming from a deep queue:

<div class="evidence" markdown="1">
<div class="label">claims/s by client count</div>

```
 1 client     5,131 claims/s    0.20 ms mean
 8 clients   14,243 claims/s    0.56 ms mean
32 clients   10,334 claims/s    3.10 ms mean
```
</div>

The regression at 32 is oversubscription on ten cores rather than a contention
limit in the engine — worth knowing as the shape to expect, which is that more
workers than cores stops helping before it starts hurting badly.

**`queue_depth()` is in the hot path too**, because a 30-second cadence per pool
is a hot path. It counts ready-and-due plus running, and what the planner does
depends on how much of the table is live: with a small backlog it answers from
the existing partial indexes in 92 buffers, and with a large one it can fall back
to a sequential scan. `idx_tasks_live` gives it an index-only scan — 867 buffers
instead of 30,733 on a million-row table with a 300k backlog.

<p class="related"><strong>Related</strong>
<a href="operating.html#scaling-on-queue-depth">the KEDA configuration</a> ·
<a href="operating.html#rate-limits">throttling a source instead of a pool</a></p>
</details>

## Fan-out and fan-in stay linear

A `matrix` step expands into N children and a successor waits on all of them.
Completing those children is the one place an accidental quadratic would hide.

What we are trying to do here is confirm that a wide fan-in costs N and not N².
{: .goal }

<div class="evidence" markdown="1">
<div class="label">completing N children that feed one successor</div>

```
  100 children     7.4 ms    74 us/child
  500 children    27.1 ms    54 us/child
 2000 children   157.1 ms    78 us/child
```
</div>

<details class="why" markdown="1">
<summary>Why it works — the reverse dependency index, and the reason a fan-in
reads a handle</summary>

`cascade_task_status` fires on each completed child and decrements
`pending_deps` on every task that depended on it. `idx_task_deps_reverse` on
`depends_on_task_id` is what keeps that a lookup rather than a scan, so the cost
stays around 75 µs per child however wide the fan gets.

This is also the reason a fan-in reads `workflow.matrix_outputs(task_id)` rather
than a template. Children do not write into `runs.context`, because one JSONB
column rewritten in full on every completion would give quadratic write
amplification precisely as the fan gets wide — which is the case you built a
fan-out for.

<p class="related"><strong>Related</strong>
<a href="outputs.html#2-the-database-is-the-state">why a step returns a
receipt</a> ·
<a href="grammar-workflow.html#matrix-the-work-to-do-is-a-query-result">the
matrix keys</a></p>
</details>

## What happens when a worker dies holding work

A pod is evicted, a node drains, a process is OOM-killed. The task it had claimed
is sitting in `running` with a lease nobody is refreshing.

What we are trying to do here is get that work back without ever taking it from a
worker that is merely slow.
{: .goal }

```sql
select workflow.reap_stale_tasks();   -- one pg_cron job, once a minute
```

<div class="evidence" markdown="1">
<div class="label">2,000 tasks stranded by pods that no longer existed</div>

```
reaper while the leases were fresh (< 2 min)   reaped = 0
reaper once they aged past the timeout         reaped = 258
convergence over three passes                  84 -> 888 -> 269 -> 0 running
```
</div>

<details class="why" markdown="1">
<summary>Why it works — it reaps by lease age, so a slow worker and a dead one are
not confused</summary>

The first line is the one that matters. A reaper that requeued everything in
`running` would take work from a worker that was simply taking a while, and then
two workers would be doing the same task. This one reaps only leases older than
the queue's `stale_timeout` (two minutes by default), so a live-but-slow worker
keeps its task.

Every reaped task came back to `ready` with `attempts` incremented, so a task
that strands repeatedly still hits `max_attempts` and fails the run rather than
looping forever.

And the worker that died cannot come back and overwrite the retry's answer: the
lease fence refuses a `complete_task` from a reaped claim, and records the
refusal in `v_lease_violations` rather than discarding it.

<p class="related"><strong>Related</strong>
<a href="failure.html#crash-recovery">the lease fence</a> ·
<a href="install.html#pg_cron-if-you-want-schedules">why the reaper needs
`pg_cron`</a></p>
</details>

## The connection budget is what limits worker count

Throughput is not what you run out of first. Connections are.

What we are trying to do here is size a worker pool against the database's
connection limit rather than against its throughput.
{: .goal }

<div class="evidence" markdown="1">
<div class="label">30 pods × 4 connections against max_connections = 100</div>

```
FATAL:  sorry, too many clients already
```
</div>

<details class="why" markdown="1">
<summary>Why it works — and why the failure is worse than tasks stopping</summary>

The refusal reached the operator too. The role in that test was a superuser and
`superuser_reserved_connections` was 3, and a `psql` was still refused: thirty
pods reconnecting in a tight loop win the race for three reserved slots. So the
failure mode of connection exhaustion is not that work stops — it is that **you
cannot get in to find out why**.

Two things follow when you size a pool.

**Cap `maxReplicas` against `max_connections` on purpose.** A pool scaling on
queue depth will happily grow past the connection budget, because depth says
nothing about connections. Either put a pooler in front, or pick the ceiling
deliberately.

**This is the concrete reason workers poll rather than `LISTEN`.** A listening
connection is session state and cannot be pooled in transaction mode, so a
listening worker holds a dedicated backend for its whole life. The ceiling that
took thirty polling pods to reach would arrive at exactly `max_connections`
listening workers, and no pooler could move it.

<p class="related"><strong>Related</strong>
<a href="#polling-is-cheaper-than-it-sounds">what the poll actually costs</a> ·
<a href="operating.html#scaling-on-queue-depth">setting `maxReplicas`</a></p>
</details>

## Sizing

Enough to plan with, measured rather than assumed.

| | |
|---|---|
| A task row | ~340 bytes — 66 MB for 200k, 338 MB for 1M |
| The claim index | 1.3 MB at 200k ready, 6.4 MB at 1M |
| Task payload | capped at `workflow.max_payload_bytes`, 64 KB by default |
| Claim latency | 0.07 ms at 200k ready, 0.04 ms at 1M — flat in depth |
| Claim throughput | ~14,000/s at 8 workers on 10 cores |

<details class="why" markdown="1">
<summary>Why it works — the payload cap is what keeps a task row small enough for
this to hold</summary>

Three hundred and forty bytes a row is only true because a step's output is
capped. A step that returned its rows instead of a receipt would put the data
plane in the task table, and both the row size and every index built over it
would grow with it.

That is the practical reason behind the advice on
[what a step leaves behind](outputs.html): the cap is not a limitation to work
around, it is what makes a million-task backlog a third of a gigabyte instead of
a problem.

<p class="related"><strong>Related</strong>
<a href="outputs.html">the four output classes</a> ·
<a href="operating.html#payload-limits">raising the cap, and writing it
down</a></p>
</details>

## The environment these numbers came from

| | |
|---|---|
| PostgreSQL | 19beta3, `percolate @@extension@@` |
| Host | 10 cores, Docker Desktop on macOS |
| `shared_buffers` | 128 MB (the image default) |
| `work_mem` | 4 MB (the image default) |
| Load | `pgbench` as the `worker` role, calling `workflow.claim_task` |

`work_mem` is the one to adjust when comparing against your own numbers: it
decides whether a sort spills to disk, so a deployment that has raised it will
see smaller differences than the ones above.

The harness is `dev/scale/` in the specs repository, and it is meant to be re-run
rather than trusted. It asserts the *plan* and not only the time, because the
failure it exists to catch is the planner quietly abandoning an index.

Next: [operating it](operating.html).
