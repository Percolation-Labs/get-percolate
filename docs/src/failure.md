# Failure and retry

Retry is a decision, not a default. The worker is the only thing that knows what
an HTTP status means, so the worker decides; the engine honours the verdict.
{: .lede }

## Terminal versus retryable

```python
fail_task(task_id, error, terminal=True)   # do not retry, whatever attempts remain
fail_task(task_id, error, terminal=False)  # requeue with exponential backoff
```

A 400 or a 404 fails identically on every attempt; retrying it five times with
backoff turns a fast failure into a slow one while burning the caller's rate
limit. A 5xx or a 429 is the server's problem and is worth retrying.

| Failure | Class | Why |
|---|---|---|
| HTTP 4xx (except 408, 429) | terminal | the same request gets the same answer |
| HTTP 5xx, 429, connection error | retryable | transient by definition |
| Output over the payload limit | terminal | the same response is the same size every attempt |
| **Output violating `output_schema`** | **retryable** | the same prompt genuinely can conform next time |
| Unregistered step function, missing handler | terminal | `pip install` does not run itself between attempts |
| A `$artifact` that is not a resource uuid | terminal | the same string arrives every attempt |

The shape violation is the interesting one — it is the only failure in the
engine deliberately classified as retryable when it looks like a bug.

## Fan-out and partial failure

A matrix over real data will hit an absent value, a rate limit or an oversized
response on essentially every run. `continue_on: failed` makes a child failure a
**result** rather than an outage:

```yaml
  - id: run
    matrix:
      rows: {function: labelled_sample, args: ['gazette', 30]}
      continue_on: failed
      min_success: 20
      template: {agent: extractor, input: '{{item.text}}'}
```

`min_success` is the floor. Below it the aggregate is **cancelled rather than run
on partial data** — which is the point: a summary computed over 3 of 30
documents that reports success is worse than no summary.

In an evaluation the polarity inverts. The fraction of documents an extractor
cannot parse is exactly the measurement, so an eval writes `continue_on: failed`
with no floor.

## Crash recovery

A worker holds a **lease**, refreshed by heartbeat. `reap_stale_tasks()` requeues
a task whose lease has gone stale, unclaimed, behind a backoff.

Two things about this are less obvious than they look:

- **A reaped worker cannot publish its result.** If the original worker comes
  back and calls `complete_task`, the lease fence refuses it and the refusal is
  *visible* in `v_lease_violations` rather than silent. Otherwise a slow worker
  and a dead one are indistinguishable until the "dead" one returns and
  overwrites the retry's answer with a stale one.
- **A crash loop is bounded** by `max_attempts`, fails the run, and names the
  worker that died.

`heartbeat_task` returns `false` for three different reasons — cancel requested,
task terminal, or your lease was reaped — and all three mean stop.

## Saga compensation

```yaml
  - id: charge
    rest: {url: …, method: POST}
    compensate_with: refund
    saga_group: booking
```

`begin_compensation()` enqueues the compensating steps for completed tasks in
**reverse completion order**. Compensations are ordinary tasks, so they inherit
retries, backoff and the audit trail — and they stay out of the forward graph,
so a compensation cannot satisfy a forward dependency.

## What to watch

| | |
|---|---|
| `workflow.v_stuck_tasks` | not moving — **paired with progress**, because a crash loop refreshes `heartbeat_at` on every claim and would otherwise look healthy |
| `workflow.v_lease_violations` | a reaped worker tried to publish |
| `workflow.encoding_drift()` | a producer returning double-encoded JSON |
| `content.check_drift()` | files no resource points at, resources never chunked |

The first row is the general lesson: **a health signal that the failure itself
resets is worse than no signal**, because someone is watching it.
