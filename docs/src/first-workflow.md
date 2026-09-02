# Your first workflow

A workflow is a document. `define_yaml` compiles it into rows and
`start_workflow` runs it, and because both are ordinary SQL functions you do not
need anything running in order to define one.
{: .lede }

## The smallest one that does something

What we are trying to do here is define and run a workflow with nothing deployed
anywhere.
{: .goal }

```sql
select workflow.define_yaml($$
name: hello
steps:
  - id: now
    sql: {function: p8ql, args: ['SELECT now()']}
$$);

select workflow.start_workflow('hello', '{}'::jsonb);
```

<details class="why" markdown="1">
<summary>Why it works — the run has already finished by the time
`start_workflow` returns</summary>

A `sql` step becomes ready as soon as the things it depends on are satisfied,
and then executes inside Postgres in that same transaction. There is no worker
involved anywhere, no queue to poll, and no moment where the run exists but
nothing is acting on it.

That is not a special case for trivial workflows. Any pipeline made only of
`sql` and `p8ql` steps behaves this way, however long it is.

<p class="related"><strong>Related</strong>
<a href="authoring.html#choosing-a-step-kind">why to reach for `sql` first</a> ·
<a href="cookbook.html#6-a-workflow-with-nothing-running">a three-step version
with its task table</a></p>
</details>

## A four-step one

What we are trying to do here is fetch a rate table, project it into typed rows,
fan out over the currencies it produced, and aggregate the children.
{: .goal }

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

Only two of those four steps need a process. `project` and `volatility` run
inside the database, and `fetch` and the fan-out children are outbound calls,
which is the one thing the database will not do.

<details class="why" markdown="1">
<summary>Why it works — three things this example is quietly teaching you</summary>

**The run can see itself, behind a `$`.** `{{run.*}}` reads the input you passed
to `start_workflow`, and the run's own identity lives behind the prefix:
`{{run.$id}}` is this run's uuid, `{{run.$trace_id}}` the trace shared by every
task in it, `{{run.$session}}` a conversation id the engine mints for agent
steps. The prefix exists because plenty of payloads have a key called `id`, and
without it the same template would mean different things depending on what you
passed in. You cannot work around it by passing the run id yourself either,
since you do not have it until `start_workflow` returns.

**The row set is a query.** `matrix.rows` takes the statement itself — or a
registered function, if the deployment wants that operation blessed. `max_fanout`
is required for the same reason you would not run a query with no `LIMIT`
against a result set you have not seen.

**The fan-in reads handles, not values.** `fx_volatility` reads its siblings
through `workflow.matrix_outputs` rather than through a template. Children do
not write into `runs.context`, because one JSONB column rewritten in full on
every completion gives you quadratic write amplification once a fan-out gets
wide.

The children also exist as rows the moment `fan` completes, with `volatility`
already depending on all of them, so there is never a moment where the fan-out
has happened and the work is not written down.

<p class="related"><strong>Related</strong>
<a href="grammar-workflow.html#templates-and-the-one-rule-that-bites">every
template namespace</a> ·
<a href="outputs.html">why a fan-in reads a handle</a> ·
<a href="cookbook.html#7-fan-out-over-a-query-result">a fan-out with its rows
captured</a></p>
</details>

## Watching a run

What we are trying to do here is find out where a run has got to, from SQL or
over HTTP.
{: .goal }

```sql
select status, count(*) from workflow.tasks_api where run_id = :run group by 1;
select * from workflow.runs_api where id = :run;
```

<details class="why" markdown="1">
<summary>Why it works — every function in the client API is already a REST
endpoint</summary>

Both of those are RLS-filtered views, so a caller sees their own runs and not
anybody else's. Over REST they are `GET /runs_api?id=eq.<uuid>` and
`GET /tasks_api?run_id=eq.<uuid>`.

There is no generated SDK, and there is not meant to be. Every function in the
client API is a PostgREST endpoint already, which makes any HTTP-capable
language a complete client — and it means the management surface is the same one
a worker uses rather than a second, privileged path.

<p class="related"><strong>Related</strong>
<a href="operating.html">what to watch when nobody is looking</a> ·
<a href="query.html#over-rest-and-the-two-things-that-look-like-bugs">why a
result can look empty</a></p>
</details>

Next: [the workflow grammar](grammar-workflow.html) is the full vocabulary, and
[authoring in YAML](authoring.html) covers how to choose between the step kinds.
