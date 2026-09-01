# Your first workflow

A workflow is a document. `define_yaml` compiles it into rows and
`start_workflow` runs it, and both are ordinary SQL functions, so you do not
need anything running to define one.
{: .lede }

## The smallest one that does something

```sql
select workflow.define_yaml($$
name: hello
steps:
  - id: now
    sql: {function: p8ql, args: ['SELECT now()']}
$$);

select workflow.start_workflow('hello', '{}'::jsonb);
```

That run has already finished by the time `start_workflow` returns to you. A
`sql` step becomes ready as soon as the things it depends on are satisfied and
then executes inside Postgres, so there is no worker involved anywhere.

## A four-step one

<ol class="steps" markdown="1">
<li markdown="1">**Fetch** something over the network. This needs a worker, since the database does not make outbound calls.</li>
<li markdown="1">**Project** the response into a typed table. Pure SQL, so it runs in the database.</li>
<li markdown="1">**Fan out** over the rows that produced.</li>
<li markdown="1">**Aggregate** the children, reading their outputs by handle rather than by value.</li>
</ol>

```yaml
name: fx_daily
steps:
  - id: fetch
    queue: http
    rest:
      url: https://api.frankfurter.app/latest?from=USD
      jsonpath: rates

  - id: project
    needs: [fetch]
    sql: {function: fx_project, args: ['{{run.$id}}', '{{steps.fetch.result}}']}

  - id: fan
    needs: [project]
    matrix:
      rows: {function: fx_currencies, args: ['{{run.$id}}']}
      max_fanout: 20
      template:
        queue: http
        rest: {url: 'https://api.frankfurter.app/2024-01-01..?from=USD&to={{item.code}}'}

  - id: volatility
    needs: [fan]
    sql: {function: fx_volatility, args: ['{{run.$id}}']}
```

### What it looks like while it runs

<div class="evidence" markdown="1">
<div class="label">select step_key, kind, status from workflow.tasks_api where run_id = …</div>

```
 step_key   | kind      | status
------------+-----------+--------
 fetch      | http_call | done
 project    | sql       | done
 fan        | sql       | done
 fan[EUR]   | http_call | running
 fan[GBP]   | http_call | running
 fan[JPY]   | http_call | ready
 volatility | sql       | pending
```
</div>

The children exist as rows the moment `fan` completes, with `volatility`
already depending on all of them. There is never a moment where the fan-out has
happened but the work is not written down.

## Three things this example is teaching you

### `{{run.$id}}` — the run can see itself

`{{run.*}}` reads the input you passed to `start_workflow`. The run's own
identity lives behind a `$`:

| Template | Is |
|---|---|
| `{{run.$id}}` | this run's uuid |
| `{{run.$trace_id}}` | the trace shared by every task in the run |
| `{{run.$session}}` | a conversation id the engine mints, for agent steps |

The prefix is there because plenty of payloads have a key called `id`, and
without it the same template would mean different things depending on what you
passed in. You cannot get around this by passing the run id yourself either,
since you do not have it until `start_workflow` returns.

### The row set comes from a registered function

`matrix.rows` names a function in `workflow.step_functions` rather than inline
SQL. Registering one is an admin action, so writing a workflow never widens
what can be executed. `max_fanout` is required, for the same reason you would
not run a query with no `LIMIT` against a result set you have not seen.

### The fan-in reads handles, not values

`fx_volatility` reads its siblings through `workflow.matrix_outputs` rather
than through a template. Children do not write into `runs.context`, because one
JSONB column rewritten in full on every completion gives you quadratic write
amplification once a fan-out gets wide.

## Watching a run

```sql
select status, count(*) from workflow.tasks_api where run_id = :run group by 1;
select * from workflow.runs_api where id = :run;
```

Both are RLS-filtered views. Over REST they are
`GET /runs_api?id=eq.<uuid>` and `GET /tasks_api?run_id=eq.<uuid>`, since every
function in the client API is already a PostgREST endpoint and any
HTTP-capable language is a full client with no generated SDK.

Next: [authoring in YAML](authoring.html) covers the step kinds and what the
compiler will refuse.
