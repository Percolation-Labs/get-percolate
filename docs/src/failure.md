# Failure and retry

Retry is a decision rather than a default. The worker is the only thing that
knows what an HTTP status actually means, so the worker decides and the engine
goes with its answer.
{: .lede }

## Terminal or retryable

What we are trying to do here is tell the engine whether another attempt could
possibly help.
{: .goal }

```python
fail_task(task_id, error, terminal=True)   # do not retry, whatever attempts remain
fail_task(task_id, error, terminal=False)  # requeue with exponential backoff
```

| Failure | Class | Why |
|---|---|---|
| HTTP 4xx (except 408, 429) | terminal | the same request gets the same answer |
| HTTP 5xx, 429, connection error | retryable | transient by definition |
| Output over the payload limit | terminal | the same response is the same size every time |
| Output violating `output_schema` | retryable | the same prompt really can conform next time |
| Unregistered step function, missing handler | terminal | `pip install` does not run itself between attempts |
| Missing `credential_ref` | terminal | configuration, not weather |
| A `$artifact` that is not a resource uuid | terminal | the same string arrives every time |

<details class="why" markdown="1">
<summary>Why it works — the shape violation is the only one classified against
appearances</summary>

A 400 or a 404 will fail the same way every time, so retrying it five times with
backoff turns a fast failure into a slow one and burns your rate limit doing it.
A 5xx or a 429 is the server's problem and is worth another go.

The shape violation is the interesting row, because it looks like a bug and is
classified retryable anyway. Every other terminal classification exists because
retrying *cannot* help; here the same prompt genuinely can produce conforming
output on the next attempt, which turns `max_attempts` into a real budget for
asking again. Verified: a step whose endpoint violates its schema twice and
conforms on the third completes in three attempts.

The reason this decision belongs to the worker rather than to the engine is that
the engine sees a failed task and the worker saw the response. Handing the
classification to the engine would mean encoding HTTP semantics in PL/pgSQL and
getting them wrong for every protocol that is not HTTP.

<p class="related"><strong>Related</strong>
<a href="grammar-workflow.html#agent-steps-sessions-and-declared-shapes">what
`output_schema` checks</a> ·
<a href="outputs.html">why an oversized output is terminal</a></p>
</details>

## Fan-out and partial failure

A matrix over real data will hit a missing value, a rate limit or an oversized
response on more or less every run.

What we are trying to do here is let a child failure be a result rather than an
outage, while still refusing to aggregate over too little.
{: .goal }

```yaml
  - id: run
    matrix:
      rows: {function: labelled_sample, args: ['gazette', 30]}
      continue_on: failed
      min_success: 20
      template: {agent: extractor, input: '{{item.text}}'}
```

<details class="why" markdown="1">
<summary>Why it works — the floor exists so a partial answer cannot report
success</summary>

`continue_on: failed` makes a failed child satisfy its dependents. `min_success`
is the floor below which the aggregate is **cancelled** rather than run on
partial data, because a summary computed over 3 of 30 documents that reports
success is worse than no summary at all. It takes a fraction when it is ≤ 1 and
an absolute count when it is > 1.

Declaring `min_success` without `continue_on` is refused by name: without it the
first failed child cancels the successors, so the threshold could never be
reached and the key would be decoration.

It is a **transport** floor rather than a content one — a 200 carrying an empty
body counts as a success against it. The engine cannot know what a good result
looks like, so the threshold answers *did enough calls come back* and the
declared shape answers the rest.

In an evaluation the polarity flips. The fraction of documents an extractor
cannot parse is the measurement you wanted, so an eval sets `continue_on: failed`
with no floor at all.

<p class="related"><strong>Related</strong>
<a href="grammar-workflow.html#matrix-the-work-to-do-is-a-query-result">every
matrix key</a> ·
<a href="recipes.html#4-one-specialist-per-document-type-over-a-backlog">a
backlog that uses both</a></p>
</details>

## Crash recovery

What we are trying to do here is get work back when the process holding it stops
existing.
{: .goal }

<!-- run: sql -->
```sql
select workflow.reap_stale_tasks();     -- one pg_cron job, once a minute
```

<details class="why" markdown="1">
<summary>Why it works — the lease fence, and why a slow worker and a dead one
look identical until one returns</summary>

A worker holds a lease it refreshes by heartbeat, and `reap_stale_tasks()`
requeues a task whose lease has gone stale — unclaimed, and behind a backoff.

Two parts are less obvious than they look.

**A reaped worker cannot publish its result.** If the original worker comes back
and calls `complete_task`, the lease fence refuses it and the refusal shows up in
`v_lease_violations` rather than disappearing. Without that, a slow worker and a
dead one are indistinguishable right up until the "dead" one returns and
overwrites the retry's answer with a stale one.

**A crash loop is bounded** by `max_attempts`, fails the run, and names the
worker that died.

`heartbeat_task` returns `false` for three different reasons — a cancel was
requested, the task is terminal, or your lease was reaped — and all three mean
stop.

<p class="related"><strong>Related</strong>
<a href="operating.html">watching for lease violations</a> ·
<a href="install.html#pg_cron-if-you-want-schedules">why the reaper needs
`pg_cron`</a></p>
</details>

## Saga compensation

What we are trying to do here is give back the things that already succeeded,
when a later step fails.
{: .goal }

```yaml
  - id: charge
    rest: {url: …, method: POST}
    compensate_with: refund
    saga_group: booking
```

<details class="why" markdown="1">
<summary>Why it works — compensations are ordinary tasks, deliberately</summary>

`begin_compensation()` enqueues the compensating steps for completed tasks in
reverse completion order. Because they are ordinary tasks they inherit retries,
backoff and the audit trail, and because they stay out of the forward graph a
compensation cannot accidentally satisfy a forward dependency.

The run ends `failed` with `compensation_state = compensated`, and those are two
columns because they answer two questions. A saga that rolled back cleanly still
did not do what it was asked.

<p class="related"><strong>Related</strong>
<a href="cookbook.html#9-undo-the-steps-that-already-worked">a saga with its
task table captured</a> ·
<a href="recipes.html#7-undo-what-already-happened">the same over real external
calls</a></p>
</details>

## What to watch

| | |
|---|---|
| `workflow.v_stuck_tasks` | not moving, and not making progress |
| `workflow.v_lease_violations` | a reaped worker tried to publish its result |
| `workflow.encoding_drift()` | a producer returning double-encoded JSON |
| `content.check_drift()` | files no resource points at, resources never chunked |

<details class="why" markdown="1">
<summary>Why it works — the first one has a lesson in it worth generalising</summary>

A view of `heartbeat_at` alone cannot see a crash loop, because every claim
refreshes it — so the failure keeps resetting the signal that is supposed to
reveal it. That is worse than having no view, because somebody is watching it
and drawing the wrong conclusion. `v_stuck_tasks` therefore pairs the two.

The general rule is to pair staleness with progress. "Not moving" and "moving and
getting nowhere" are different failures, and a monitor that only detects the
first will report health during the second.

<p class="related"><strong>Related</strong>
<a href="operating.html">the rest of what to watch</a> ·
<a href="recipes.html#a-throttle-has-to-exist-before-a-step-names-it">a failure
with no signal at all</a></p>
</details>

Next: [uploading files](ingest.html).
