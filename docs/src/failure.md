# Failure and retry

Retry is a decision rather than a default. The worker is the only thing that
knows what an HTTP status means, so the worker decides and the engine goes with
its answer.
{: .lede }

## Terminal or retryable

```python
fail_task(task_id, error, terminal=True)   # do not retry, whatever attempts remain
fail_task(task_id, error, terminal=False)  # requeue with exponential backoff
```

A 400 or a 404 will fail the same way every time, so retrying it five times
with backoff turns a fast failure into a slow one and burns your rate limit
doing it. A 5xx or a 429 is the server's problem and is worth another go.

| Failure | Class | Why |
|---|---|---|
| HTTP 4xx (except 408, 429) | terminal | the same request gets the same answer |
| HTTP 5xx, 429, connection error | retryable | transient by definition |
| Output over the payload limit | terminal | the same response is the same size every time |
| Output violating `output_schema` | retryable | the same prompt really can conform next time |
| Unregistered step function, missing handler | terminal | `pip install` does not run itself between attempts |
| A `$artifact` that is not a resource uuid | terminal | the same string arrives every time |

The shape violation is the interesting one, since it is the only failure we
classify as retryable when it looks like a bug.

## Fan-out and partial failure

A matrix over real data will hit a missing value, a rate limit or an oversized
response on more or less every run. `continue_on: failed` makes a child failure
a result rather than an outage:

```yaml
  - id: run
    matrix:
      rows: {function: labelled_sample, args: ['gazette', 30]}
      continue_on: failed
      min_success: 20
      template: {agent: extractor, input: '{{item.text}}'}
```

`min_success` is the floor, and below it the aggregate is cancelled rather than
run on partial data. A summary computed over 3 of 30 documents that reports
success is worse than no summary at all.

In an evaluation the polarity flips. The fraction of documents an extractor
cannot parse is the measurement you wanted, so an eval sets `continue_on:
failed` with no floor.

## Crash recovery

A worker holds a lease that it refreshes by heartbeat, and
`reap_stale_tasks()` requeues a task whose lease has gone stale, unclaimed and
behind a backoff.

Two parts of this are less obvious than they look:

- A reaped worker cannot publish its result. If the original worker comes back
  and calls `complete_task`, the lease fence refuses it and the refusal shows
  up in `v_lease_violations` rather than disappearing. Without that, a slow
  worker and a dead one look identical until the "dead" one returns and
  overwrites the retry's answer with a stale one.
- A crash loop is bounded by `max_attempts`, fails the run, and names the
  worker that died.

`heartbeat_task` returns `false` for three different reasons — a cancel was
requested, the task is terminal, or your lease was reaped — and all three mean
stop.

## Saga compensation

```yaml
  - id: charge
    rest: {url: …, method: POST}
    compensate_with: refund
    saga_group: booking
```

`begin_compensation()` enqueues the compensating steps for completed tasks in
reverse completion order. Compensations are ordinary tasks so they inherit
retries, backoff and the audit trail, and they stay out of the forward graph so
a compensation cannot accidentally satisfy a forward dependency.

## What to watch

| | |
|---|---|
| `workflow.v_stuck_tasks` | not moving, and not making progress |
| `workflow.v_lease_violations` | a reaped worker tried to publish its result |
| `workflow.encoding_drift()` | a producer returning double-encoded JSON |
| `content.check_drift()` | files no resource points at, resources never chunked |

The first one has a lesson in it worth generalising. It originally could not
see a crash loop at all, because every claim refreshes `heartbeat_at`, so the
failure kept resetting the signal that was supposed to reveal it. That is worse
than having no view, because somebody is watching it. Pair staleness with
progress: "not moving" and "moving and getting nowhere" are different failures.

Next: [agents](agents.html).
