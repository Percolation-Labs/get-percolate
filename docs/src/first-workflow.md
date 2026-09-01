# Your first workflow

A workflow is a document. `define_yaml` compiles it to rows and
`start_workflow` runs it — both are ordinary SQL functions, so nothing needs to
be running for you to define one.
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

That run is already complete by the time `start_workflow` returns. A `sql` step
becomes ready the moment its dependencies are satisfied and executes inside
Postgres — there is no worker in this picture at all.

## A real one, four steps

<ol class="steps" markdown="1">
<li markdown="1">**Fetch** something over the network. Needs a worker, because the database does not make outbound calls.</li>
<li markdown="1">**Project** the response into a typed table. Pure SQL; runs in-database.</li>
<li markdown="1">**Fan out** over the rows that produced. Expands with no controller process.</li>
<li markdown="1">**Aggregate** the children. Reads their outputs by handle, not by value.</li>
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

### What the run looks like while it happens

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

The children exist as rows the instant `fan` completes, with `volatility`
already depending on all of them. That is the property the design is for: there
is no moment where the fan-out has happened but the work is not recorded.

## Three things this example is quietly teaching

### `{{run.$id}}` — the run can see itself

`{{run.*}}` reads the run *input*. The run's own identity lives behind a
reserved `$`:

| Template | Is |
|---|---|
| `{{run.$id}}` | this run's uuid |
| `{{run.$trace_id}}` | the trace shared by every task in the run |
| `{{run.$session}}` | an engine-minted conversation id, for agent steps |

The prefix is reserved rather than plain `{{run.id}}` because an input key
called `id` is not unusual, and shadowing it would make the same template mean
different things depending on the caller's payload. This could not be worked
around by passing the id in: the caller does not know it until `start_workflow`
returns.

### The row set comes from a registered function

`matrix.rows` names a function in `workflow.step_functions`, never inline SQL.
Registration is an admin act, so **authoring a workflow never widens what can be
executed**. `max_fanout` is mandatory for the same reason a query without a
LIMIT is a bad idea against an unknown result set.

### The fan-in reads handles, not values

`fx_volatility` reads its siblings' outputs through `workflow.matrix_outputs`,
not through a template. Children deliberately do not write into `runs.context`:
one JSONB column rewritten in full per completion is quadratic write
amplification at fan-out scale.

## Watching it

```sql
select status, count(*) from workflow.tasks_api where run_id = :run group by 1;
select * from workflow.runs_api where id = :run;
```

Both are RLS-filtered views. Over REST they are `GET /runs_api?id=eq.<uuid>` and
`GET /tasks_api?run_id=eq.<uuid>` — every function in the client API is already
a PostgREST endpoint, so any HTTP-capable language is a full client with no
generated SDK.
